import AppKit

// The Desktop picture under each glass folder (setPicture): the very pixels Finder's icon hides, so laid over it they
// show nothing but the Desktop. Only a still picture filling the main screen; any other (dynamic, aerial, fitted,
// tiled) keeps the cover. Found and cut off the main queue (asking for it takes ~7 ms), kept small: one square a folder.

struct Wallpaper: Equatable {
    let url: URL, modified: Date?, screen: CGRect, scale: CGFloat

    /// Nil unless `screen` shows one still picture, scaled to fill.
    /// shortcut: an aerial is told apart by where its video lives; if one ever passes as a still, ask how it's reported.
    static func current(_ screen: NSScreen) -> Wallpaper? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL,
              !url.path.localizedCaseInsensitiveContains("aerial"), !url.path.contains("idleassetsd"),
              let options = NSWorkspace.shared.desktopImageOptions(for: screen),
              (options[.imageScaling] as? NSNumber)?.uintValue == NSImageScaling.scaleProportionallyUpOrDown.rawValue,
              (options[.allowClipping] as? NSNumber)?.boolValue == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1 else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Wallpaper(url: url, modified: modified, screen: screen.frame, scale: screen.backingScaleFactor)
    }

    /// Each of `rects` (screen points, y up) as the screen shows it, at its scale. Decodes the whole picture: slow.
    func crops(_ rects: [String: CGRect]) -> [String: CGImage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = (props[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              var h = (props[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat($0.doubleValue) }) else { return [:] }
        if ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 { swap(&w, &h) }  // turned a quarter
        let fill = max(screen.width / w, screen.height / h), shown = CGSize(width: w * fill, height: h * fill)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(shown.width, shown.height) * scale] as CFDictionary),
              let space = image.colorSpace else { return [:] }
        let k = CGFloat(image.width) / shown.width  // picture pixels per point
        let left = screen.minX + (screen.width - shown.width) / 2, top = screen.maxY - (screen.height - shown.height) / 2
        var cut: [String: CGImage] = [:]
        for (path, rect) in rects {
            // Copied, not cropping(to:): a crop would keep the whole decoded picture alive.
            guard let canvas = CGContext(data: nil, width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()),
                                         bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            canvas.interpolationQuality = .high
            let s = scale / k  // canvas pixels per picture pixel
            let size = CGSize(width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)  // y up: top row at the top
            canvas.draw(image, in: CGRect(x: (left - rect.minX) * scale, y: (top - rect.minY) * scale - size.height, width: size.width, height: size.height))
            cut[path] = canvas.makeImage()
        }
        return cut
    }
}

/// The screen rect (points, y up, whole pixels) the stand-in's picture covers for an icon at `icon`.
func pictureRect(_ icon: CGRect, scale: CGFloat) -> CGRect {
    let over = icon.insetBy(dx: -plainReach * icon.width, dy: -plainReach * icon.width)
    let pixels = CGRect(x: over.minX * scale, y: over.minY * scale, width: over.width * scale, height: over.height * scale).integral
    return CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
}

/// Each glass folder's picture, cut one batch at a time.
final class Pictures {
    private var wallpaper: Wallpaper?
    private var failed: Wallpaper?  // couldn't be cut: not tried again
    private var cut: [String: (rect: CGRect, image: CGImage)] = [:]
    private var cutting = false
    private var known = false       // until the first check, pictures may come
    private let work = DispatchQueue(label: "io.github.zupersun.liquidfolder.pictures", qos: .userInitiated)

    /// Whether pictures can be cut, as of the last check (before one: maybe, so new glass waits for it).
    var usable: Bool { !known || (wallpaper != nil && wallpaper != failed) }

    /// The picture for `path` at `rect`, if cut.
    func picture(_ path: String, _ rect: CGRect) -> CGImage? { cut[path].flatMap { $0.rect == rect ? $0.image : nil } }

    /// Check the wallpaper, then cut what `wanted` (path: rect) lacks; `ready` gets the paths cut, on the main queue.
    /// A changed wallpaper drops every picture: `ready` then gets them all, to take them off until cut again.
    func cut(_ wanted: [String: CGRect], ready: @escaping ([String]) -> Void) {
        guard let screen = NSScreen.screens.first else { return }
        work.async { [weak self] in
            let now = Wallpaper.current(screen)
            DispatchQueue.main.async { self?.checked(now, wanted, ready) }
        }
    }

    private func checked(_ now: Wallpaper?, _ wanted: [String: CGRect], _ ready: @escaping ([String]) -> Void) {
        known = true
        if now == nil || now == failed { ready([]) }  // none will come: glass held for one shows now
        if now != wallpaper {
            let dropped = Array(cut.keys)
            (wallpaper, cut) = (now, [:])
            if !dropped.isEmpty { ready(dropped) }
        }
        let missing = wanted.filter { cut[$0.key]?.rect != $0.value }
        guard let now, now == wallpaper, now != failed, !cutting, !missing.isEmpty else { return }
        cutting = true
        work.async { [weak self] in
            let images = now.crops(missing)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cutting = false
                guard self.wallpaper == now else { return }
                if images.isEmpty { self.failed = now }
                for (path, image) in images { self.cut[path] = (missing[path]!, image) }
                ready(Array(images.keys))
            }
        }
    }

    func forget(_ path: String) { cut[path] = nil }
}

extension Liquify {
    /// Cut the Desktop picture under each glass window lacking one; each goes to its stand-in as it comes.
    func cutPictures() {
        var wanted: [String: CGRect] = [:]
        for (path, frame) in icons where tiles[path] != nil { wanted[path] = pictureRect(frame, scale: scale(of: frame)) }
        pictures.cut(wanted) { [weak self] paths in
            guard let self else { return }
            paths.forEach(givePicture)
            if !paths.isEmpty { cutPictures() }  // more may have come meanwhile
            if !pictures.usable { Array(awaiting.keys).forEach(reveal) }  // none will come
        }
    }

    /// Give `path`'s stand-in its picture for where its window is now (none if not cut), and show it if held back.
    func givePicture(_ path: String) {
        guard let window = tiles[path], let holder = window.contentView, let frame = icons[path] else { return }
        let rect = pictureRect(frame, scale: window.backingScaleFactor)
        setPicture(holder, pictures.picture(path, rect), rect: rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY))
        reveal(path)
    }

    /// Show a window held back for its picture: a new one at once, one that stepped aside fading in.
    func reveal(_ path: String) {
        guard let fades = awaiting.removeValue(forKey: path), let holder = tiles[path]?.contentView else { return }
        if fades { fadeIn(holder) } else { holder.alphaValue = 1 }
    }

    /// Finder's Desktop selection changed: a selected folder's picture gives way to Finder's box (see setStandIn).
    func selectionChanged() {
        guard let states = finder.selected(among: tiles.keys.map { ($0 as NSString).lastPathComponent }) else { return }
        for (path, window) in tiles {
            if let selected = states[(path as NSString).lastPathComponent], let holder = window.contentView { reselect(holder, selected) }
        }
    }
}
