import AppKit

// -- Finder's redraw

/// Finder sometimes redraws a glass folder as its plain blue icon for a second or two: when a window showing the folder
/// opens or closes (a spring-loaded one too) and after something is dragged out of that window (0.3–1 s after, for
/// 0.6–2.2 s; its own doing, with or without this app: measured on an iCloud Desktop); now and then also as
/// a drop lands (once in eleven, for 0.33 s from the count's change, with no window open). The cover, made for
/// Finder's glass picture, can't take that off. So for those moments a stand-in lies over Finder's icon instead: the
/// screen around the icon, with the icon (and any other icon nearby) cut out, blurred and made opaque again by a colour
/// matrix, which divides the blurred colour by the blurred coverage (the compositor's colour matrix works on
/// un-premultiplied colour): the wallpaper as it goes on around the icon, filled in smoothly. Nothing of Finder's icon
/// reaches the glass then, whatever Finder draws; the frost is only smoother for a moment.
let finderRedraw = 4.5  // after a window showing the folder opens, closes or changes
let countRedraw = 2.0    // after a drop, or any change in what the folder holds with no window showing it
let standInBlur: CGFloat = 0.35   // of the icon's size; at 0.2 the middle of the hole is too far from anything to fill
let standInReach: CGFloat = 0.8   // of the icon's size, around it: what the stand-in is made from (and the window's room)
let standInID = NSUserInterfaceItemIdentifier("stand-in")
// Under it, a finer stand-in for the band just past the folder's edge, where the wallpaper is close by to sample: so
// little blur that it shows the wallpaper as it is there. (The strong blur the middle needs would show a frosted ring.)
let standInEdgeID = NSUserInterfaceItemIdentifier("stand-in edge")
let edgeBlur: CGFloat = 0.05  // of the icon's size

/// The screen around, blurred `radius` and made opaque again (see above), shown within `mask`; sampled as cut (cutStandIn).
private func sampleLayer(_ frame: CGRect, radius: CGFloat, mask: CALayer, backdrop: CALayer.Type) -> CALayer {
    let made = CALayer()  // rendered on its own by the compositor, so it has see-through pixels to blur
    made.frame = frame
    made.opacity = 0  // only while Finder may redraw: see setStandIn
    let around = backdrop.init()
    around.frame = made.bounds
    around.setValue(true, forKey: "windowServerAware")
    around.mask = CAShapeLayer()
    made.addSublayer(around)
    made.filters = [compositorFilter("gaussianBlur", ["inputRadius": radius, "inputNormalizeEdges": true]),
                    compositorFilter("colorMatrix", ["inputColorMatrix": matrixValue([[1, 0, 0, 0, 0], [0, 1, 0, 0, 0], [0, 0, 1, 0, 0], [0, 0, 0, 0, 1]])])].compactMap { $0 }
    made.mask = mask
    return made
}

func addStandIn(_ holder: NSView, icon: CGRect, others: [CGRect], selected: Bool = false, scale: CGFloat) {
    guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }  // see addFrost
    let silhouette = plainSilhouette(pixels: Int((icon.width * (1 + 2 * plainReach) * scale).rounded()))
    func over() -> CALayer {  // where Finder's plain icon can draw, softly edged so the stand-in melts into what is around it
        let over = CALayer()
        over.frame = icon.insetBy(dx: -plainReach * icon.width, dy: -plainReach * icon.width)
        over.contents = silhouette
        over.contentsScale = scale
        return over
    }
    var below = views(holder, coverID).first
    for (id, radius) in [(standInEdgeID, edgeBlur), (standInID, standInBlur)] {
        let view = NSView(frame: holder.bounds)
        view.layer = CALayer()
        view.wantsLayer = true
        view.identifier = id
        view.layer!.addSublayer(sampleLayer(view.bounds, radius: radius * icon.width, mask: over(), backdrop: backdropClass))
        holder.addSubview(view, positioned: .above, relativeTo: below)
        below = view
    }
    cutStandIn(holder, icon: icon, others: others, selected: selected)
}

/// What the stand-in samples: the screen around, but not the folder's icon as large as Finder's plain one can draw
/// (swollen 8%, with 4% and 2 px to spare) — the rest of the icon's square is left in, for it holds what lies right by
/// the folder — nor the `others` nearby (icons, names). A `selected` folder lies in Finder's selection box, which darkens
/// what is under it (to ~70%): then only what is inside the box is sampled. shortcut: the box measured at 116 pt only
/// (6.5 pt around the icon, corners 10.5 pt); measure again if a selected folder's stand-in shows its edge.
/// `selected` nil: as last cut. What it is cut with is kept, for reselect.
func cutStandIn(_ holder: NSView, icon: CGRect, others: [CGRect], selected: Bool? = nil) {
    guard let made = views(holder, standInID).first?.layer?.sublayers?.first, let shape = made.sublayers?.first?.mask as? CAShapeLayer else { return }
    let selected = selected ?? (shape.value(forKey: "liquidfolderSelected") as? Bool ?? false)
    shape.setValue(selected, forKey: "liquidfolderSelected")
    shape.setValue(NSValue(rect: icon), forKey: "liquidfolderIcon")
    shape.setValue(others.map { NSValue(rect: $0) }, forKey: "liquidfolderOthers")
    let place = NSAffineTransform(), pixels = icon.width * (made.mask?.contentsScale ?? 2)
    place.translateX(by: icon.midX, yBy: icon.midY)
    place.scale(by: 1.12 + 2 / (188.5 / units * pixels))
    place.translateX(by: -icon.width / 2, yBy: -icon.height / 2)
    // Joined shape by shape: in one path, the outline and a rect over it run opposite ways and cancel where they overlap,
    // which sampled Finder's icon there (a new file's name lying over the folder, say).
    let cuts = others.reduce(place.transform(outline(icon.width)).cgPath) { $0.union(CGPath(rect: $1, transform: nil)) }
    let k = min(1, icon.width / 116)  // (smaller icons: a box no larger than measured, in case Finder's shrinks with them)
    let area = selected ? CGPath(roundedRect: icon.insetBy(dx: -5.5 * k, dy: -5.5 * k), cornerWidth: 9.5 * k, cornerHeight: 9.5 * k, transform: nil)
                        : CGPath(rect: made.bounds, transform: nil)
    let near = NSAffineTransform()  // the plain icon, not swelling, and 2 px: what the edge layer must not sample
    near.translateX(by: icon.midX, yBy: icon.midY)
    near.scale(by: 1.05 + 2 / (188.5 / units * pixels))
    near.translateX(by: -icon.width / 2, yBy: -icon.height / 2)
    let edgeCuts = others.reduce(near.transform(outline(icon.width)).cgPath) { $0.union(CGPath(rect: $1, transform: nil)) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)  // at once: a re-cut sliding over a quarter second would sample what it must not
    shape.path = area.subtracting(cuts)
    (views(holder, standInEdgeID).first?.layer?.sublayers?.first?.sublayers?.first?.mask as? CAShapeLayer)?.path = area.subtracting(edgeCuts)
    CATransaction.commit()
    setPatch(holder, others: others)  // (the patch keeps out the same)
}

/// Whether the stand-in in `holder` was last cut for a selected folder.
func cutSelected(_ holder: NSView) -> Bool? {
    (views(holder, standInID).first?.layer?.sublayers?.first?.sublayers?.first?.mask as? CAShapeLayer)?.value(forKey: "liquidfolderSelected") as? Bool
}

/// The stand-in re-cut for Finder's selection as it is now, around what it was last cut around (nothing asked of Finder).
func reselect(_ holder: NSView, _ selected: Bool) {
    guard let shape = views(holder, standInID).first?.layer?.sublayers?.first?.sublayers?.first?.mask as? CAShapeLayer,
          shape.value(forKey: "liquidfolderSelected") as? Bool != selected,
          let icon = (shape.value(forKey: "liquidfolderIcon") as? NSValue)?.rectValue,
          let others = (shape.value(forKey: "liquidfolderOthers") as? [NSValue])?.map(\.rectValue) else { return }
    cutStandIn(holder, icon: icon, others: others, selected: selected)
}

let plainReach: CGFloat = 0.12  // of the icon's size, around it: room for the plain icon's largest shape, feathered
let tightGrowth: CGFloat = 1.02  // the stand-in's reach when Finder's plain icon isn't animating: its own size, and a pixel

/// How much larger than the folder's outline, about its middle, Finder's plain icon is covered, for an icon `pixels`
/// wide: a plain icon swollen 8%, and 8% more so that the feather's fall-off (about 2.3 feathers at the bottom) lies
/// beyond it; and 2 px more, for small icons' pixels.
func plainGrowth(_ pixels: CGFloat) -> CGFloat { 1.16 + 2 / (188.5 / units * pixels) }

/// Where Finder's plain icon can draw, as a mask `pixels` square (`point` pixels to the point) over the icon and
/// `plainReach` around it: the folder's outline
/// (the plain icon has the same) as large as Finder's own animations make it (a plain folder swells 7.6% on a drop and
/// opens about 6% larger while something hovers over it; its redraw was seen mid-way, ~4% out), with room,
/// feathered (1.5 pt at 116 pt) so that the stand-in melts into what is around it.
func plainSilhouette(pixels: Int) -> CGImage? {
    let area = CGRect(x: 0, y: 0, width: pixels, height: pixels), span = designSize * (1 + 2 * plainReach)
    let icon = CGFloat(pixels) / (1 + 2 * plainReach), feather = 0.013 * icon  // of the icon: as the margin past a swollen icon is
    let grown = NSAffineTransform()  // about the middle, in the folder's points, with the room around it
    grown.translateX(by: span / 2, yBy: span / 2)
    grown.scale(by: plainGrowth(icon))
    grown.translateX(by: -designSize / 2, yBy: -designSize / 2)
    let shape = silhouette(grown.transform(outline(designSize)), area, pixels: area.width / span)  // white on black
        .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: area)
        .applyingFilter("CIMaskToAlpha")
    return context.createCGImage(shape, from: area)
}

/// Lay the stand-in over Finder's icon (`up`) or take it away, fading quickly, or at `once` (a window just laid out
/// afresh while one is up). It stays as it is set until set again: see Agent.standIn.
/// `wide`: its middle over Finder's plain icon as large as its drop and hover animations make it (during a drag or a drop);
/// else just over the folder's outline, and the finer edge layer over the band past it (no frosted ring shows there).
func setStandIn(_ holder: NSView, _ up: Bool, once: Bool = false, wide: Bool = true) {
    for layer in (views(holder, standInEdgeID) + views(holder, standInID)).compactMap({ $0.layer?.sublayers?.first }) {
        let middle = layer.superlayer === views(holder, standInID).first?.layer
        let from = layer.presentation()?.opacity ?? layer.opacity, to: Float = up ? 1 : 0
        CATransaction.begin()  // the new opacity and its fade in one go: apart, the new one reached the screen a frame early
        CATransaction.setDisableActions(true)
        if up, middle, let mask = layer.mask {  // (made wide: drawn smaller about the icon's centre, it hugs the outline)
            let pixels = mask.frame.width / (1 + 2 * plainReach) * mask.contentsScale, k = wide ? 1 : tightGrowth / plainGrowth(pixels)
            mask.transform = CATransform3DMakeScale(k, k, 1)
        }
        layer.opacity = to
        if !once && from != to {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = up ? 0.1 : 0.3  // up quickly: Finder's plain icon can come 0.23 s after its window
            fade.fillMode = .backwards  // a frame drawn before the fade's start shows where it starts, not where it ends
            layer.add(fade, forKey: "stand in")
        } else {
            layer.removeAnimation(forKey: "stand in")  // an older fade the other way would play on against the new state
        }
        CATransaction.commit()
    }
}
