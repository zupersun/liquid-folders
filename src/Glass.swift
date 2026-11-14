import AppKit
import CoreImage

// What a glass folder looks like on the Desktop: the system's own Liquid Glass, frosted, bent at the rim and toned
// live by the window server, in a see-through window just above Finder's icon for the folder (drawing over icons takes
// no permission). Finder's icon is a still picture of the glass's film and rim (Still.swift), the picture Finder
// windows, title bars and Get Info show; on the Desktop a cover in the same window has the window server take it back
// off what the glass sees (Drop.swift), and the window draws the same film and rim itself, where they can move.
// No layer here reads a pixel, so no Screen Recording is needed and any wallpaper, moving or not, just works.
//
// Geometry is in the 512-unit canvas of the system folder icon, y measured down from the top, taken
// from the icon's own outline on macOS 26.6.

let units: CGFloat = 512
// The folder's corners, and its front pane's, in canvas units. Where the front pane's top-left
// corner would round down, it curves up instead, by `frontSweep`, and flows into the folder's left side.
let cornerRadius: CGFloat = 65
let frontSweep: CGFloat = 38
let frontTop: CGFloat = 135  // the front pane's top edge, below the back pane's (100)

// The material. Control Center's tiles darken what is behind them by about a quarter and lift the
// shadows a little; these per-channel gains and offsets were fitted to screenshots of Control
// Center over the Desktop.
let tone: [(gain: CGFloat, offset: CGFloat)] = [(0.69, 0.10), (0.64, 0.13), (0.60, 0.17)]
let frostBlur: CGFloat = 3.5     // points of blur on what is seen through the glass
// Colours behind the glass come out more vivid than they are, as in Control Center: fitted, with `tone`, to five of
// its tiles over a light sky (1.8 fits best, rms 4.9/255). Control Center does not darken its glass over a bright
// wallpaper.
let saturation: CGFloat = 1.8
let glassVariant = 19            // the system glass with Control Center's thin bright rim over a clear body
let designSize: CGFloat = 60     // the icon size the look was tuned at (Finder's Desktop icons here); others scale it
let glassRoom: CGFloat = 12      // points of wallpaper around the icon in the glass's window, for the frost to blur in from
// The system glass bends what is under its rim inward; this much more than it would by itself, and over
// a band this much wider, stands in for the lens the folder's rounded edge had before (bend 0.2 of its side).
let refraction = (amount: CGFloat(1.6), reach: CGFloat(1.4))
// The rim: the system glass draws a thin white line, lit from the top left. Finder's picture, lying over it, lights
// the same line a little more (under the picture's film the glass's own comes out dimmer), lit the same way: `width`
// points wide, `depth` points in, so the two read as one line.
let rimLight = (depth: CGFloat(0.3), width: CGFloat(0.8), strength: CGFloat(0.3), reach: CGFloat(0.24))

// GPU kernel, compiled from Metal source when first used. rim: white where `line` is drawn, lit as the system glass
// lights its rim: brightest where the edge runs along the up-left/down-right diagonal, fading to nothing across it.
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
    return try! CIKernel.kernels(withMetalString: source)[0]  // a typo here is a programming error: fail loudly
}()

/// A glass folder, for its window just above Finder's icon: `size` points square, laid out at `designSize` and
/// scaled, so its blur, bend and rim grow and shrink with Finder's icon size. Back to front:
///  - the back pane: frost, system glass, film, rim;
///  - the sheets, as far as the front pane's frost blurs them in from;
///  - the front pane's frost, then the sheets' crisp tops above the pane, then its system glass, film and rim, which
///    tip open together (see Drop.swift).
/// Each frost sees what lies under it in this window and, under the window, the screen with Finder's still picture
/// taken back off it (the cover, Drop.swift). The film and rim are those of Finder's picture (Still.swift), so the
/// folder looks as it did when that picture lay over the glass; the back frost and film leave a hole where the front
/// pane is, wherever it has tipped to, so nothing is frosted or toned twice.
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

let paneID = NSUserInterfaceItemIdentifier("pane")            // the front pane's glass, film and rim, which tip together
let backFrostID = NSUserInterfaceItemIdentifier("back frost")
let frontFrostID = NSUserInterfaceItemIdentifier("front frost")
let backFilmID = NSUserInterfaceItemIdentifier("back film")
let sheetsBehindID = NSUserInterfaceItemIdentifier("sheets behind")
let sheetsTopsID = NSUserInterfaceItemIdentifier("sheets' tops")
let shadeID = NSUserInterfaceItemIdentifier("shade")

/// The shade the front pane casts on the inside it uncovers as it tips open: its shadow, nudged up and softened, cut to
/// the folder's inside around the pane (the pane is see-through, so its own shadow under it would darken all of it).
func addShade(_ tile: NSView) {
    let view = NSView(frame: tile.bounds)
    let shade = CALayer()
    shade.shadowPath = frontOutline(designSize).cgPath
    shade.shadowColor = .black
    shade.shadowRadius = 1.5
    shade.shadowOffset = CGSize(width: 0, height: 1)
    shade.shadowOpacity = 0  // shut: no shade
    let cut = CAShapeLayer()
    cut.path = backFilmShape(0).cgPath  // on the folder's inside only
    cut.fillRule = .evenOdd
    shade.mask = cut
    view.layer = shade
    view.wantsLayer = true
    view.identifier = shadeID
    tile.addSubview(view)
}

/// Where the back frost, the front frost and the back film lie while the front pane is tipped `open` (see paneMap).
func backFrostShape(_ open: CGFloat) -> NSBezierPath { holed(inset(outline(designSize)), warped(inset(frontOutline(designSize), by: 1), open)) }
func frontFrostShape(_ open: CGFloat) -> NSBezierPath { warped(inset(frontOutline(designSize)), open) }
func backFilmShape(_ open: CGFloat) -> NSBezierPath { holed(outline(designSize), warped(frontOutline(designSize), open)) }
/// The sheets as the front frost sees them: within the pane and a band above it, which its blur draws in from (as many
/// as the frost saw when the sheets' tops lay in a window of their own: the whole tops would light the pane's top more).
func sheetsBehindShape(_ open: CGFloat) -> NSBezierPath {
    let pane = warped(frontOutline(designSize), open), band = NSAffineTransform()
    band.translateX(by: 0, yBy: frostBlur)
    let shape = NSBezierPath()
    shape.append(pane)
    shape.append(band.transform(pane))
    return shape
}
/// The sheets' crisp tops: everywhere but the pane, with room above the folder for a first sheet to come in from.
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

/// The film of Finder's picture over `shape`, as a layer of its own so that its shape can move.
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

/// The rim's lit line for `shape` as a picture `pixels` square, `designSize` points.
func rimPicture(_ shape: NSBezierPath, _ pixels: CGFloat) -> NSImage {
    let area = CGRect(x: 0, y: 0, width: pixels.rounded(), height: pixels.rounded())
    return NSImage(cgImage: context.createCGImage(rim(shape, area, pixels: area.width / designSize), from: area)!,
                   size: NSSize(width: designSize, height: designSize))
}

let sheetsID = NSUserInterfaceItemIdentifier("sheets")

/// The sheets, seen only within `shape`, which stays put while they move (see popSheets) and moves with the pane.
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

/// Every view showing a folder's sheets in `view`.
func sheetViews(_ view: NSView) -> [NSImageView] {
    (view.identifier == sheetsID ? [view as? NSImageView].compactMap { $0 } : []) + view.subviews.flatMap(sheetViews)
}

/// The sheets as a `pixels`-square picture, `designSize` points.
func paper(_ sheets: Int, _ pixels: CGFloat) -> NSImage {
    let bitmap = drawn(CGSize(width: pixels, height: pixels), CGRect(x: 0, y: 0, width: pixels, height: pixels)) { drawSheets(sheets) }
    return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: designSize, height: designSize))
}

/// Frost filling `shape`: the window server's copy of whatever lies behind it, blurred, made more vivid and toned.
/// It reaches past the tile, so that the blur near the rim draws on real wallpaper. A view of its own, so that it
/// keeps its place among the tile's other views.
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
    // shortcut: CABackdropLayer and CAFilter are private (the system glass is built from them); if a macOS update drops
    // them the folder shows the system glass alone, over the screen as it is (cover included, if it survives).
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

/// The shape a frost view (or a film view) is cut to, to move with the front pane.
func shapeLayer(_ view: NSView) -> CAShapeLayer? {
    view.layer as? CAShapeLayer ?? view.layer?.mask as? CAShapeLayer ?? view.layer?.sublayers?.first?.mask as? CAShapeLayer
}

func compositorFilter(_ type: String, _ inputs: [String: Any]) -> NSObject? {
    guard let filter = (NSClassFromString("CAFilter") as? NSObject.Type)?
        .perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject else { return nil }
    for (key, value) in inputs { filter.setValue(value, forKey: key) }
    return filter
}

/// The tone the frost itself must add, given that the film of Finder's picture (`filmOpacity` of `film`) lies over it,
/// drawn by the folder's window: together they make Control Center's tone (and the folder's tint). As rows of
/// (r, g, b, a, offset), for the compositor's colour matrix.
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

/// Control Center's tone and then the folder's tint, as one affine map (matrix, offset) on screen values: a tint is
/// the colour's hue and strength at the toned light's lightness (CIColorBlendMode's sums, which are linear until
/// they clip), `tint` of the way.
func toneMatrix(_ colour: String, _ tint: CGFloat) -> ([[CGFloat]], [CGFloat]) {
    let gains = tone.map(\.gain), offsets = tone.map(\.offset)
    guard let (r, g, b) = rgb(colour), tint > 0 else {
        return ((0..<3).map { i in (0..<3).map { j in i == j ? gains[i] : 0 } }, offsets)
    }
    let weights: [CGFloat] = [0.3, 0.59, 0.11], hue = [r, g, b]
    let hueLight = zip(weights, hue).map(*).reduce(0, +)
    let mix = (0..<3).map { i in (0..<3).map { j in (i == j ? 1 - tint : 0) + tint * weights[j] } }  // (1 - t) I + t 1 w
    let matrix = (0..<3).map { i in (0..<3).map { j in mix[i][j] * gains[j] } }
    let offset = (0..<3).map { i in (0..<3).map { j in mix[i][j] * offsets[j] }.reduce(0, +) + tint * (hue[i] - hueLight) }
    return (matrix, offset)
}

/// The rim's second line for `shape` (in tile points) over `area` (in pixels, `pixels` to the point).
func rim(_ shape: NSBezierPath, _ area: CGRect, pixels: CGFloat) -> CIImage {
    let short = min(shape.bounds.width, shape.bounds.height) * pixels
    let line = silhouette(inset(shape, by: rimLight.depth), area, pixels: pixels, stroke: rimLight.width)
    let height = silhouette(shape, area, pixels: pixels).clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: rimLight.reach * short / 2]).cropped(to: area)
    return rimKernel.apply(extent: area, roiCallback: { _, _ in area }, arguments: [line, height, rimLight.strength])!
}

/// `shape` (in tile points) in white on black over `area` (in pixels): filled, or only its outline, `stroke` points wide.
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

// The tone was measured in screen values, so the arithmetic runs on those, not on linear light.
let context = CIContext(options: [.workingColorSpace: NSNull()])

func addImage(_ tile: NSView, _ picture: NSImage) {
    let view = NSImageView(frame: CGRect(origin: .zero, size: picture.size))
    view.imageScaling = .scaleAxesIndependently
    view.image = picture
    tile.addSubview(view)
}

/// `shape` drawn in by about `by` points all round. (A frost layer stops half a point inside the
/// glass's rim, or its soft edge leaves a dark hairline on the Desktop just outside it.)
func inset(_ shape: NSBezierPath, by amount: CGFloat = 0.5) -> NSBezierPath {
    let bounds = shape.bounds
    let shrink = NSAffineTransform()
    shrink.translateX(by: bounds.midX, yBy: bounds.midY)
    shrink.scaleX(by: 1 - 2 * amount / bounds.width, yBy: 1 - 2 * amount / bounds.height)
    shrink.translateX(by: -bounds.midX, yBy: -bounds.midY)
    return shrink.transform(shape)
}

/// System glass filling `shape`. It is clipped to the shape's bounds: Control Center's tiles cast no
/// shadow, and the glass's own shadow would make the folder look like a sticker floating off the Desktop.
func addGlass(_ tile: NSView, _ shape: NSBezierPath) {
    let bounds = shape.bounds
    let glass = NSGlassEffectView(frame: bounds)
    glass.clipsToBounds = true
    // shortcut: _variant, _adaptiveAppearance and _setPath: are private. If a macOS update drops them
    // the glass falls back to the public clear style as a rounded rectangle; switch when Apple
    // publishes custom shapes.
    if send(glass, "set_variant:", glassVariant) {
        send(glass, "set_adaptiveAppearance:", 1)  // add no light or dark film of its own: the frost sets the tone
    } else {
        glass.style = .clear
    }
    let shift = NSAffineTransform()
    shift.translateX(by: -bounds.minX, yBy: -bounds.minY)  // the path is given in the glass's own coordinates
    if !send(glass, "_setPath:", shift.transform(shape).cgPath) {
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

/// Turn up the bending under the rim of every system glass in `view`, once they have been drawn (they build
/// their layers on first display); false while some have not. shortcut: reaches into the glass's private
/// compositor filters; if they are renamed the glass keeps its own, gentler bend.
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

/// A window whose glass always looks as it does in the front window.
///
/// Glass in a background window is dimmed: no highlight, no refraction at the rim, no shadow. This
/// window never takes focus, as it lets every click through to Finder, so it says it is active.
final class GlassWindow: NSWindow {
    // shortcut: a private AppKit method; if a macOS update drops it the glass is dimmed again
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    /// Take up the active look now, not on the next focus change.
    func forceActiveLook() {
        let selector = NSSelectorFromString("_sendForcedWindowChangedKeyState")
        if responds(to: selector) { perform(selector) }
    }
}
