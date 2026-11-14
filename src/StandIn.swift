import AppKit

// The stand-in: Finder sometimes redraws a glass folder as its plain icon, which the cover can't take off. For those
// moments a stand-in hides it with the screen around the icon, icon cut out, blurred in.

// Measured: Finder shows the plain icon 0.3–1 s after a window showing the folder opens, closes or has something
// dragged out, for 0.6–2.2 s; and on about one drop in eleven, for 0.33 s.
let finderRedraw = 4.5  // s, after a window showing the folder opens, closes or changes
let countRedraw = 2.0    // s, after a drop or a change in contents with no window showing it
let standInBlur: CGFloat = 0.35   // of icon size; at 0.2 the middle of the hole is too far from anything to fill
let standInReach: CGFloat = 0.8   // of icon size: how far around the icon it samples (and the window's room)
let standInID = NSUserInterfaceItemIdentifier("stand-in")
// Under it, a finer stand-in for the band just past the folder's edge: so little blur that no frosted ring shows.
let standInEdgeID = NSUserInterfaceItemIdentifier("stand-in edge")
let edgeBlur: CGFloat = 0.05  // of icon size

/// The screen around, blurred by `radius`, shown within `mask`. Alpha set to 1 after the blur divides colour by
/// coverage (the compositor's matrix works on un-premultiplied colour), so the cut-out hole fills in smoothly.
private func sampleLayer(_ frame: CGRect, radius: CGFloat, mask: CALayer, backdrop: CALayer.Type) -> CALayer {
    let made = CALayer()  // rendered on its own, so it has see-through pixels to blur
    made.frame = frame
    made.opacity = 0  // shown only while Finder may redraw (setStandIn)
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
    func over() -> CALayer {  // where Finder's plain icon can draw, soft-edged
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

/// Cut what the stand-in samples: the screen around, minus the icon (as large as the plain one draws) and `others`.
/// A `selected` folder samples only inside Finder's selection box, which darkens to ~70%. `selected` nil: as last cut.
/// Sampled 1 pt inside the box (measured 6.5 pt around, corners 10.5). shortcut: measured at 116 pt only, re-measure
/// if a selected stand-in shows the box's edge.
func cutStandIn(_ holder: NSView, icon: CGRect, others: [CGRect], selected: Bool? = nil) {
    guard let made = views(holder, standInID).first?.layer?.sublayers?.first, let shape = made.sublayers?.first?.mask as? CAShapeLayer else { return }
    let selected = selected ?? (shape.value(forKey: "liquidfolderSelected") as? Bool ?? false)
    shape.setValue(selected, forKey: "liquidfolderSelected")
    shape.setValue(NSValue(rect: icon), forKey: "liquidfolderIcon")
    shape.setValue(others.map { NSValue(rect: $0) }, forKey: "liquidfolderOthers")
    let place = NSAffineTransform(), pixels = icon.width * (made.mask?.contentsScale ?? 2)
    place.translateX(by: icon.midX, yBy: icon.midY)
    place.scale(by: 1.12 + 2 / (188.5 / units * pixels))  // plain icon swells 8%, plus 4% and 2 px to spare
    place.translateX(by: -icon.width / 2, yBy: -icon.height / 2)
    // Union, not one path: opposite windings would cancel where a rect overlaps the outline and sample Finder's icon.
    let cuts = others.reduce(place.transform(outline(icon.width)).cgPath) { $0.union(CGPath(rect: $1, transform: nil)) }
    let k = min(1, icon.width / 116)  // box no larger than measured
    let area = selected ? CGPath(roundedRect: icon.insetBy(dx: -5.5 * k, dy: -5.5 * k), cornerWidth: 9.5 * k, cornerHeight: 9.5 * k, transform: nil)
                        : CGPath(rect: made.bounds, transform: nil)
    let near = NSAffineTransform()  // the plain icon at rest, and 2 px: kept out of the edge layer's sample
    near.translateX(by: icon.midX, yBy: icon.midY)
    near.scale(by: 1.05 + 2 / (188.5 / units * pixels))
    near.translateX(by: -icon.width / 2, yBy: -icon.height / 2)
    let edgeCuts = others.reduce(near.transform(outline(icon.width)).cgPath) { $0.union(CGPath(rect: $1, transform: nil)) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)  // at once: an animated re-cut would sample the icon
    shape.path = area.subtracting(cuts)
    (views(holder, standInEdgeID).first?.layer?.sublayers?.first?.sublayers?.first?.mask as? CAShapeLayer)?.path = area.subtracting(edgeCuts)
    CATransaction.commit()
    setPatch(holder, others: others)
}

/// Whether the stand-in in `holder` was last cut for a selected folder.
func cutSelected(_ holder: NSView) -> Bool? {
    (views(holder, standInID).first?.layer?.sublayers?.first?.sublayers?.first?.mask as? CAShapeLayer)?.value(forKey: "liquidfolderSelected") as? Bool
}

/// Re-cut the stand-in for Finder's selection now, around what it was last cut around.
func reselect(_ holder: NSView, _ selected: Bool) {
    guard let shape = views(holder, standInID).first?.layer?.sublayers?.first?.sublayers?.first?.mask as? CAShapeLayer,
          shape.value(forKey: "liquidfolderSelected") as? Bool != selected,
          let icon = (shape.value(forKey: "liquidfolderIcon") as? NSValue)?.rectValue,
          let others = (shape.value(forKey: "liquidfolderOthers") as? [NSValue])?.map(\.rectValue) else { return }
    cutStandIn(holder, icon: icon, others: others, selected: selected)
}

let plainReach: CGFloat = 0.12  // of icon size: room around it for the plain icon's largest shape, feathered
let tightGrowth: CGFloat = 1.02  // reach while the plain icon isn't animating: its own size and a pixel

/// How much the folder's outline is grown to cover Finder's plain icon `pixels` wide: swollen 8%, 8% more for the
/// feather's fall-off, and 2 px for small icons.
func plainGrowth(_ pixels: CGFloat) -> CGFloat { 1.16 + 2 / (188.5 / units * pixels) }

/// Mask of where Finder's plain icon can draw, `pixels` square, reaching `plainReach` around the icon.
/// Measured: a plain folder swells 7.6% on a drop and ~6% under a hover; feathered 1.5 pt at 116 pt.
func plainSilhouette(pixels: Int) -> CGImage? {
    let area = CGRect(x: 0, y: 0, width: pixels, height: pixels), span = designSize * (1 + 2 * plainReach)
    let icon = CGFloat(pixels) / (1 + 2 * plainReach), feather = 0.013 * icon
    let grown = NSAffineTransform()  // about the middle
    grown.translateX(by: span / 2, yBy: span / 2)
    grown.scale(by: plainGrowth(icon))
    grown.translateX(by: -designSize / 2, yBy: -designSize / 2)
    let shape = silhouette(grown.transform(outline(designSize)), area, pixels: area.width / span)
        .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: area)
        .applyingFilter("CIMaskToAlpha")
    return context.createCGImage(shape, from: area)
}

/// Fade the stand-in in (`up`) or out, or switch at `once` (a window just laid out afresh). Stays until set again.
/// `wide`: cover the plain icon as large as its drop and hover animations make it; else just the folder's outline.
func setStandIn(_ holder: NSView, _ up: Bool, once: Bool = false, wide: Bool = true) {
    for layer in (views(holder, standInEdgeID) + views(holder, standInID)).compactMap({ $0.layer?.sublayers?.first }) {
        let middle = layer.superlayer === views(holder, standInID).first?.layer
        let from = layer.presentation()?.opacity ?? layer.opacity, to: Float = up ? 1 : 0
        CATransaction.begin()  // opacity and fade together, or the new opacity shows a frame early
        CATransaction.setDisableActions(true)
        if up, middle, let mask = layer.mask {  // the mask is made wide; scaled down it hugs the outline
            let pixels = mask.frame.width / (1 + 2 * plainReach) * mask.contentsScale, k = wide ? 1 : tightGrowth / plainGrowth(pixels)
            mask.transform = CATransform3DMakeScale(k, k, 1)
        }
        layer.opacity = to
        if !once && from != to {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = up ? 0.1 : 0.3  // in fast: the plain icon can come 0.23 s after its window
            fade.fillMode = .backwards  // a frame drawn before the fade starts shows its start value
            layer.add(fade, forKey: "stand in")
        } else {
            layer.removeAnimation(forKey: "stand in")  // else an older opposite fade plays on
        }
        CATransaction.commit()
    }
}
