import AppKit

// Finder's still picture of a glass folder: film, rim and sheets. Finder windows, Get Info and drags show it as is;
// on the Desktop the glass window takes it back off (cover, patch) and draws the same over live frost.

let iconSizes = [32, 64, 128, 256, 512]  // pixel sizes Finder stores an icon at

// (x offset, y offset, degrees) per sheet, back to front, indexed by sheet count.
let sheetFans: [[(CGFloat, CGFloat, CGFloat)]] = [
    [],
    [(0, 0, 0)],
    [(-34, 8, -6), (30, 0, 5)],
    [(-62, 14, -9), (0, 0, 0), (60, 12, 8)],
]

/// A film `1 - gain` opaque gives Control Center's tone over any backdrop. One opacity serves all channels: the
/// thinnest, as the frost under it can darken what it shows but never lighten it.
let filmOpacity = 1 - tone.map(\.gain).max()!

let pictureVersion = 7  // raise when the drawing changes, so folders with the old picture get the new one

/// The film colour closest to the live glass over Finder's dark and light window backgrounds alike.
func film(_ colour: String, _ tint: CGFloat) -> [CGFloat] {
    let backdrops: [CGFloat] = [0.12, 1.0]
    let seen = backdrops.map { seenThrough($0, rgb(colour), tint) }
    return (0..<3).map { c in
        min(1, max(0, zip(backdrops, seen).map { b, through in through[c] - b * (1 - filmOpacity) }.reduce(0, +) / 2 / filmOpacity))
    }
}

/// The folder as a Finder icon, drawn at every size Finder stores: film, sheets under the front pane, rim.
func icon(_ colour: String, _ tint: CGFloat, sheets: Int = 0) -> NSImage {
    let picture = NSImage(size: NSSize(width: units, height: units))
    for size in iconSizes {
        let bitmap = iconBitmap(size, colour, tint, sheets: sheets)
        bitmap.size = NSSize(width: units, height: units)
        picture.addRepresentation(bitmap)
    }
    return picture
}

func iconBitmap(_ size: Int, _ colour: String, _ tint: CGFloat, sheets: Int = 0) -> NSBitmapImageRep {
    let area = CGRect(x: 0, y: 0, width: size, height: size)
    let tinted = film(colour, tint)
    let bitmap = drawn(area.size, area) {
        NSColor(srgbRed: tinted[0], green: tinted[1], blue: tinted[2], alpha: filmOpacity).set()
        outline(units, flipped: true).fill()
        guard sheets > 0 else { return }  // no sheets: exactly what the cover takes off
        NSGraphicsContext.saveGraphicsState()  // sheets whole above the front pane, faint behind it
        let above = NSBezierPath(rect: CGRect(x: -units, y: -units, width: 3 * units, height: 3 * units))
        above.append(frontOutline(units, flipped: true))
        above.windingRule = .evenOdd
        above.addClip()
        drawSheets(sheets)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        frontOutline(units, flipped: true).addClip()
        NSGraphicsContext.current?.cgContext.setAlpha(0.35)
        drawSheets(sheets)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        frontOutline(units, flipped: true).addClip()  // the front pane's film again, over the sheets only
        NSColor(srgbRed: tinted[0], green: tinted[1], blue: tinted[2], alpha: filmOpacity).set()
        let sheetArea = NSBezierPath()
        sheetShapes(sheets, grownBy: 0).forEach { sheetArea.append($0) }  // same winding: overlaps fill once
        sheetArea.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    for shape in [outline(designSize), frontOutline(designSize)] {
        NSGraphicsContext.current!.cgContext.draw(context.createCGImage(rim(shape, area, pixels: CGFloat(size) / designSize), from: area)!, in: area)
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

/// The stored size Finder draws a `points` icon from. Measured: it rounds up to 16, 32, 128, 256 or 512 pt × scale.
func storedSize(points: CGFloat, scale: CGFloat) -> Int {
    let rounded = CGFloat([16, 32, 128, 256, 512].first { CGFloat($0) >= points } ?? 512) * scale
    return iconSizes.first { CGFloat($0) >= rounded } ?? iconSizes.last!
}

/// Finder's picture as it lands on screen for a `points` icon, without sheets (the patch covers those).
/// shortcut: assumes Finder scales like Core Graphics' high-quality interpolation, re-check if a ghost shows.
func finderPicture(_ colour: String, _ tint: CGFloat, points: CGFloat, scale: CGFloat) -> CGImage {
    let stored = iconBitmap(storedSize(points: points, scale: scale), colour, tint)
    let pixels = Int((points * scale).rounded())
    let canvas = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    canvas.interpolationQuality = .high
    canvas.draw(stored.cgImage!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return canvas.makeImage()!
}

/// What the live glass makes of a grey backdrop: Control Center's tone, then the tint by CIColorBlendMode's sums.
func seenThrough(_ white: CGFloat, _ colour: (CGFloat, CGFloat, CGFloat)?, _ tint: CGFloat) -> [CGFloat] {
    let toned = tone.map { $0.gain * white + $0.offset }
    guard let (r, g, b) = colour else { return toned }
    let lum = { (c: [CGFloat]) in 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] }
    let light = lum(toned)
    let hue = [r, g, b].map { $0 + light - lum([r, g, b]) }
    let low = hue.min()!, high = hue.max()!
    let squeeze = min(low < 0 ? light / (light - low) : 1, high > 1 ? (1 - light) / (high - light) : 1)
    return zip(toned, hue).map { t, h in t + tint * (light + (h - light) * squeeze - t) }
}

// -- shared drawing

/// The whole folder silhouette, tab included, scaled to `size`; y runs up unless flipped.
func outline(_ size: CGFloat, flipped: Bool = false) -> NSBezierPath {
    let unit = size / units
    func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * unit, y: (flipped ? y : units - y) * unit) }
    let r = cornerRadius
    let tab = min(r, frontTop - 67 - frontSweep)  // the tab's corner ends where the front pane's sweep meets the side
    let path = NSBezierPath()
    path.move(to: at(21 + tab, 67))
    path.line(to: at(150, 67))
    path.curve(to: at(207, 100), controlPoint1: at(178, 67), controlPoint2: at(176, 100))  // the tab's shoulder
    path.appendArc(from: at(490, 100), to: at(490, 100 + r), radius: r * unit)
    path.appendArc(from: at(490, 444), to: at(490 - r, 444), radius: r * unit)
    path.appendArc(from: at(21, 444), to: at(21, 444 - r), radius: r * unit)
    path.appendArc(from: at(21, 67), to: at(21 + tab, 67), radius: tab * unit)
    path.close()
    return path
}

/// The front pane, scaled to `size`; y runs up unless flipped. Its top-left corner curves up into the side.
func frontOutline(_ size: CGFloat, flipped: Bool = false) -> NSBezierPath {
    let unit = size / units
    func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * unit, y: (flipped ? y : units - y) * unit) }
    let r = cornerRadius, s = frontSweep, top = frontTop, k: CGFloat = 0.5523  // k: a quarter circle as a curve
    let path = NSBezierPath()
    if s > 0 {
        path.move(to: at(21, top - s))
        path.curve(to: at(21 + s, top), controlPoint1: at(21, top - s + k * s), controlPoint2: at(21 + s - k * s, top))
    } else {
        path.move(to: at(21, top + r))
        path.appendArc(from: at(21, top), to: at(21 + r, top), radius: r * unit)
    }
    path.appendArc(from: at(490, top), to: at(490, top + r), radius: r * unit)
    path.appendArc(from: at(490, 444), to: at(490 - r, 444), radius: r * unit)
    path.appendArc(from: at(21, 444), to: at(21, 444 - r), radius: r * unit)
    path.close()
    return path
}

/// The sheets' outlines, back to front, in canvas units (y down), each grown by `grownBy` units.
func sheetShapes(_ sheets: Int, grownBy grow: CGFloat) -> [NSBezierPath] {
    sheetFans[min(sheets, sheetFans.count - 1)].map { dx, dy, degrees -> NSBezierPath in
        let turn = NSAffineTransform()
        turn.translateX(by: 256 + dx, yBy: 232 + dy)
        turn.rotate(byDegrees: degrees)
        return turn.transform(NSBezierPath(roundedRect: CGRect(x: -108, y: -140, width: 216, height: 280).insetBy(dx: -grow, dy: -grow),
                                           xRadius: 12 + grow, yRadius: 12 + grow))
    }
}

/// White sheets in canvas units, each with a soft shadow.
func drawSheets(_ sheets: Int) {
    let shapes = sheetShapes(sheets, grownBy: 0)
    for (behind, shape) in zip(stride(from: sheets - 1, through: 0, by: -1), shapes) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()  // shadows ignore the canvas scale: blur and offset are in device pixels
        shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        let grey = 1 - 0.03 * CGFloat(behind)  // sheets further back are a little darker
        NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 0.95).set()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A clear bitmap of `size` pixels with draw() run in canvas units, mapped onto `area`.
func drawn(_ size: CGSize, _ area: CGRect, _ draw: () -> Void) -> NSBitmapImageRep {
    let width = Int(size.width.rounded()), height = Int(size.height.rounded())
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: width * 4, bitsPerPixel: 32)!.retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.compositingOperation = .copy
    NSColor.clear.set()
    NSBezierPath.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.compositingOperation = .sourceOver
    let canvas = NSAffineTransform()
    canvas.translateX(by: area.minX, yBy: area.minY + area.height)
    canvas.scaleX(by: area.width / units, yBy: -area.height / units)  // 512 units across, y down
    canvas.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

// -- patch: Finder's sheets, taken back off on the Desktop

let patchID = NSUserInterfaceItemIdentifier("patch")

/// Finder's sheets are opaque, so the cover can't take them off: a patch over them shows the screen around them,
/// blurred and made opaque again (as the stand-in does), so the frost never sees them. `others`: left out of it.
func addPatch(_ holder: NSView, icon: CGRect, others: [CGRect], sheets: [Int], scale: CGFloat) {
    guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }  // see addFrost
    let view = NSView(frame: holder.bounds)
    view.layer = CALayer()
    view.wantsLayer = true
    view.identifier = patchID
    let made = CALayer()
    made.frame = view.bounds
    let around = backdropClass.init()
    around.frame = made.bounds
    around.setValue(true, forKey: "windowServerAware")
    around.mask = CAShapeLayer()
    made.addSublayer(around)
    made.filters = [compositorFilter("gaussianBlur", ["inputRadius": standInBlur * icon.width, "inputNormalizeEdges": true]),
                    compositorFilter("colorMatrix", ["inputColorMatrix": matrixValue([[1, 0, 0, 0, 0], [0, 1, 0, 0, 0], [0, 0, 1, 0, 0], [0, 0, 0, 0, 1]])])].compactMap { $0 }
    made.mask = CAShapeLayer()
    made.setValue(NSValue(rect: icon), forKey: "liquidfolderIcon")
    made.setValue(others.map { NSValue(rect: $0) }, forKey: "liquidfolderOthers")
    made.setValue(storedSize(points: icon.width, scale: scale), forKey: "liquidfolderStored")
    view.layer!.addSublayer(made)
    holder.addSubview(view, positioned: .above, relativeTo: views(holder, coverID).first)
    setPatch(holder, sheets: sheets)
}

/// Cover the sheets for each count in `sheets`, and their shadows (6 px of blur at the stored size, and 2 more),
/// within the icon's square. Samples around them but not `others`. A nil argument keeps the last value.
func setPatch(_ holder: NSView, sheets: [Int]? = nil, others: [CGRect]? = nil) {
    guard let made = views(holder, patchID).first?.layer?.sublayers?.first, let shown = made.mask as? CAShapeLayer,
          let sampled = made.sublayers?.first?.mask as? CAShapeLayer, let icon = (made.value(forKey: "liquidfolderIcon") as? NSValue)?.rectValue,
          let stored = made.value(forKey: "liquidfolderStored") as? Int else { return }
    others.map { made.setValue($0.map { NSValue(rect: $0) }, forKey: "liquidfolderOthers") }
    sheets.map { made.setValue($0, forKey: "liquidfolderSheets") }
    let others = (made.value(forKey: "liquidfolderOthers") as? [NSValue])?.map(\.rectValue) ?? []
    let counts = made.value(forKey: "liquidfolderSheets") as? [Int] ?? []
    let place = NSAffineTransform()  // canvas units (y down) to the window's points
    place.translateX(by: icon.minX, yBy: icon.maxY)
    place.scaleX(by: icon.width / units, yBy: -icon.height / units)
    let over = Set(counts).flatMap { sheetShapes($0, grownBy: 8 / CGFloat(stored) * units) }.reduce(CGMutablePath() as CGPath) { $0.union(place.transform($1).cgPath) }
        .intersection(CGPath(rect: icon, transform: nil))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    made.isHidden = counts.allSatisfy { $0 == 0 }
    shown.path = over
    sampled.path = CGPath(rect: made.bounds, transform: nil).subtracting(others.reduce(over) { $0.union(CGPath(rect: $1, transform: nil)) })
    CATransaction.commit()
}
