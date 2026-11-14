import AppKit

// A glass folder's window and how the folder moves in it: its front pane tips open while something is dragged over
// it, as a plain folder's does; when something is dropped in, the pane opens a little further and
// shuts, the whole folder gives a little and swells, and the sheets jump (a first sheet slides in from above). All of
// it lives in one window just above Finder's icon, over a cover that takes Finder's still picture back off what the
// glass sees, and a stand-in for the moments Finder draws something else (each in its own section below).

/// How far the front pane's top-right corner comes away while something is dragged over the folder, as shares of the
/// pane's height (down) and width (in), and how dark its shade on the inside gets.
/// The pane is glued to the folder along its left side, tip included, and along its bottom.
let swing = (down: CGFloat(0.14), across: CGFloat(0.04), shade: CGFloat(0.35))
/// On a drop the pane opens this much further than while hovering (1), then shuts: (open, at, shut by), seconds.
let dropLid = (open: CGFloat(1.6), at: 0.11, shut: 0.36)
let frameStep = 1.0 / 60  // how finely the pane's motion is laid out ahead, so that every part of it keeps in step

/// What a plain folder does when something is dropped into it (measured frame by frame on macOS 26.6): about a quarter of a second after the drop its paper dips a little, springs up past
/// where it rests and settles. As shares of the folder's size, over time from the start. A glass folder's front pane
/// shows what is behind it, so a first sheet doesn't rise from inside, as a plain folder's does, but drops in from
/// above, fading in, while the pane is open, and lands as it shuts.
let dropPop = (delay: 0.26, duration: 0.44, values: [0, -0.0625, 0.035, 0] as [CGFloat], times: [0, 0.09, 0.32, 1] as [NSNumber])
let firstSheetPop = (delay: 0.04, duration: 0.46, values: [0.42, 0, -0.04, 0] as [CGFloat], times: [0, 0.62, 0.8, 1] as [NSNumber])
/// Meanwhile the whole plain folder gives a little, swells by 7.6% and comes back, about its centre (two drops measured
/// frame by frame and averaged; it starts 0.165 s after the drop: started from the mouse-up's own time, the
/// glass recorded the same way came about 0.01 s later than asked). As scales over time from the start.
let dropSwell = (delay: 0.155, duration: 0.543,
                 values: [1, 0.9666, 0.9591, 0.976, 0.9986, 1.0283, 1.0507, 1.0648, 1.0749, 1.0737, 1.0659, 1.0578,
                          1.0497, 1.0396, 1.0306, 1.0236, 1.0186, 1.0152, 1.0109, 1.0091, 1.0056, 1.0038, 1] as [CGFloat])

/// How long a drop plays: its contents are counted again after it, not during it (see Agent.dropped).
let dropSettles = max(dropPop.delay + dropPop.duration, firstSheetPop.delay + firstSheetPop.duration, dropSwell.delay + dropSwell.duration)

let swellID = NSUserInterfaceItemIdentifier("swell")  // the view that swells with the folder, about the icon's centre
let tileID = NSUserInterfaceItemIdentifier("tile")
let coverID = NSUserInterfaceItemIdentifier("cover")

/// A folder's window contents: room around Finder's icon (`icon`, in the window), the cover over the icon, the stand-in
/// (made without `others`, the other icons nearby) and, over them, the folder in a view that can swell.
func glassHolder(_ window: CGSize, icon: CGRect, others: [CGRect] = [], selected: Bool = false, colour: String, tint: CGFloat, sheets: Int,
                 finderSheets: [Int] = [], scale: CGFloat) -> NSView {
    let holder = NSView(frame: CGRect(origin: .zero, size: window))
    holder.wantsLayer = true
    let picture = finderPicture(colour, tint, points: icon.width, scale: scale)
    let cover = NSView(frame: icon)
    cover.layer = CALayer()  // ours alone: AppKit draws nothing into it
    cover.wantsLayer = true
    cover.identifier = coverID
    addUnpicture(cover.layer!, picture, colour: colour, tint: tint, scale: scale)
    holder.addSubview(cover)
    addStandIn(holder, icon: icon, others: others, selected: selected, scale: scale)
    addPatch(holder, icon: icon, others: others, sheets: finderSheets, scale: scale)  // (under the stand-in: just over the cover)
    let swelling = NSView(frame: icon)
    swelling.wantsLayer = true
    swelling.identifier = swellID
    let tile = folderTile(size: icon.width, colour: colour, tint: tint, sheets: sheets, scale: scale)
    tile.identifier = tileID
    swelling.addSubview(tile)
    holder.addSubview(swelling)
    return holder
}

/// The glass in a folder's window (`holder`) at `opacity`, as Mission Control fades Finder's icons: the folder fades,
/// and the cover with it, which then takes about as much of Finder's fading picture off as there is (fading the
/// window instead would leave the cover taking a whole picture off a fading one: a dark rim ghost mid-fade).
func fade(_ holder: NSView, _ opacity: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for id in [coverID, patchID, standInEdgeID, standInID, swellID] { views(holder, id).forEach { $0.layer?.opacity = Float(opacity) } }  // (the stand-in comes and goes inside: setStandIn)
    CATransaction.commit()
}

/// Bring a folder's glass (its window's contents, `view`) back, gently: a cross-fade from Finder's own icon.
func fadeIn(_ view: NSView) {
    view.alphaValue = 0
    view.isHidden = false
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        view.animator().alphaValue = 1
    }
}

/// Every view in `view` (itself included) with the given identifier.
func views(_ view: NSView, _ id: NSUserInterfaceItemIdentifier) -> [NSView] {
    (view.identifier == id ? [view] : []) + view.subviews.flatMap { views($0, id) }
}

// -- the front pane

/// The perspective map, in the folder's own points (y up), that keeps the front pane's left side and bottom where they
/// are and moves its top-right corner `open` of the way it comes away while something is dragged over the folder.
func paneMap(_ open: CGFloat) -> CATransform3D {
    let box = frontOutline(designSize).bounds
    return warp(box: box, topRight: CGPoint(x: box.maxX - open * swing.across * box.width, y: box.maxY - open * swing.down * box.height))
}

/// `path` as the front pane carries it when tipped `open`.
func warped(_ path: NSBezierPath, _ open: CGFloat) -> NSBezierPath {
    guard open != 0 else { return path }
    let m = paneMap(open)
    func map(_ p: NSPoint) -> NSPoint {
        let w = p.x * m.m14 + p.y * m.m24 + m.m44
        return NSPoint(x: (p.x * m.m11 + p.y * m.m21 + m.m41) / w, y: (p.x * m.m12 + p.y * m.m22 + m.m42) / w)
    }
    let out = NSBezierPath()
    var points = [NSPoint](repeating: .zero, count: 3)
    for i in 0..<path.elementCount {
        switch path.element(at: i, associatedPoints: &points) {
        case .moveTo: out.move(to: map(points[0]))
        case .lineTo: out.line(to: map(points[0]))
        case .cubicCurveTo: out.curve(to: map(points[2]), controlPoint1: map(points[0]), controlPoint2: map(points[1]))
        case .quadraticCurveTo: out.curve(to: map(points[1]), controlPoint1: map(points[0]), controlPoint2: map(points[0]))
        case .closePath: out.close()
        @unknown default: break
        }
    }
    return out
}

/// The perspective transform that keeps `box`'s bottom-left, bottom-right and top-left corners where they are and
/// moves its top-right corner to `topRight` (Heckbert's square-to-quad mapping, after a mapping of the box onto the
/// unit square). Layer transforms map a point as a row vector, so a 2D perspective [[a b c] [d e f] [g h 1]] fills
/// m11 m12 m14 / m21 m22 m24 / m41 m42 m44.
func warp(box: CGRect, topRight: CGPoint) -> CATransform3D {
    let (x0, y0) = (box.minX, box.minY), (x1, y1) = (box.maxX, box.minY)  // bottom left, bottom right
    let (x2, y2) = (topRight.x, topRight.y), (x3, y3) = (box.minX, box.maxY)  // top right (moved), top left
    let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
    let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
    let det = dx1 * dy2 - dx2 * dy1
    let g = (dx3 * dy2 - dx2 * dy3) / det, h = (dx1 * dy3 - dx3 * dy1) / det
    let square = [[x1 - x0 + g * x1, y1 - y0 + g * y1, g],  // unit square -> quad, as rows (u v 1) -> (x y w)
                  [x3 - x0 + h * x3, y3 - y0 + h * y3, h],
                  [x0, y0, 1]]
    let unit = [[1 / box.width, 0, 0], [0, 1 / box.height, 0], [-box.minX / box.width, -box.minY / box.height, 1]]  // box -> unit square
    let m = (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0) { $0 + unit[r][$1] * square[$1][c] } } }
    var t = CATransform3DIdentity
    (t.m11, t.m12, t.m14) = (m[0][0], m[0][1], m[0][2])
    (t.m21, t.m22, t.m24) = (m[1][0], m[1][1], m[1][2])
    (t.m41, t.m42, t.m44) = (m[2][0], m[2][1], m[2][2])
    return t
}

/// Tip the front pane of the folder in `view` open (while something is dragged over it) or shut, on a spring,
/// from wherever it is now.
func setOpen(_ view: NSView, _ open: Bool) {
    guard let tile = views(view, tileID).first else { return }
    let from = openness(tile)
    movePane(tile, spring(from: from, to: open ? 1 : 0), after: 0)
}

/// Something was dropped in, `ago` seconds ago: the pane opens further and shuts, the folder swells, the sheets jump
/// (`first`: a first sheet, which drops in from above instead).
func playDrop(_ view: NSView, first: Bool, ago: Double) {
    guard let tile = views(view, tileID).first else { return }
    let from = openness(tile)
    let lid = stride(from: 0.0, through: dropLid.shut, by: frameStep).map { t -> CGFloat in
        let ease = { (u: Double) in CGFloat(u * u * (3 - 2 * u)) }
        return t < dropLid.at ? from + (dropLid.open - from) * ease(t / dropLid.at)
                              : dropLid.open * (1 - ease((t - dropLid.at) / (dropLid.shut - dropLid.at)))
    } + [0]
    movePane(tile, lid, after: -ago)
    swellFolder(view, after: dropSwell.delay - ago)
    popSheets(tile, after: (first ? firstSheetPop.delay : dropPop.delay) - ago, first: first)
}

/// How far open the pane of `tile` is right now, partway through a move if one is under way.
func openness(_ tile: NSView) -> CGFloat {
    guard let pane = views(tile, paneID).first?.layer, let path = pane.value(forKey: "liquidfolderOpenness") as? [CGFloat],
          let begin = pane.value(forKey: "liquidfolderBegin") as? CFTimeInterval, !path.isEmpty else { return 0 }
    let at = Int(((CACurrentMediaTime() - begin) / frameStep).rounded())
    return path[min(max(at, 0), path.count - 1)]
}

/// Move the front pane of `tile` through `path` (how far open, one step per `frameStep`), starting `delay` seconds from
/// now: the pane's glass, film and rim tip as one; the frost behind it and the film and frost around it are cut to
/// match at every step, so that nothing shows twice or not at all.
func movePane(_ tile: NSView, _ path: [CGFloat], after delay: Double) {
    guard let pane = views(tile, paneID).first?.layer else { return }
    let begin = CACurrentMediaTime() + delay, times = path.indices.map { NSNumber(value: Double($0) / Double(max(path.count - 1, 1))) }
    func animate(_ layer: CALayer, _ key: String, _ values: [Any]) {
        layer.setValue(values.last, forKeyPath: key)
        let move = CAKeyframeAnimation(keyPath: key)
        move.values = values
        move.keyTimes = times
        move.duration = max(frameStep, Double(path.count - 1) * frameStep)
        move.beginTime = begin
        move.fillMode = .backwards  // until it starts, as it was
        layer.add(move, forKey: key)
    }
    let anchor = CGPoint(x: pane.anchorPoint.x * pane.bounds.width, y: pane.anchorPoint.y * pane.bounds.height)  // transforms work from it
    let toAnchor = CATransform3DMakeTranslation(anchor.x, anchor.y, 0), fromAnchor = CATransform3DMakeTranslation(-anchor.x, -anchor.y, 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    animate(pane, "transform", path.map { NSValue(caTransform3D: CATransform3DConcat(CATransform3DConcat(toAnchor, paneMap($0)), fromAnchor)) })
    for (id, shape) in [(backFrostID, backFrostShape), (frontFrostID, frontFrostShape), (backFilmID, backFilmShape),
                        (sheetsBehindID, sheetsBehindShape), (sheetsTopsID, sheetsTopsShape), (shadeID, backFilmShape)] {
        for view in views(tile, id) { if let cut = shapeLayer(view) { animate(cut, "path", path.map { shape($0).cgPath }) } }
    }
    for shade in views(tile, shadeID).compactMap(\.layer) {  // the inside the pane uncovers lies in its shade
        animate(shade, "shadowPath", path.map { warped(frontOutline(designSize), $0).cgPath })
        animate(shade, "shadowOpacity", path.map { Float(swing.shade * min(1, max(0, $0))) })
    }
    pane.setValue(path, forKey: "liquidfolderOpenness")
    pane.setValue(begin, forKey: "liquidfolderBegin")
    CATransaction.commit()
}

/// A spring (stiffness 260, damping 20, mass 1, as CASpringAnimation has it), from `from` to `to`, one value per
/// `frameStep` until it has settled.
func spring(from: CGFloat, to: CGFloat) -> [CGFloat] {
    var x = Double(from - to), v = 0.0, path: [CGFloat] = []
    while path.count < 120 && (abs(x) > 1e-3 || abs(v) > 1e-2 || path.isEmpty) {
        path.append(to + CGFloat(x))
        for _ in 0..<8 { v += (-260 * x - 20 * v) * frameStep / 8; x += v * frameStep / 8 }
    }
    return path + [to]
}

// -- the swell

/// Swell the folder in `view`, `delay` seconds from now (or already that far through, if `delay` is negative).
func swellFolder(_ view: NSView, after delay: Double) {
    for swelling in views(view, swellID) {
        guard let layer = swelling.layer else { continue }
        let centre = CGPoint(x: (0.5 - layer.anchorPoint.x) * layer.bounds.width, y: (0.5 - layer.anchorPoint.y) * layer.bounds.height)
        let grow = CAKeyframeAnimation(keyPath: "transform")
        grow.values = dropSwell.values.map { s in
            NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(centre.x * (1 - s), centre.y * (1 - s), 0)))
        }
        grow.calculationMode = .cubic
        grow.duration = dropSwell.duration
        grow.beginTime = CACurrentMediaTime() + delay
        layer.add(grow, forKey: "swell")
    }
}

// -- the cover

/// Take Finder's picture (`picture`, as Finder puts it on screen) off whatever is under it: the window server's copy of
/// the screen below, with the picture's rim line taken out and then its film. Each is undone by a colour matrix, shown
/// as strongly as a mask says; where the rim's line is `r` strong over the film, and the matrix takes out a line
/// `rimLight.strength` strong (k), showing it r(1 - k) / (k(1 - r)) strong leaves exactly what was under the line.
func addUnpicture(_ layer: CALayer, _ picture: CGImage, colour: String, tint: CGFloat, scale: CGFloat) {
    guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }  // see addFrost
    for (mask, rows) in unpicture(picture, colour: colour, tint: tint) {
        let undo = backdropClass.init()
        undo.frame = layer.bounds
        undo.setValue(true, forKey: "windowServerAware")
        undo.filters = [compositorFilter("colorMatrix", ["inputColorMatrix": matrixValue(rows)])].compactMap { $0 }
        let shape = CALayer()
        shape.frame = undo.bounds
        shape.contents = mask
        shape.contentsScale = scale
        undo.mask = shape
        layer.addSublayer(undo)
    }
}

/// The undoing of `picture`, bottom first: each a mask and the colour matrix shown through it.
///
/// The compositor clips at black between layers, and a matrix taking out a line k strong goes below black wherever what
/// it sees is darker than k; a pixel's own line leaves it at least r bright. So the line is taken out in bands of
/// strength `rimBand` apart, each pixel by the band just above its own line, and nothing clips unless what lies under
/// the line is darker than about `rimBand`.
///
/// Where the rim's line runs over the film's edge, Finder's scaling blends the two in ways a line and a film alone can't
/// describe; what that leaves is the same small offset over anything, so it is taken out last, channel by channel.
func unpicture(_ picture: CGImage, colour: String, tint: CGFloat) -> [(mask: CGImage, rows: [[CGFloat]])] {
    typealias Channel = (gain: CGFloat, offset: CGFloat)  // each channel x becomes x * gain + offset
    let rimBand: CGFloat = 0.05, nudge: CGFloat = 0.1     // the largest offset a correction takes out
    let strongest = 1 - (1 - rimLight.strength) * (1 - rimLight.strength)  // where the front pane's line lies on the back's
    let bands = stride(from: rimBand, through: strongest + 2 * rimBand, by: rimBand).map { $0 }  // scaling overshoots a little
    let f = film(colour, tint), a = filmOpacity, fMean = f.reduce(0, +) / 3
    // (x - k) / (1 - k) takes out a white line k strong, (x - a f) / (1 - a) the film, x ± nudge an offset in one channel.
    let undoings: [[Channel]] = bands.map { k in [Channel](repeating: (1 / (1 - k), -k / (1 - k)), count: 3) }
        + [f.map { (1 / (1 - a), -a * $0 / (1 - a)) }]
        + [nudge, -nudge].flatMap { d in (0..<3).map { c in (0..<3).map { $0 == c ? (1, d) : (1, 0) } as [Channel] } }
    let filmStep = bands.count, corrections = filmStep + 1
    let w = picture.width, h = picture.height
    let source = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    source.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
    let seen = source.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    let masks = undoings.map { _ in
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
    }
    let shown = masks.map { $0.data!.bindMemory(to: UInt8.self, capacity: w * h) }
    let byte = { (x: CGFloat) in UInt8((min(1, max(0, x)) * 255).rounded()) }
    for i in 0..<(w * h) where seen[4 * i + 3] > 0 {
        // The picture here is a rim line r strong over the film q opaque: clear = (1 - r)(1 - q), colour = r + (1 - r) q f.
        let clear = 1 - CGFloat(seen[4 * i + 3]) / 255
        let light = CGFloat(Int(seen[4 * i]) + Int(seen[4 * i + 1]) + Int(seen[4 * i + 2])) / 765  // colour, mean of the channels
        var q = min(a, max(0, (1 - clear - light) / (1 - clear * fMean - light)))
        var r = 1 - clear / (1 - q)
        if r < 0 || r > bands.last! {  // keep (1 - r)(1 - q) = clear exactly, so that nothing is left over light or dark alike
            r = min(bands.last!, max(0, r))
            q = min(a, max(0, 1 - clear / (1 - r)))
        }
        shown[filmStep][i] = byte(q * (1 - a) / (a * (1 - q)))  // the film q opaque, taken out by a matrix for a
        var steps = [filmStep]
        if r > 0.5 / 255, let band = bands.firstIndex(where: { $0 >= r }) {
            shown[band][i] = byte(r * (1 - bands[band]) / (bands[band] * (1 - r)))
            steps.insert(band, at: 0)
        }
        for c in 0..<3 {  // what the steps leave over black, as shown: the offset to take out
            var left = CGFloat(seen[4 * i + c]) / 255
            for step in steps {
                let mix = CGFloat(shown[step][i]) / 255, map = undoings[step][c]
                left += mix * (map.gain * left + map.offset - left)
            }
            shown[corrections + c + (left > 0 ? 3 : 0)][i] = byte(abs(left) / nudge)
        }
    }
    return zip(masks, undoings).map { mask, channels in
        let rows: [[CGFloat]] = channels.enumerated().map { c, map in (0..<4).map { $0 == c ? map.gain : 0 } + [map.offset] }
        return (mask.makeImage()!, rows + [[0, 0, 0, 1, 0]])
    }
}

// -- the sheets

/// Play the drop on the sheets in `view`, `delay` seconds from now (or already that far through, if negative).
func popSheets(_ view: NSView, after delay: Double, first: Bool) {
    let pop = first ? firstSheetPop : dropPop
    let move = CAKeyframeAnimation(keyPath: "transform.translation.y")
    move.values = pop.values.map { $0 * designSize }
    move.keyTimes = pop.times
    let ease = { (name: CAMediaTimingFunctionName) in CAMediaTimingFunction(name: name) }
    move.timingFunctions = [ease(.easeIn), ease(.easeOut), ease(.easeInEaseOut)]
    move.duration = pop.duration
    move.beginTime = CACurrentMediaTime() + delay
    move.fillMode = .backwards  // a first sheet waits out of sight
    for sheets in sheetViews(view) {
        sheets.layer?.add(move, forKey: "drop")
        guard first else { continue }
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.1
        appear.beginTime = move.beginTime
        appear.fillMode = .backwards
        sheets.layer?.add(appear, forKey: "appear")
    }
}
