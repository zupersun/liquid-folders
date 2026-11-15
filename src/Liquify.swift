import AppKit

// Liquify: keeps each glass folder's Finder icon and, on the Desktop, its live glass window in step.
// Idle until a folder, the Desktop or the settings change.

let desktopPath = resolved("~/Desktop")  // resolved, to match stored folder paths

final class Liquify {
    enum Watched: Equatable { case settings, desktop, folder(String) }
    struct Look: Equatable { let style: Style, sheets: Int }
    struct TileState: Equatable { let look: Look, icon: CGRect? }  // icon: Finder's frame, y down

    private var folders: [String: Style] = [:]
    private var shown: [String: Look] = [:]
    private var counts: [String: Int] = [:]
    var tiles: [String: GlassWindow] = [:]         // (these, and finder, also used in Wallpaper.swift)
    var icons: [String: CGRect] = [:]              // Finder's icon frame, on screen, y up
    let pictures = Pictures()                      // the Desktop picture under each (setPicture)
    var awaiting: [String: Bool] = [:]             // windows held back for their picture: fade in once shown?
    private var opened: String?                    // the folder tipped open: something is dragged over it
    // Deadlines are in uptime: a wall clock set back would stall them.
    private var settling: [String: TimeInterval] = [:]    // a drop plays on the folder
    private var standingIn: [String: TimeInterval] = [:]  // the stand-in covers Finder's icon
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var heardQuietly: Set<String> = []     // a window opened for these mid-drag: its close goes unheard
    private var othersChanged = false              // Desktop items came or went since the stand-ins were cut
    private let missionControl = MissionControlFade.shared
    private var tiled: [String: TileState] = [:]   // what each window shows now
    private var watches: [(Watched, DispatchSourceFileSystemObject)] = []
    private var monitors: [Any] = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var layoutDue = false, retryDue = false
    private var ticker: Timer?
    private var watchUntil: TimeInterval = 0
    private var pressing = false, lastPress: TimeInterval = 0
    private var iconDue: Set<String> = [], stepAsideTurn = 0
    private var tags: [String: Data?] = [:], givingUntil: [String: TimeInterval] = [:]
    private var onDesktop = Set(desktopFolders().keys)  // the Desktop's folders (file IDs) last seen: newer ones become glass
    private var mouseUp: TimeInterval = 0         // the event's own clock, also uptime
    private var pressedAt = CGPoint.zero
    private var pressedOn: String?
    private var moving: (path: String, from: CGRect?)?
    private var dragCount = 0         // drag pasteboard's change count before this press
    private var dragEnded: TimeInterval = 0
    private var iconTurn: [String: Int] = [:], clearedAt: [String: TimeInterval] = [:]
    private let dragBoard = NSPasteboard(name: .drag)
    let finder = FinderDesktop()

    init() {
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        watch(configURL.deletingLastPathComponent().path, .settings)
        watch(desktopPath, .desktop)
        // Icons move on mouse drags and View Options sliders, screen changes and Space switches.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in self?.pressed(event) } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.mouseUp = event.timestamp
            self?.layoutSoon()
        } as Any)
        tokens.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.watchClosely(for: 0.6) }))
        tokens.append((NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in self?.cutPictures(); self?.layoutSoon() }))  // its own wallpaper?
        if !finder.allowed {
            print("Without Accessibility permission, icons will update but there will be no live glass on the Desktop.")
        }
        dragCount = dragBoard.changeCount
        missionControl.show = { [weak self] opacity in self?.tiles.values.forEach { $0.contentView.map { fade($0, opacity) } } }
        finder.windowChanged = { [weak self] title in self?.windowChanged(title) }
        finder.selectionChanged = { [weak self] in self?.selectionChanged() }
        // Mid-drag no window title can be read: a spring-loaded window is for the open folder, else it could be any.
        finder.windowChangedQuietly = { [weak self] in
            guard let self else { return }
            for path in self.opened.map({ [$0] }) ?? Array(self.tiles.keys) {
                self.heardQuietly.insert(path)
                self.standIn(path)
            }
        }
        finder.watchWindows()
        applySettings()
    }

    deinit {  // no glass may stay over Finder's icons once switched off
        for window in tiles.values { window.orderOut(nil) }
        ticker?.invalidate()
        for (_, source) in watches { source.cancel() }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        for (centre, token) in tokens { centre.removeObserver(token) }
        missionControl.show = nil
    }

    // -- watching

    private func watch(_ path: String, _ meaning: Watched) {
        let events: DispatchSource.FileSystemEvent = meaning == .settings || meaning == .desktop ? [.write, .rename] : [.write, .rename, .attrib]
        guard let source = watchPath(path, events, { [weak self] seen, handle in
            if seen.contains(.rename), case .folder(let path) = meaning { followMove(path, handle) } else { self?.changed(meaning) }
        }) else { return }
        watches.append((meaning, source))
    }

    private func changed(_ meaning: Watched) {
        switch meaning {
        case .settings: applySettings()
        case .desktop:  // Finder re-sorts icons, and the stand-ins must clear new ones
            let now = desktopFolders()  // (by file ID: a renamed folder isn't new)
            liquifyArrivals(Set(now.filter { !onDesktop.contains($0.key) }.values))
            onDesktop = Set(now.keys)
            othersChanged = true
            watchClosely(for: 0.6)
        case .folder(let path):
            // Customised in Finder, not by this app: it stops being glass.
            if now > (givingUntil[path] ?? 0), customizedByUser(path) { try? removeFromConfig(path); return }
            if tagData(path) != tags[path] { tags[path] = tagData(path); standIn(path) }  // Finder redraws it plain
            refreshIcon(path)
        }
    }

    // -- settings

    private func applySettings() {
        if takeRequests() { finder.deselect(); return }  // saving the requests calls this again
        var wanted: [String: Style]
        do { wanted = try loadConfig() } catch { print(error); return }  // keep running on the last good settings
        for (path, style) in wanted {
            if let problem = problemWith(path: path, style: style) {
                print("Skipping \(path): \(problem)")
                wanted[path] = nil
            }
        }
        for path in folders.keys where wanted[path] == nil { forget(path) }
        let fresh = wanted.keys.contains { folders[$0] == nil }
        for (path, style) in wanted {
            if folders[path] == nil { watch(path, .folder(path)); tags[path] = tagData(path) }
            folders[path] = style
            refreshIcon(path)
        }
        if fresh && ticker == nil { layout() } else { layoutSoon() }  // a new glass folder shows at once
    }

    private func forget(_ path: String) {
        watches.removeAll { meaning, source in
            guard meaning == .folder(path) else { return false }
            source.cancel()  // also closes the handle
            return true
        }
        remove(path)
        tiled[path] = nil
        folders[path] = nil
        shown[path] = nil
        counts[path] = nil
        standingIn[path] = nil
        settling[path] = nil
        iconTurn[path] = (iconTurn[path] ?? 0) + 1  // cancels icons still on their way
    }

    // -- Finder's icon

    /// Recount and show the sheets. Skipped while dragged over or mid-drop: those recount when done.
    private func refreshIcon(_ path: String) {
        if path == opened || (settling[path] ?? 0) > now { return }
        guard let style = folders[path], let items = try? countItems(path, enough: .max) else { return }
        // Finder may redraw it plain when its contents change (surely with a window open; 1 in 11 drops without).
        if counts[path].map({ $0 != items }) == true { standIn(path, for: finder.showing(windowTitles(path)) ? finderRedraw : countRedraw) }
        counts[path] = items
        show(path, Look(style: style, sheets: sheetCount(items)))
    }

    private func show(_ path: String, _ look: Look) {
        let before = shown[path]
        guard before != look else { return }
        if before?.style == look.style { giveIconSoon(path, look.sheets) } else { giveIcon(path, look) }
        shown[path] = look
        if before?.style == look.style, let state = tiled[path], let window = tiles[path], let tile = window.contentView {
            let picture = paper(look.sheets, (state.icon?.width ?? designSize) * window.backingScaleFactor)
            sheetViews(tile).forEach { $0.image = picture }
            tiled[path] = TileState(look: look, icon: state.icon)
        } else {
            layoutSoon()
        }
    }

    /// Something was dropped on a glass folder `ago` seconds ago: play it now, recount after (it may fail or lag).
    private func dropped(on path: String, ago: Double) {
        guard let look = shown[path], let tile = tiles[path]?.contentView else { return }
        if opened != path { openFolder(nil) }
        opened = nil  // the drop shuts the pane itself
        standIn(path, for: countRedraw)  // Finder may redraw it plain as the drop lands
        show(path, Look(style: look.style, sheets: sheetCount((counts[path] ?? 0) + 1)))
        playDrop(tile, first: look.sheets == 0, ago: ago)
        tile.window?.displayIfNeeded()  // new sheets reach their layers only in a display pass
        CATransaction.flush()  // on screen before the main thread moves on
        let adding = dragBoard.pasteboardItems?.count ?? 1  // reading the files themselves may block on Finder
        show(path, Look(style: look.style, sheets: sheetCount((counts[path] ?? 0) + max(1, adding))))
        settling[path] = now + dropSettles
        DispatchQueue.main.asyncAfter(deadline: .now() + dropSettles + 0.05) { [weak self] in self?.refreshIcon(path) }
    }

    /// Set the custom icon unless its stamp matches. iCloud Desktop sees a replaced icon minutes late, a new one
    /// in seconds: so clear the old, then set 1.5 s later. Only the latest call (`turn`) lands.
    private func giveIcon(_ path: String, _ look: Look) {
        let style = look.style, key = iconKey(style, sheets: look.sheets), turn = (iconTurn[path] ?? 0) + 1
        iconTurn[path] = turn
        let stamp = iconStamp(path)
        guard stamp != key else { return }
        let replacing = FileManager.default.fileExists(atPath: path + "/" + iconFile)
        let wait = replacing ? 1.5 : max(0, (clearedAt[path] ?? -9) + 1.5 - now)
        standIn(path, for: wait + (stamp == nil ? 12 : finderRedraw))  // plain until Finder has it; a first is slow
        givingUntil[path] = now + wait + 3  // this app's change, not a customisation
        if replacing { DispatchQueue.main.async { [weak self] in  // after a drop's motion is on screen
            guard let self, iconTurn[path] == turn else { return }
            clearedAt[path] = now
            NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, iconTurn[path] == turn, folders[path] == style,
                  NSWorkspace.shared.setIcon(icon(style.colour, style.tint, sheets: look.sheets), forFile: path, options: []) else { return }
            setIconStamp(path, key)
            tiles[path]?.contentView.map { setPatch($0, sheets: [look.sheets]) }
        }
    }

    /// While its context menu is open: a tag picked there has Finder redraw it plain before this app hears.
    private func holdWhileMenu(_ path: String) {
        standIn(path, for: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in finderMenuOpen() ? self?.holdWhileMenu(path) : self?.standIn(path) }
    }

    /// Only the sheets changed: update Finder's icon once the mouse rests 8 s (a swap shows plain for seconds,
    /// drag images too). Until then the patch covers both.
    private func giveIconSoon(_ path: String, _ sheets: Int) {
        tiles[path]?.contentView.map { setPatch($0, sheets: [stampedSheets(path), sheets]) }
        guard iconDue.insert(path).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, iconDue.remove(path) != nil, let look = shown[path] else { return }
            if pressing || now - lastPress < 8 { giveIconSoon(path, look.sheets) } else { giveIcon(path, look) }
        }
    }

    /// A Finder window titled `title` opened, closed or navigated: Finder may redraw that folder plain.
    /// Untitled (""): a new window, named a moment later, so it could be any folder's.
    private func windowChanged(_ title: String) {
        for path in tiles.keys where title.isEmpty || windowTitles(path).contains(title) { standIn(path, for: title.isEmpty ? 0.7 : finderRedraw, recut: !title.isEmpty) }
    }

    /// Cover Finder's icon with the stand-in for at least `seconds`. `recut` nil: re-cut only if it wasn't up.
    private func standIn(_ path: String, for seconds: Double = finderRedraw, recut: Bool? = nil) {
        let until = max(standingIn[path] ?? 0, now + seconds), wasUp = (standingIn[path] ?? 0) > now
        standingIn[path] = until
        if let window = tiles[path], let holder = window.contentView {
            setStandIn(holder, true, wide: finder.quiet || now - dragEnded < 1.5)  // up first: Finder can be slow
            CATransaction.flush()
            // Re-cut around the current neighbours (Finder lists new icons late); never mid-drag.
            if recut ?? !wasUp, !finder.quiet, let frame = icons[path], let screen = NSScreen.screens.first?.frame {
                finder.everyFrame().map { cutStandIn(holder, icon: frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY), others: cuts(frame, window.frame, screen, $0),
                                                    selected: finder.selected((path as NSString).lastPathComponent)) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + until - now + 0.01) { [weak self] in
            guard let self, (self.standingIn[path] ?? 0) <= self.now, let holder = self.tiles[path]?.contentView else { return }
            setStandIn(holder, false)
        }
    }

    // -- Desktop glass

    /// Click-through window just above Finder's icons. Stationary, so it stays put when a wallpaper click moves
    /// windows aside; Mission Control would still show it, so MissionControlFade fades it.
    private func window(_ frame: CGRect, _ content: NSView) -> GlassWindow {
        let window = GlassWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none  // no close animation over its replacement
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        window.contentView = content
        window.orderFrontRegardless()
        window.forceActiveLook()
        return window
    }

    private func remove(_ path: String) {
        tiles.removeValue(forKey: path)?.orderOut(nil)
        icons[path] = nil
        pictures.forget(path)
        awaiting[path] = nil
        if opened == path { opened = nil }
    }

    /// Hide the glass so Finder's own icon shows (and moves) alone.
    private func stepAside(_ path: String) {
        tiles[path]?.contentView?.isHidden = true
    }

    /// The glass folder at `point` (on screen, y up), other than `except`, if no window covers the Desktop there.
    private func folder(at point: CGPoint, except: String?) -> String? {
        guard let path = icons.first(where: { $0.key != except && onFolder(point, $0.value, name: windowTitles($0.key)[0], items: counts[$0.key]) })?.key,
              desktopShows(point) else { return nil }
        return path
    }

    /// Tip `path`'s front pane open (nil: none), shutting the last one, which is recounted.
    private func openFolder(_ path: String?) {
        guard path != opened else { return }
        let left = opened
        if let left, let tile = tiles[left]?.contentView { setOpen(tile, false) }
        if let path, let tile = tiles[path]?.contentView { setOpen(tile, true) }
        opened = path
        if let left { refreshIcon(left) }
    }

    /// Coalesce events into one layout once Finder settles, and again after its resize animation ends.
    private func layoutSoon() {
        guard !layoutDue else { return }
        layoutDue = true
        for delay in [0.35, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.layout() }
        }
    }

    /// Mouse down: watch closely until it comes up. Heard late (a busy app), a drag may have begun:
    /// keep the drag count from the last mouse-up and use the event's own location.
    private func pressed(_ event: NSEvent) {
        pressedAt = event.locationInWindow  // on screen, for a global event
        pressedOn = icons.first(where: { onFolder(pressedAt, $0.value, name: windowTitles($0.key)[0], items: counts[$0.key]) })
            .flatMap { desktopShows(pressedAt) ? $0.key : nil }
        if now - event.timestamp < 0.05 { dragCount = dragBoard.changeCount }
        heardQuietly = []
        pressing = true
        lastPress = now
        // Finder selects on mouse down (not on the menu bar or Dock, nor on a selection: that is kept to drag).
        if event.modifierFlags.isDisjoint(with: [.command, .shift]) && desktopShows(pressedAt)
            && NSScreen.screens.first(where: { $0.frame.contains(pressedAt) })?.visibleFrame.contains(pressedAt) == true
            && pressedOn.flatMap({ tiles[$0]?.contentView }).flatMap(cutSelected) != true {
            for (path, window) in tiles { window.contentView.map { reselect($0, path == pressedOn) } }
        }
        if event.clickCount == 2, let pressedOn { standIn(pressedOn) }  // its window opens before Finder says so
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control), let pressedOn { holdWhileMenu(pressedOn) }
        watchClosely(for: 0)
    }

    /// Poll Finder's Desktop at 60 Hz for `seconds` and while the mouse is held. A window lags Finder by a frame,
    /// so the glass steps aside while Finder moves an icon, then is laid out afresh and fades back in.
    private func watchClosely(for seconds: Double) {
        watchUntil = max(watchUntil, now + seconds)
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let finderInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        // Only a real drag writes the drag pasteboard (not a selection box, window move or slider).
        let dragging = dragBoard.changeCount != dragCount, at = NSEvent.mouseLocation
        // Ask Finder nothing during a drag or just after (asked at once, it twice left a moved folder hanging 2 s).
        var dropping = now - dragEnded < 0.3
        finder.quiet = (pressing && dragging) || dropping
        if pressing && NSEvent.pressedMouseButtons & 1 == 0 {  // released: a drop, or a slider let go
            pressing = false
            if dragging { (dragEnded, dropping) = (now, true) }
            dragCount = dragBoard.changeCount  // baseline for a press heard late
            if dragging {  // stand-ins up during the drag last a full redraw past its end
                for path in tiles.keys where (standingIn[path] ?? 0) > now { standIn(path) }
            }
            if finderInFront { watchUntil = max(watchUntil, now + 0.3) }  // Finder may still be settling its icons
            if dragging, let pressedOn {  // a glass folder moved: Finder reports its place up to 1 s later
                stepAside(pressedOn)
                watchUntil = max(watchUntil, now + 1)
                moving = (pressedOn, tiled[pressedOn]?.icon)
            }
            // shortcut: an Escape-cancelled drag over a folder still plays a drop, fix if cancels become detectable.
            if dragging, let path = folder(at: at, except: pressedOn) {
                let ago = now - mouseUp
                dropped(on: path, ago: ago >= 0 && ago < 0.05 ? ago : 0)
                return  // Finder is busy with the drop: ask it next tick
            }
            openFolder(nil)
        }
        if pressing && dragging {
            // Dragging out of a window showing a glass folder can make Finder redraw it plain: keep the stand-in up.
            for path in tiles.keys where (standingIn[path] ?? 0) < now + 1
                && (heardQuietly.contains(path) || finder.showing(windowTitles(path))) {
                standIn(path)
            }
            openFolder(folder(at: at, except: pressedOn))
        } else if (!pressing || finderInFront) && !dropping {
            stepAside()
        }
        if let moving, !pressing, !dropping, let name = Optional((moving.path as NSString).lastPathComponent),
           let frames = finder.frames([name]), frames[name] != moving.from {
            if frames[name] != nil { watchUntil = min(watchUntil, now) }  // landed: lay it out now
            self.moving = nil  // stop asking: an unknown name makes Finder scan the whole Desktop
        }
        if !pressing && !dropping && now >= watchUntil {
            moving = nil
            ticker?.invalidate()
            ticker = nil
            layout()
        }
    }

    /// Hide the glass of any icon Finder moved or resized since layout.
    private func stepAside() {
        let showing = tiles.keys.filter { tiles[$0]?.contentView?.isHidden == false }.sorted()
        guard finder.allowed, !showing.isEmpty else { return }
        // Light on Finder: ask about one folder per tick, all every 10th tick or once that one moved
        // (sliders and reflows move them together; a lone move is a drag, handled at mouse-up).
        stepAsideTurn += 1
        guard let first = finder.frames([(showing[0] as NSString).lastPathComponent]) else { return }
        let all = stepAsideTurn % 10 == 0 || first[(showing[0] as NSString).lastPathComponent] != tiled[showing[0]]?.icon
        guard let frames = all ? finder.frames(showing.map { ($0 as NSString).lastPathComponent }) : first else { return }
        for path in showing where (all || path == showing[0]) && frames[(path as NSString).lastPathComponent] != tiled[path]?.icon
            && !(pressing && path == pressedOn) { stepAside(path) }
    }

    /// Lay each glass window over its icon, with room around to sample, swell and drop a first sheet in.
    private func layout() {
        layoutDue = false
        guard ticker == nil else { return }  // tick lays out once things settle
        guard let screen = NSScreen.screens.first?.frame else { return }  // none briefly while displays change
        let desktop = folders.keys.filter { ($0 as NSString).deletingLastPathComponent == desktopPath && shown[$0] != nil }
        // No answer from Finder: keep the glass; the next mouse-up asks again, or one retry if glass stepped aside.
        guard let frames = finder.frames(desktop.map { ($0 as NSString).lastPathComponent }) else {
            if !retryDue, tiles.values.contains(where: { $0.contentView?.isHidden == true }) {
                retryDue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.retryDue = false; self?.layout() }
            }
            return
        }
        var others: [CGRect]?  // every icon's frame, read at most once
        let recut = othersChanged
        othersChanged = false
        for path in desktop {
            let icon = frames[(path as NSString).lastPathComponent], look = shown[path]!
            let state = TileState(look: look, icon: icon)
            var moved = false
            if let window = tiles[path], window.contentView?.isHidden == false, let old = tiled[path], old.look == look, let was = old.icon, let icon, was.size == icon.size, was != icon,
               let frame = Optional(appKit(icon, screen)), window.backingScaleFactor == scale(of: frame) {
                // Nudged by Finder, glass showing: move the window as is. A user move is redone and faded in
                // (moving and showing in one turn flashed a frame at the old place).
                window.setFrameOrigin(CGPoint(x: frame.minX - room(icon), y: frame.minY - room(icon)))
                icons[path] = frame
                givePicture(path)  // the old one is cut for the old place
                tiled[path] = state
                moved = true
            }
            if tiled[path] == state {  // most layouts: nothing moved
                if recut || moved || (standingIn[path] ?? 0) > now, let window = tiles[path], let holder = window.contentView, let frame = icons[path] {
                    if others == nil { others = finder.everyFrame() }
                    guard let others else { othersChanged = true; continue }  // no answer: re-cut next time
                    cutStandIn(holder, icon: frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY),
                               others: cuts(frame, window.frame, screen, others), selected: finder.selected((path as NSString).lastPathComponent))
                } else if let holder = tiles[path]?.contentView, let selected = finder.selected((path as NSString).lastPathComponent) {
                    reselect(holder, selected)  // kept current for a stand-in raised mid-drag
                }
                continue
            }
            // Refill a showing window in place: removing it first would bare Finder's icon for a frame.
            let stepped = tiles[path]?.contentView?.isHidden ?? false, reused = stepped ? nil : tiles[path]
            if reused == nil { remove(path) } else if opened == path { opened = nil }
            tiled[path] = state
            guard let icon else { remove(path); continue }  // off the Desktop now
            let frame = appKit(icon, screen), scale = scale(of: frame)
            if others == nil { others = finder.everyFrame() }
            if others == nil { othersChanged = true }  // no answer: cut without them, re-cut next time
            let around = frame.insetBy(dx: -room(icon), dy: -room(icon))
            let holder = glassHolder(around.size, icon: frame.offsetBy(dx: -around.minX, dy: -around.minY), others: cuts(frame, around, screen, others ?? []),
                                     selected: finder.selected((path as NSString).lastPathComponent) ?? (tiles[path]?.contentView.flatMap(cutSelected) ?? false),
                                     colour: look.style.colour, tint: look.style.tint, sheets: look.sheets, finderSheets: [stampedSheets(path), look.sheets], scale: scale)
            if (standingIn[path] ?? 0) > now { setStandIn(holder, true, once: true, wide: finder.quiet || now - dragEnded < 1.5) }
            let rect = pictureRect(frame, scale: scale), picture = pictures.picture(path, rect)
            setPicture(holder, picture, rect: rect.offsetBy(dx: -around.minX, dy: -around.minY))
            // Without its picture the glass would change as it comes: held back until cut (Finder's icon shows).
            let held = picture == nil && reused == nil && (stepped || (standingIn[path] ?? 0) > now) && pictures.usable
            if stepped || held { holder.alphaValue = 0 }  // fades in below: no full-strength first frame
            fade(holder, missionControl.shown)
            if let reused {
                reused.setFrame(around, display: false)
                reused.contentView = holder
                reused.forceActiveLook()
            } else {
                tiles[path] = window(around, holder)
            }
            icons[path] = frame
            if let tile = views(holder, tileID).first { tune(tile, tries: 10) }
            if held {
                awaiting[path] = stepped
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reveal(path) }  // not cut by then
            } else if stepped { tiles[path]?.contentView.map(fadeIn) }
        }
        for window in tiles.values where window.contentView?.isHidden == true {
            window.contentView.map(fadeIn)  // stepped aside, but its icon did not move
        }
        cutPictures()
    }
}
