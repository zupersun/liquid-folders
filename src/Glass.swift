import AppKit
import CoreImage

// A glass folder on the Desktop: system Liquid Glass with frost, film and rim, in a click-through window over
// Finder's icon. No layer reads pixels, so no Screen Recording permission is needed.

// Geometry is in the system folder icon's 512-unit canvas, y down, traced from macOS 26.6.
let units: CGFloat = 512
// Corner radius in canvas units; the front pane's top-left corner curves up by `frontSweep` into the left side.
let cornerRadius: CGFloat = 65
let frontSweep: CGFloat = 38
let frontTop: CGFloat = 135  // the back pane's top is at 100

// Control Center's tone per channel, fitted to screenshots of it over the Desktop.
let tone: [(gain: CGFloat, offset: CGFloat)] = [(0.69, 0.10), (0.64, 0.13), (0.60, 0.17)]
let frostBlur: CGFloat = 3.5     // points
// Fitted with `tone` to five Control Center tiles over a light sky (rms 4.9/255).
let saturation: CGFloat = 1.8
let glassVariant = 19            // Control Center's thin bright rim over a clear body
let designSize: CGFloat = 60     // icon size the look was tuned at; other sizes scale it
let glassRoom: CGFloat = 12      // points of wallpaper around the icon for the frost to blur in from
// Multipliers on the system glass's own bend under the rim (strength, band width).
let refraction = (amount: CGFloat(1.6), reach: CGFloat(1.4))
// A second rim line over the system glass's, which comes out dim under the film; lit the same way, from the top left.
let rimLight = (depth: CGFloat(0.3), width: CGFloat(0.8), strength: CGFloat(0.3), reach: CGFloat(0.24))

// Rim line lit as the system glass lights its rim: brightest along the up-left/down-right diagonal.
private let rimKernel: CIKernel = {
    let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    [[stitchable]] float4 rim(sampler line, sampler height, float strength, destination dest) {
        float2 p = dest.coord();
        float2 across = float2(1.0, 0.0), up = float2(0.0, 1.0);
        float2 slope = float2(height.sample(height.transform(p + across)).r - height.sample(height.transform(p - across)).r,
                              height.sample(height.transform(p + up)).r - height.sample(height.transform(p - up)).r);
        float2 inward = length(slope) > 1e-6 ? normalize(slope) : float2(0.0);
        float lit = clamp(1.3 * abs(dot(inward, float2(-0.7071, 0.7071))), 0.0, 1.0);
        float alpha = strength * line.sample(line.transform(p)).r * lit;
        return float4(alpha, alpha, alpha, alpha);
    }
    }}
    """
    return try! CIKernel.kernels(withMetalString: source)[0]
}()

/// A glass folder `size` points square, laid out at `designSize` and scaled. Back to front: back frost, glass, film,
/// rim; sheets; front frost; sheets' tops; shade; front pane (glass, film, rim), which tips open as one.
func folderTile(size: CGFloat, colour: String, tint: CGFloat, sheets: Int, scale: CGFloat) -> NSView {
    let tile = NSView(frame: CGRect(x: 0, y: 0, width: size, height: size))
    tile.wantsLayer = true
    tile.setBoundsSize(NSSize(width: designSize, height: designSize))
    let back = outline(designSize), front = frontOutline(designSize), pixels = size * scale
    addFrost(tile, backFrostShape(0), colour: colour, tint: tint, id: backFrostID)
    addGlass(tile, back)
    addFilm(tile, backFilmShape(0), colour: colour, tint: tint, id: backFilmID)
    addImage(tile, rimPicture(back, pixels))
    let papers = paper(sheets, pixels)
    addSheets(tile, papers, within: sheetsBehindShape(0), id: sheetsBehindID)
    addFrost(tile, frontFrostShape(0), colour: colour, tint: tint, id: frontFrostID)
    addSheets(tile, papers, within: sheetsTopsShape(0), id: sheetsTopsID)
    addShade(tile)
    let pane = NSView(frame: tile.bounds)
    pane.wantsLayer = true
    pane.identifier = paneID
    addGlass(pane, front)
    addFilm(pane, front, colour: colour, tint: tint, id: nil)
    addImage(pane, rimPicture(front, pixels))
    tile.addSubview(pane)
    return tile
}

let paneID = NSUserInterfaceItemIdentifier("pane")
let backFrostID = NSUserInterfaceItemIdentifier("back frost")
let frontFrostID = NSUserInterfaceItemIdentifier("front frost")
let backFilmID = NSUserInterfaceItemIdentifier("back film")
let sheetsBehindID = NSUserInterfaceItemIdentifier("sheets behind")
let sheetsTopsID = NSUserInterfaceItemIdentifier("sheets' tops")
let shadeID = NSUserInterfaceItemIdentifier("shade")

/// The shadow the front pane casts as it tips open, cut to around the pane: the pane is see-through.
func addShade(_ tile: NSView) {
    let view = NSView(frame: tile.bounds)
    let shade = CALayer()
    shade.shadowPath = frontOutline(designSize).cgPath
    shade.shadowColor = .black
    shade.shadowRadius = 1.5
    shade.shadowOffset = CGSize(width: 0, height: 1)
    shade.shadowOpacity = 0  // shut
    let cut = CAShapeLayer()
    cut.path = backFilmShape(0).cgPath
    cut.fillRule = .evenOdd
    shade.mask = cut
    view.layer = shade
    view.wantsLayer = true
    view.identifier = shadeID
    tile.addSubview(view)
}

/// Shapes with the front pane tipped `open` (see paneMap); the back ones leave a hole for it, so nothing tones twice.
func backFrostShape(_ open: CGFloat) -> NSBezierPath { holed(inset(outline(designSize)), warped(inset(frontOutline(designSize), by: 1), open)) }
func frontFrostShape(_ open: CGFloat) -> NSBezierPath { warped(inset(frontOutline(designSize)), open) }
func backFilmShape(_ open: CGFloat) -> NSBezierPath { holed(outline(designSize), warped(frontOutline(designSize), open)) }
/// The sheets the front frost sees: within the pane and a `frostBlur` band above it, which its blur draws in.
func sheetsBehindShape(_ open: CGFloat) -> NSBezierPath {
    let pane = warped(frontOutline(designSize), open), band = NSAffineTransform()
    band.translateX(by: 0, yBy: frostBlur)
    let shape = NSBezierPath()
    shape.append(pane)
    shape.append(band.transform(pane))
    return shape
}
/// The sheets' crisp tops: everywhere but the pane, with room above the folder for a sheet to come in from.
func sheetsTopsShape(_ open: CGFloat) -> NSBezierPath {
    holed(NSBezierPath(rect: CGRect(x: -designSize, y: -designSize, width: 3 * designSize, height: 3 * designSize)),
          warped(frontOutline(designSize), open))
}

func holed(_ shape: NSBezierPath, _ hole: NSBezierPath) -> NSBezierPath {
    let path = NSBezierPath()
    path.append(shape)
    path.append(hole)
    path.windingRule = .evenOdd
    return path
}

/// The film of Finder's picture over `shape`, as its own layer so the shape can move.
func addFilm(_ tile: NSView, _ shape: NSBezierPath, colour: String, tint: CGFloat, id: NSUserInterfaceItemIdentifier?) {
    let view = NSView(frame: tile.bounds)
    let layer = CAShapeLayer(), tinted = film(colour, tint)
    layer.path = shape.cgPath
    layer.fillRule = shape.windingRule == .evenOdd ? .evenOdd : .nonZero
    layer.fillColor = NSColor(srgbRed: tinted[0], green: tinted[1], blue: tinted[2], alpha: filmOpacity).cgColor
    view.layer = layer
    view.wantsLayer = true
    view.identifier = id
    tile.addSubview(view)
}

/// The rim line for `shape`, `pixels` square, `designSize` points.
func rimPicture(_ shape: NSBezierPath, _ pixels: CGFloat) -> NSImage {
    let area = CGRect(x: 0, y: 0, width: pixels.rounded(), height: pixels.rounded())
    return NSImage(cgImage: context.createCGImage(rim(shape, area, pixels: area.width / designSize), from: area)!,
                   size: NSSize(width: designSize, height: designSize))
}

let sheetsID = NSUserInterfaceItemIdentifier("sheets")

/// The sheets, seen only within `shape`, which stays put while they move (see popSheets).
func addSheets(_ tile: NSView, _ picture: NSImage, within shape: NSBezierPath, id: NSUserInterfaceItemIdentifier) {
    let window = NSView(frame: tile.bounds)
    window.wantsLayer = true
    window.identifier = id
    let mask = CAShapeLayer()
    mask.path = shape.cgPath
    mask.fillRule = shape.windingRule == .evenOdd ? .evenOdd : .nonZero
    window.layer?.mask = mask
    let sheets = NSImageView(frame: tile.bounds)
    sheets.identifier = sheetsID
    sheets.imageScaling = .scaleAxesIndependently
    sheets.image = picture
    sheets.wantsLayer = true
    window.addSubview(sheets)
    tile.addSubview(window)
}

func sheetViews(_ view: NSView) -> [NSImageView] {
    (view.identifier == sheetsID ? [view as? NSImageView].compactMap { $0 } : []) + view.subviews.flatMap(sheetViews)
}

/// The sheets as a `pixels`-square picture, `designSize` points.
func paper(_ sheets: Int, _ pixels: CGFloat) -> NSImage {
    let bitmap = drawn(CGSize(width: pixels, height: pixels), CGRect(x: 0, y: 0, width: pixels, height: pixels)) { drawSheets(sheets) }
    return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: designSize, height: designSize))
}

/// Frost in `shape`: the window server's copy of what lies behind, blurred, saturated and toned.
/// It reaches past the tile so the blur near the rim draws on real wallpaper.
func addFrost(_ tile: NSView, _ shape: NSBezierPath, colour: String, tint: CGFloat, id: NSUserInterfaceItemIdentifier) {
    let view = NSView(frame: tile.bounds)
    view.wantsLayer = true
    view.identifier = id
    tile.addSubview(view)
    let holder = CALayer()
    holder.frame = view.bounds
    let mask = CAShapeLayer()
    mask.path = shape.cgPath
    mask.fillRule = shape.windingRule == .evenOdd ? .evenOdd : .nonZero
    holder.mask = mask
    // shortcut: CABackdropLayer and CAFilter are private (no frost if dropped), switch if Apple makes a public one.
    guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }
    let backdrop = backdropClass.init()
    let room = glassRoom * designSize / tile.frame.width
    backdrop.frame = tile.bounds.insetBy(dx: -room, dy: -room)
    backdrop.setValue(true, forKey: "windowServerAware")
    backdrop.setValue(2 * frostBlur, forKey: "marginWidth")
    backdrop.filters = [
        compositorFilter("gaussianBlur", ["inputRadius": frostBlur, "inputNormalizeEdges": true]),
        compositorFilter("colorSaturate", ["inputAmount": saturation]),
        compositorFilter("colorMatrix", ["inputColorMatrix": underFilm(colour, tint)]),
    ].compactMap { $0 }
    holder.addSublayer(backdrop)
    view.layer?.addSublayer(holder)
}

/// The shape a frost or film view is cut to, to move with the front pane.
func shapeLayer(_ view: NSView) -> CAShapeLayer? {
    view.layer as? CAShapeLayer ?? view.layer?.mask as? CAShapeLayer ?? view.layer?.sublayers?.first?.mask as? CAShapeLayer
}

func compositorFilter(_ type: String, _ inputs: [String: Any]) -> NSObject? {
    guard let filter = (NSClassFromString("CAFilter") as? NSObject.Type)?
        .perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject else { return nil }
    for (key, value) in inputs { filter.setValue(value, forKey: key) }
    return filter
}

/// The tone the frost must add so that, with the picture's film over it, the two make Control Center's tone and the
/// folder's tint. Rows of (r, g, b, a, offset).
func underFilmRows(_ colour: String, _ tint: CGFloat) -> [[CGFloat]] {
    let (matrix, offset) = toneMatrix(colour, tint)
    let f = film(colour, tint), a = filmOpacity
    return (0..<3).map { r in matrix[r].map { $0 / (1 - a) } + [0, (offset[r] - a * f[r]) / (1 - a)] } + [[0, 0, 0, 1, 0]]
}

func underFilm(_ colour: String, _ tint: CGFloat) -> NSValue { matrixValue(underFilmRows(colour, tint)) }

/// Rows of (r, g, b, a, offset) as the compositor's colour matrix.
func matrixValue(_ rows: [[CGFloat]]) -> NSValue {
    var values = rows.flatMap { $0 }.map { Float($0) }
    return NSValue(bytes: &values, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
}

/// Control Center's tone, then the folder's tint, as one affine map (matrix, offset) on screen values.
/// The tint follows CIColorBlendMode's sums, which are linear until they clip.
func toneMatrix(_ colour: String, _ tint: CGFloat) -> ([[CGFloat]], [CGFloat]) {
    let gains = tone.map(\.gain), offsets = tone.map(\.offset)
    guard let (r, g, b) = rgb(colour), tint > 0 else {
        return ((0..<3).map { i in (0..<3).map { j in i == j ? gains[i] : 0 } }, offsets)
    }
    let weights: [CGFloat] = [0.3, 0.59, 0.11], hue = [r, g, b]
    let hueLight = zip(weights, hue).map(*).reduce(0, +)
    let mix = (0..<3).map { i in (0..<3).map { j in (i == j ? 1 - tint : 0) + tint * weights[j] } }
    let matrix = (0..<3).map { i in (0..<3).map { j in mix[i][j] * gains[j] } }
    let offset = (0..<3).map { i in (0..<3).map { j in mix[i][j] * offsets[j] }.reduce(0, +) + tint * (hue[i] - hueLight) }
    return (matrix, offset)
}

/// The rim's second line for `shape` (tile points) over `area` (pixels, `pixels` to the point).
func rim(_ shape: NSBezierPath, _ area: CGRect, pixels: CGFloat) -> CIImage {
    let short = min(shape.bounds.width, shape.bounds.height) * pixels
    let line = silhouette(inset(shape, by: rimLight.depth), area, pixels: pixels, stroke: rimLight.width)
    let height = silhouette(shape, area, pixels: pixels).clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: rimLight.reach * short / 2]).cropped(to: area)
    return rimKernel.apply(extent: area, roiCallback: { _, _ in area }, arguments: [line, height, rimLight.strength])!
}

/// `shape` (tile points) white on black over `area` (pixels): filled, or stroked `stroke` points wide.
func silhouette(_ shape: NSBezierPath, _ area: CGRect, pixels: CGFloat, stroke: CGFloat = 0) -> CIImage {
    let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width), pixelsHigh: Int(area.height),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    NSColor.black.set()
    NSBezierPath.fill(CGRect(x: 0, y: 0, width: canvas.pixelsWide, height: canvas.pixelsHigh))
    let place = NSAffineTransform()
    place.scale(by: pixels)
    NSColor.white.set()
    let placed = place.transform(shape)
    if stroke > 0 {
        placed.lineWidth = stroke * pixels
        placed.stroke()
    } else {
        placed.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return CIImage(cgImage: canvas.cgImage!)
}

// The tone was measured in screen values, so the maths runs on those, not on linear light.
let context = CIContext(options: [.workingColorSpace: NSNull()])

func addImage(_ tile: NSView, _ picture: NSImage) {
    let view = NSImageView(frame: CGRect(origin: .zero, size: picture.size))
    view.imageScaling = .scaleAxesIndependently
    view.image = picture
    tile.addSubview(view)
}

/// `shape` shrunk by about `by` points all round. Frost stops half a point inside the glass's rim, or its soft edge
/// leaves a dark hairline on the Desktop.
func inset(_ shape: NSBezierPath, by amount: CGFloat = 0.5) -> NSBezierPath {
    let bounds = shape.bounds
    let shrink = NSAffineTransform()
    shrink.translateX(by: bounds.midX, yBy: bounds.midY)
    shrink.scaleX(by: 1 - 2 * amount / bounds.width, yBy: 1 - 2 * amount / bounds.height)
    shrink.translateX(by: -bounds.midX, yBy: -bounds.midY)
    return shrink.transform(shape)
}

/// System glass filling `shape`, clipped to its bounds: its own shadow would make the folder look like a sticker.
func addGlass(_ tile: NSView, _ shape: NSBezierPath) {
    let bounds = shape.bounds
    let glass = NSGlassEffectView(frame: bounds)
    glass.clipsToBounds = true
    // shortcut: _variant, _adaptiveAppearance and _setPath: are private, switch when Apple publishes custom shapes.
    if send(glass, "set_variant:", glassVariant) {
        send(glass, "set_adaptiveAppearance:", 1)  // no light or dark film of its own: the frost sets the tone
    } else {
        glass.style = .clear
    }
    let shift = NSAffineTransform()
    shift.translateX(by: -bounds.minX, yBy: -bounds.minY)  // _setPath: takes the glass's own coordinates
    let path = shift.transform(shape).cgPath
    if send(glass, "_setPath:", path) {
        let edge = CAShapeLayer()  // its rim's glow speckles past the path at the lit corners, which bounds don't clip
        edge.path = path
        edge.frame = CGRect(origin: .zero, size: bounds.size)
        glass.wantsLayer = true
        glass.layer?.mask = edge
    } else {
        glass.cornerRadius = cornerRadius * bounds.width / units
    }
    tile.addSubview(glass)
}

/// Strengthen the glass's bend once it has built its layers, on its first display.
func tune(_ tile: NSView, tries: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak tile] in
        guard let tile, tile.window != nil else { return }
        if !strengthenRefraction(tile) && tries > 1 { tune(tile, tries: tries - 1) }
    }
}

/// Turn up the bend under the rim of every system glass in `view`; false while some have not built their layers.
/// shortcut: edits the glass's private filters (if renamed: the default bend), switch if Apple exposes the bend.
@discardableResult
func strengthenRefraction(_ view: NSView) -> Bool {
    func visit(_ layer: CALayer) -> Bool {
        if let filters = layer.filters as? [NSObject], let glass = filters.first(where: { $0.value(forKey: "type") as? String == "glassBackground" }) {
            if layer.value(forKey: "liquidfolderTuned") == nil, let amount = glass.value(forKey: "inputInnerRefractionAmount") as? Double,
               let reach = glass.value(forKey: "inputInnerRefractionHeight") as? Double {
                glass.setValue(amount * Double(refraction.amount), forKey: "inputInnerRefractionAmount")
                glass.setValue(reach * Double(refraction.reach), forKey: "inputInnerRefractionHeight")
                layer.filters = filters
                layer.setValue(true, forKey: "liquidfolderTuned")
            }
            return true
        }
        return (layer.sublayers ?? []).map(visit).contains(true)
    }
    func glass(_ view: NSView) -> [NSView] { view.subviews.flatMap { $0 is NSGlassEffectView ? [$0] : glass($0) } }
    return glass(view).allSatisfy { $0.layer.map(visit) ?? false }
}

/// Call a private method taking one integer, if the object has it.
@discardableResult
func send(_ object: NSObject, _ name: String, _ value: Int) -> Bool {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return false }
    typealias Call = @convention(c) (NSObject, Selector, Int) -> Void
    unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector, value)
    return true
}

/// Call a private method taking one object, if the object has it.
@discardableResult
func send(_ object: NSObject, _ name: String, _ value: AnyObject) -> Bool {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return false }
    typealias Call = @convention(c) (NSObject, Selector, AnyObject) -> Void
    unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector, value)
    return true
}

/// A window that always gets the active glass look. Glass in a background window is dimmed (no highlight, rim bend
/// or shadow), and this window never takes focus: every click goes through to Finder.
final class GlassWindow: NSWindow {
    // shortcut: a private AppKit method (if dropped, the glass dims again), switch if Apple adds a public option.
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    /// Take up the active look now, not on the next focus change.
    func forceActiveLook() {
        let selector = NSSelectorFromString("_sendForcedWindowChangedKeyState")
        if responds(to: selector) { perform(selector) }
    }
}
