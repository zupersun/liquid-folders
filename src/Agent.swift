import AppKit

// The background agent: gives each opted-in folder its glass icon (Finder's still picture of it) and, on the Desktop,
// the live glass folder in a window just above that icon. It sleeps until a folder, the Desktop or the settings change.

let desktopPath = resolved("~/Desktop")  // resolved, to match how folder paths are stored

/// Keeps every opted-in folder's icon and Desktop glass in step with its contents and settings.
final class Agent {
    enum Watched: Equatable { case settings, desktop, folder(String) }
    struct Look: Equatable { let style: Style, sheets: Int }
    struct TileState: Equatable { let look: Look, icon: CGRect? }  // icon: Finder's frame for it, y down

    private var folders: [String: Style] = [:]
    private var shown: [String: Look] = [:]        // each folder's look, with as many sheets as it holds
    private var counts: [String: Int] = [:]        // how many items each folder held when last counted
    private var tiles: [String: GlassWindow] = [:] // each Desktop folder's glass, in a window just above its icon
    private var icons: [String: CGRect] = [:]      // and Finder's icon for it, on screen in AppKit's coordinates (y up)
    private var opened: String?                    // the folder whose front pane is tipped open: something is over it
    // Until when (uptime, the clock the take-downs are timed on: a wall clock set back would leave them waiting):
    private var settling: [String: TimeInterval] = [:]    // a drop plays on the folder: see dropped
    private var standingIn: [String: TimeInterval] = [:]  // the stand-in lies over Finder's icon: see standIn
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var heardQuietly: Set<String> = []     // a window opened or turned for these during this drag: its close goes unheard
    private var othersChanged = false              // Desktop items came or went since the stand-ins were cut: see layout
    private let missionControl = MissionControlFade.shared
    private var tiled: [String: TileState] = [:]   // what each folder's windows currently show
    private var watches: [(Watched, DispatchSourceFileSystemObject)] = []
    private var monitors: [Any] = []                                  // NSEvent's, for the mouse
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []  // and notification centres'
    private var layoutDue = false, retryDue = false  // see layoutSoon, layout
    private var ticker: Timer?        // runs only while watching closely: see watchClosely
    private var watchUntil: TimeInterval = 0  // uptime
    private var pressing = false, lastPress: TimeInterval = 0  // the mouse button is down; when it last went down
    private var iconDue: Set<String> = [], stepAsideTurn = 0  // see giveIconSoon, stepAside
    private var tags: [String: Data?] = [:], givingUntil: [String: TimeInterval] = [:]  // see changed
    private var mouseUp: TimeInterval = 0         // when the button last came up, by the event's own clock (uptime)
    private var pressedAt = CGPoint.zero
    private var pressedOn: String?    // the glass folder the press was on (its icon or name, where the Desktop shows)
    private var moving: (path: String, from: CGRect?)?  // a glass folder Finder is moving, and where it was: see tick
    private var dragCount = 0         // the drag pasteboard's change count before this press (see pressed)
    private var dragEnded: TimeInterval = 0  // when the last real drag was let go (uptime): see tick
    private var iconTurn: [String: Int] = [:], clearedAt: [String: TimeInterval] = [:]  // see giveIcon
    private let dragBoard = NSPasteboard(name: .drag)
    private let finder = FinderDesktop()

    init() {
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        watch(configURL.deletingLastPathComponent().path, .settings)
        watch(desktopPath, .desktop)
        // Icons move or resize while the mouse is held in Finder (an icon drag, or the size and spacing
        // sliders in its View Options, which change them as they go), when items come and go, when the
        // screen changes, and between Spaces. The only timer runs while watching closely: see watchClosely.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in self?.pressed(event) } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.mouseUp = event.timestamp
            self?.layoutSoon()
        } as Any)
        tokens.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.watchClosely(for: 0.6) }))
        tokens.append((NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in self?.layoutSoon() }))
        if !finder.allowed {
            print("Without Accessibility permission, icons will update but there will be no live glass on the Desktop.")
        }
        dragCount = dragBoard.changeCount
        missionControl.show = { [weak self] opacity in self?.tiles.values.forEach { $0.contentView.map { fade($0, opacity) } } }  // (as Finder's icons)
        finder.windowChanged = { [weak self] title in self?.windowChanged(title) }
        // During a drag no window's title can be read: a spring-loaded window opening over the folder under the pointer is
        // for that folder; one turning to a folder inside a Finder window could be for any of them.
        finder.windowChangedQuietly = { [weak self] in
            guard let self else { return }
            for path in self.opened.map({ [$0] }) ?? Array(self.tiles.keys) {
                self.heardQuietly.insert(path)  // (kept over it while the drag lasts: see tick)
                self.standIn(path)
            }
        }
        finder.watchWindows()
        applySettings()
    }

    deinit {  // switched off: nothing of the glass may outlive the agent over Finder's icons
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
        case .desktop:  // Finder re-sorts the Desktop when items come and go; and the stand-ins must keep clear of new ones
            othersChanged = true
            watchClosely(for: 0.6)
        case .folder(let path):
            // Given a look of the user's own in Finder (Customize Folder, another icon), or its icon taken away, and not by
            // this app: it isn't glass any more, and Finder shows what they chose (the settings watch takes the glass away).
            if now > (givingUntil[path] ?? 0), customizedByUser(path) { try? removeFromConfig(path); return }
            if tagData(path) != tags[path] { tags[path] = tagData(path); standIn(path) }  // Finder redraws it plain for a moment
            refreshIcon(path)
        }
    }

    // -- settings

    private func applySettings() {
        if takeRequests() { finder.deselect(); return }  // Liquify or Unliquify: the folders saved (which calls this again)
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
        if fresh && ticker == nil { layout() } else { layoutSoon() }  // a folder just made glass shows it at once
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
        iconTurn[path] = (iconTurn[path] ?? 0) + 1  // (a picture still on its way stays away)
    }

    // -- the icon Finder shows

    /// The folder's contents or settings changed: more or fewer sheets are swapped in place. Not while something is
    /// over the folder or a drop plays on it: the drop (or the drag leaving) counts again itself, after the motion.
    private func refreshIcon(_ path: String) {
        if path == opened || (settling[path] ?? 0) > now { return }
        guard let style = folders[path], let items = try? countItems(path, enough: .max) else { return }  // gone: listed until removed
        // Finder may redraw the folder plain whenever what it holds changes (most surely after something is dragged out of
        // a window showing it; once in eleven drops measured, with no window open).
        if counts[path].map({ $0 != items }) == true { standIn(path, for: finder.showing(windowTitles(path)) ? finderRedraw : countRedraw) }
        counts[path] = items
        show(path, Look(style: style, sheets: sheetCount(items)))
    }

    private func show(_ path: String, _ look: Look) {
        let before = shown[path]
        guard before != look else { return }
        if before?.style == look.style { giveIconSoon(path, look.sheets) } else { giveIcon(path, look) }  // (Finder's shows the sheets too)
        shown[path] = look
        if before?.style == look.style, let state = tiled[path], let window = tiles[path], let tile = window.contentView {  // just the sheets
            let picture = paper(look.sheets, (state.icon?.width ?? designSize) * window.backingScaleFactor)
            sheetViews(tile).forEach { $0.image = picture }
            tiled[path] = TileState(look: look, icon: state.icon)
        } else {
            layoutSoon()
        }
    }

    /// Something was let go over a glass folder, `ago` seconds ago: the drop plays at once, as a plain folder's does, with
    /// the sheets it will make (one more item per file dragged); counted again after the motion (a refused or slow drop).
    private func dropped(on path: String, ago: Double) {
        guard let look = shown[path], let tile = tiles[path]?.contentView else { return }
        if opened != path { openFolder(nil) }
        opened = nil  // the drop shuts the pane itself
        standIn(path, for: countRedraw)  // Finder may redraw the folder plain as what was dropped lands (see setStandIn)
        show(path, Look(style: look.style, sheets: sheetCount((counts[path] ?? 0) + 1)))
        playDrop(tile, first: look.sheets == 0, ago: ago)
        tile.window?.displayIfNeeded()  // the sheets' new picture reaches their layers in a display pass: have it now
        CATransaction.flush()  // to the screen now, not after whatever the main thread does next
        // Then as many more sheets as files were dragged.
        let adding = dragBoard.pasteboardItems?.count ?? 1  // (one per file; reading the files themselves may wait on Finder)
        show(path, Look(style: look.style, sheets: sheetCount((counts[path] ?? 0) + max(1, adding))))
        settling[path] = now + dropSettles
        DispatchQueue.main.asyncAfter(deadline: .now() + dropSettles + 0.05) { [weak self] in self?.refreshIcon(path) }
    }

    /// Give a folder Finder's picture for its look, unless it has it (its stamp). An iCloud Desktop notices a replaced picture
    /// minutes late, a new one in seconds: it goes in 1.5 s after the old is taken out. Only the latest call's (`turn`) do.
    private func giveIcon(_ path: String, _ look: Look) {
        let style = look.style, key = iconKey(style, sheets: look.sheets), turn = (iconTurn[path] ?? 0) + 1
        iconTurn[path] = turn
        let stamp = iconStamp(path)
        guard stamp != key else { return }
        let replacing = FileManager.default.fileExists(atPath: path + "/" + iconFile)
        let wait = replacing ? 1.5 : max(0, (clearedAt[path] ?? -9) + 1.5 - now)  // (cleared a moment ago: the rest of its gap)
        standIn(path, for: wait + (stamp == nil ? 12 : finderRedraw))  // Finder shows its plain icon until it has the new one (a first: slowly)
        givingUntil[path] = now + wait + 3  // (this app's own clear and set: not the user's doing)
        if replacing { DispatchQueue.main.async { [weak self] in  // (after a drop's motion is on screen)
            guard let self, iconTurn[path] == turn else { return }
            clearedAt[path] = now
            NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, iconTurn[path] == turn, folders[path] == style,
                  NSWorkspace.shared.setIcon(icon(style.colour, style.tint, sheets: look.sheets), forFile: path, options: []) else { return }
            setIconStamp(path, key)
            tiles[path]?.contentView.map { setPatch($0, sheets: [look.sheets]) }  // (Finder shows it a moment later, under the stand-in)
        }
    }

    /// Its right-click menu is open: a tag picked there has Finder redraw it plain at once (before this app hears): stand in.
    private func holdWhileMenu(_ path: String) {
        standIn(path, for: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in finderMenuOpen() ? self?.holdWhileMenu(path) : self?.standIn(path) }
    }

    /// Only the sheets changed: Finder's picture follows once the mouse has rested 8 s (swapped, Finder shows its plain
    /// folder for seconds, in the image it drags too); meanwhile the patch covers both what it shows and what is.
    private func giveIconSoon(_ path: String, _ sheets: Int) {
        tiles[path]?.contentView.map { setPatch($0, sheets: [stampedSheets(path), sheets]) }
        guard iconDue.insert(path).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, iconDue.remove(path) != nil, let look = shown[path] else { return }
            if pressing || now - lastPress < 8 { giveIconSoon(path, look.sheets) } else { giveIcon(path, look) }
        }
    }

    /// A Finder window showing a folder named `title` opened, closed or turned to or from it: Finder may redraw that
    /// folder as its plain icon now. Untitled ("": just made, named a moment later), it may be any folder's, until named.
    private func windowChanged(_ title: String) {
        for path in tiles.keys where title.isEmpty || windowTitles(path).contains(title) { standIn(path, for: title.isEmpty ? 0.7 : finderRedraw, recut: !title.isEmpty) }
    }

    /// Lay the stand-in over the folder's icon while Finder may redraw it (setStandIn), `seconds` more at least.
    private func standIn(_ path: String, for seconds: Double = finderRedraw, recut: Bool? = nil) {  // recut: re-cut (default: if it wasn't up)
        let until = max(standingIn[path] ?? 0, now + seconds), wasUp = (standingIn[path] ?? 0) > now
        standingIn[path] = until
        if let window = tiles[path], let holder = window.contentView {
            setStandIn(holder, true, wide: finder.quiet || now - dragEnded < 1.5)  // up first: asking Finder can take a moment
            CATransaction.flush()
            // Then re-cut around the Desktop as it is now (Finder lists a new icon a moment after it appears); not in a drag.
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

    // -- the glass on the Desktop

    /// A click-through window, just above Finder's icons, for a folder's glass. Stationary, so that it stays put like
    /// the icons when a click on the wallpaper moves every window aside; Mission Control would leave it showing too, so
    /// it is faded: see MissionControlFade.
    private func window(_ frame: CGRect, _ content: NSView) -> GlassWindow {
        let window = GlassWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none  // replaced at once, not shrunk and faded out over the new one
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

    /// Take a folder's window away.
    private func remove(_ path: String) {
        tiles.removeValue(forKey: path)?.orderOut(nil)
        icons[path] = nil
        if opened == path { opened = nil }
    }

    /// Hide a folder's glass, so that Finder's own icon for it shows alone (and moves as Finder moves it).
    private func stepAside(_ path: String) {
        tiles[path]?.contentView?.isHidden = true
    }

    /// The glass folder whose icon is at `point` (on screen, y up), other than `except`, if the Desktop shows there
    /// (Finder's windows lie over its icons, and ours).
    private func folder(at point: CGPoint, except: String?) -> String? {
        guard let path = icons.first(where: { $0.key != except && onFolder(point, $0.value, name: windowTitles($0.key)[0], items: counts[$0.key]) })?.key,
              desktopShows(point) else { return nil }
        return path
    }

    /// Tip `path`'s front pane open (nil: none), shutting any other; one left without a drop is counted again.
    private func openFolder(_ path: String?) {
        guard path != opened else { return }
        let left = opened
        if let left, let tile = tiles[left]?.contentView { setOpen(tile, false) }
        if let path, let tile = tiles[path]?.contentView { setOpen(tile, true) }
        opened = path
        if let left { refreshIcon(left) }
    }

    /// Coalesce a burst of events into one layout, after Finder has settled its icons, and look again
    /// once Finder has finished animating them to a new size or spacing.
    private func layoutSoon() {
        guard !layoutDue else { return }
        layoutDue = true
        for delay in [0.35, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.layout() }
        }
    }

    /// The mouse went down: watch closely until it comes up. Heard late (a busy agent), a drag may have begun already:
    /// the count from the last let-go stands, and the press is placed where the event says.
    private func pressed(_ event: NSEvent) {
        pressedAt = event.locationInWindow  // (a global event's is on screen)
        pressedOn = icons.first(where: { onFolder(pressedAt, $0.value, name: windowTitles($0.key)[0], items: counts[$0.key]) })
            .flatMap { desktopShows(pressedAt) ? $0.key : nil }
        if now - event.timestamp < 0.05 { dragCount = dragBoard.changeCount }
        heardQuietly = []
        pressing = true
        lastPress = now
        if event.modifierFlags.isDisjoint(with: [.command, .shift]) && desktopShows(pressedAt)  // Finder selects as it goes down,
            && NSScreen.screens.first(where: { $0.frame.contains(pressedAt) })?.visibleFrame.contains(pressedAt) == true  // (not menu bar, Dock)
            && pressedOn.flatMap({ tiles[$0]?.contentView }).flatMap(cutSelected) != true {  // (unless pressed on a selection: kept to drag)
            for (path, window) in tiles { window.contentView.map { reselect($0, path == pressedOn) } }
        }
        if event.clickCount == 2, let pressedOn { standIn(pressedOn) }  // its window is about to open: before Finder says so
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control), let pressedOn { holdWhileMenu(pressedOn) }
        watchClosely(for: 0)
    }

    /// Watch Finder's Desktop 60 times a second, for `seconds` and while the mouse is held. A window follows Finder a
    /// frame behind, so while Finder moves or resizes a glass folder's icon (sliders, a reflow, a move) the glass steps
    /// aside for Finder's own icon, then is laid out afresh and fades back in. Meanwhile, tip open what is dragged over.
    private func watchClosely(for seconds: Double) {
        watchUntil = max(watchUntil, now + seconds)
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let finderInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        // Only a real drag writes the drag pasteboard: not a selection rectangle, a window move or a slider.
        let dragging = dragBoard.changeCount != dragCount, at = NSEvent.mouseLocation
        // Finder is busy with a drag, and with its drop for a moment after: it isn't asked anything then (asked at once, it
        // twice left a moved folder hanging for 2 s).
        var dropping = now - dragEnded < 0.3
        finder.quiet = (pressing && dragging) || dropping
        if pressing && NSEvent.pressedMouseButtons & 1 == 0 {  // let go: dropped, or released a slider
            pressing = false
            if dragging { (dragEnded, dropping) = (now, true) }
            dragCount = dragBoard.changeCount  // what the next press, if it is heard late, is measured from
            if dragging {  // a stand-in kept up through the drag stays a whole redraw's time from its end
                for path in tiles.keys where (standingIn[path] ?? 0) > now { standIn(path) }
            }
            if finderInFront { watchUntil = max(watchUntil, now + 0.3) }  // Finder may still be settling its icons
            if dragging, let pressedOn {  // a glass folder was moved: Finder reports its new place a moment later (up to a second)
                stepAside(pressedOn)  // (kept, sheets and all, over Finder's icon left in place while it was dragged)
                watchUntil = max(watchUntil, now + 1)
                moving = (pressedOn, tiled[pressedOn]?.icon)
            }
            // shortcut: a drag called off with Escape and let go over the folder still plays a drop (and shows a sheet
            // until the recount); nothing tells the agent the drag was called off.
            if dragging, let path = folder(at: at, except: pressedOn) {
                let ago = now - mouseUp
                dropped(on: path, ago: ago >= 0 && ago < 0.05 ? ago : 0)
                return  // Finder is busy with the drop: ask it about its icons next time, not before the drop is on screen
            }
            openFolder(nil)
        }
        if pressing && dragging {  // never ask Finder anything now: it is busy with the drag and would stall us
            // A drag out of a window showing a glass folder can make Finder redraw that folder plain while it lasts:
            // the stand-in stays over it throughout (Finder's windows as last heard: nothing is asked of Finder).
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
            if frames[name] != nil { watchUntil = min(watchUntil, now) }  // in its new place: lay it out there now (gone: no hurry)
            self.moving = nil  // either way stop asking: a name Finder doesn't show has it walk the whole Desktop each time
        }
        if !pressing && !dropping && now >= watchUntil {
            moving = nil
            ticker?.invalidate()
            ticker = nil
            layout()
        }
    }

    /// Hide the glass of any icon Finder moved or resized since its layout (not asked about again until the next).
    private func stepAside() {
        let showing = tiles.keys.filter { tiles[$0]?.contentView?.isHidden == false }.sorted()
        guard finder.allowed, !showing.isEmpty else { return }
        // Light on Finder, however many folders: one asked about each time, all six times a second or once that one moved
        // (Finder's sliders and reflows move them together; a single folder moves by a drag, followed at its let-go).
        stepAsideTurn += 1
        guard let first = finder.frames([(showing[0] as NSString).lastPathComponent]) else { return }  // no answer: keep it
        let all = stepAsideTurn % 10 == 0 || first[(showing[0] as NSString).lastPathComponent] != tiled[showing[0]]?.icon
        guard let frames = all ? finder.frames(showing.map { ($0 as NSString).lastPathComponent }) : first else { return }
        for path in showing where (all || path == showing[0]) && frames[(path as NSString).lastPathComponent] != tiled[path]?.icon
            && !(pressing && path == pressedOn) { stepAside(path) }  // (held: it steps aside at the let-go, if it was dragged)
    }

    /// Lay each glass folder's window over its icon, with room around it to sample, swell and drop a first sheet in.
    private func layout() {
        layoutDue = false
        guard ticker == nil else { return }  // watching closely: it lays out when things settle
        guard let screen = NSScreen.screens.first?.frame else { return }  // (none for a moment while displays change)
        let desktop = folders.keys.filter { ($0 as NSString).deletingLastPathComponent == desktopPath && shown[$0] != nil }
        // No answer from Finder: keep the glass as it is (the layouts queued after every mouse-up ask again).
        guard let frames = finder.frames(desktop.map { ($0 as NSString).lastPathComponent }) else {
            if !retryDue, tiles.values.contains(where: { $0.contentView?.isHidden == true }) {  // glass stepped aside: ask again, once
                retryDue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.retryDue = false; self?.layout() }
            }
            return
        }
        var others: [CGRect]?  // every icon's frame, read once if any glass is laid out or re-cut
        let recut = othersChanged
        othersChanged = false
        for path in desktop {
            let icon = frames[(path as NSString).lastPathComponent], look = shown[path]!
            let state = TileState(look: look, icon: icon)
            var moved = false
            if let window = tiles[path], window.contentView?.isHidden == false, let old = tiled[path], old.look == look, let was = old.icon, let icon, was.size == icon.size, was != icon,
               let frame = Optional(appKit(icon, screen)), window.backingScaleFactor == scale(of: frame) {
                // Only nudged a couple of points by Finder, glass showing: the window goes with it, as it is, and its stand-in is
                // re-cut around its new neighbours. (A move of the user's, glass stepped aside, is laid out afresh and faded in:
                // a moved window shown in the same turn showed a frame at its old place.)
                window.setFrameOrigin(CGPoint(x: frame.minX - room(icon), y: frame.minY - room(icon)))
                icons[path] = frame
                tiled[path] = state
                moved = true
            }
            if tiled[path] == state {  // most layouts: a click somewhere that moved nothing
                if recut || moved || (standingIn[path] ?? 0) > now, let window = tiles[path], let holder = window.contentView, let frame = icons[path] {
                    if others == nil { others = finder.everyFrame() }
                    guard let others else { othersChanged = true; continue }  // no answer: re-cut next time
                    cutStandIn(holder, icon: frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY),
                               others: cuts(frame, window.frame, screen, others), selected: finder.selected((path as NSString).lastPathComponent))
                } else if let holder = tiles[path]?.contentView, let selected = finder.selected((path as NSString).lastPathComponent) {
                    reselect(holder, selected)  // kept up to date, for a stand-in that goes up while Finder isn't asked (a drag)
                }
                continue
            }
            // A window still showing is filled afresh in place, in one go: taken away first, it would leave Finder's icon
            // bare for a frame (plain, if a new picture of it is on its way).
            let stepped = tiles[path]?.contentView?.isHidden ?? false, reused = stepped ? nil : tiles[path]
            if reused == nil { remove(path) } else if opened == path { opened = nil }
            tiled[path] = state
            guard let icon else { remove(path); continue }  // not on the Desktop now: Finder's picture shows wherever it is
            let frame = appKit(icon, screen), scale = scale(of: frame)
            if others == nil { others = finder.everyFrame() }
            if others == nil { othersChanged = true }  // no answer: cut without the others now, and again next time
            let around = frame.insetBy(dx: -room(icon), dy: -room(icon))
            let holder = glassHolder(around.size, icon: frame.offsetBy(dx: -around.minX, dy: -around.minY), others: cuts(frame, around, screen, others ?? []),
                                     selected: finder.selected((path as NSString).lastPathComponent) ?? (tiles[path]?.contentView.flatMap(cutSelected) ?? false),
                                     colour: look.style.colour, tint: look.style.tint, sheets: look.sheets, finderSheets: [stampedSheets(path), look.sheets], scale: scale)
            if (standingIn[path] ?? 0) > now { setStandIn(holder, true, once: true, wide: finder.quiet || now - dragEnded < 1.5) }  // under way
            if stepped { holder.alphaValue = 0 }  // (faded in below: never a frame at full strength first)
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
            if stepped { tiles[path]?.contentView.map(fadeIn) }
        }
        for window in tiles.values where window.contentView?.isHidden == true {
            window.contentView.map(fadeIn)  // stepped aside, but its icon ended up where it was
        }
    }
}
