import AppKit

// Finder's Desktop over Accessibility: icon positions, and its windows opening, closing or changing folder.
// Finder may not answer during a drag; nothing here may hold the app up then.

/// Accessibility is the only source: Finder's scripting interface reports no positions on a sorted Desktop.
final class FinderDesktop {
    let allowed = AXIsProcessTrusted()
    private var icons: [String: AXUIElement] = [:]  // by file name
    private var groups: [AXUIElement] = []          // the Desktop's icon views, whose selection is watched
    /// The Desktop selection changed: a click, a selection box, the keyboard. Not heard during a drag.
    var selectionChanged: (() -> Void)?

    init() {
        // The default 6 s wait on a Finder busy with a drag would freeze the glass.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Frames in points, y down from the main display's top; missing where Finder shows no such icon.
    /// Nil when Finder didn't answer: not knowing isn't "the icon is gone".
    func frames(_ names: [String]) -> [String: CGRect]? {
        guard allowed else { return [:] }
        var (found, answered) = lookUp(names)
        if found.count < names.count && answered {  // first run, or Finder rebuilt its icons
            guard index() else { return nil }
            (found, answered) = lookUp(names)
        }
        return answered ? found : nil
    }

    /// Stops at the first icon Finder doesn't answer for: a hung Finder must not cost 0.25 s per icon.
    private func lookUp(_ names: [String]) -> (found: [String: CGRect], answered: Bool) {
        var found: [String: CGRect] = [:]
        for name in names {
            guard let icon = icons[name] else { continue }
            let (rect, answered) = frame(of: icon)
            guard answered else { return (found, false) }
            found[name] = rect
        }
        return (found, true)
    }

    private func frame(of icon: AXUIElement) -> (CGRect?, answered: Bool) {
        var rect = CGRect.zero
        let (value, answered) = ask(icon, "AXFrame")
        return (value.map { AXValueGetValue($0 as! AXValue, .cgRect, &rect) } == true ? rect : nil, answered)
    }

    /// Nil if Finder won't say (busy, or in a drag).
    func selected(_ name: String) -> Bool? {
        guard allowed, !quiet, let icon = icons[name] else { return nil }
        return ask(icon, "AXSelected").value as? Bool
    }

    /// The selected Desktop items' file names; nil if Finder won't say.
    func selectedNames() -> Set<String>? {
        guard allowed, !quiet else { return nil }
        var names = Set<String>()
        for group in groups {
            let (selected, answered) = ask(group, "AXSelectedChildren")
            guard answered else { return nil }
            for icon in selected as? [AXUIElement] ?? [] { (attribute(icon, "AXFilename") as? String).map { names.insert($0) } }
        }
        return names
    }

    /// Clears the Desktop selection after "Liquify", so the new glass shows as it will stay.
    func deselect() {
        guard allowed, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        for area in attribute(AXUIElementCreateApplication(finder.processIdentifier), "AXChildren") as? [AXUIElement] ?? []
            where attribute(area, "AXRole") as? String == "AXScrollArea" {
            for group in attribute(area, "AXChildren") as? [AXUIElement] ?? [] {
                AXUIElementSetAttributeValue(group, "AXSelectedChildren" as CFString, [] as CFArray)
            }
        }
    }

    // -- Finder's windows

    /// A window's title (old and new) when a Finder window opens, closes or changes folder: Finder may then redraw
    /// that folder as its plain icon (see setStandIn). An opening window is first reported as "" (any folder).
    var windowChanged: ((String) -> Void)?
    /// Called instead during a drag (see quiet): a window opening then is spring-loaded.
    var windowChangedQuietly: (() -> Void)?
    /// During a drag Finder may not answer: what is heard is kept and handled once the drag ends.
    var quiet = false { didSet { if !quiet && oldValue { catchUp() } } }
    private var unheard: [(AXUIElement, String)] = []
    private var observer: AXObserver?
    private var titles: [AXUIElement: String] = [:]  // open windows -> title ("" if Finder wouldn't say)
    private var relaunch: NSObjectProtocol?
    private var missingSince: TimeInterval?  // since when Finder or its Desktop has been missing

    /// An untitled window may show any folder.
    func showing(_ names: [String]) -> Bool { titles.values.contains { $0.isEmpty || names.contains($0) } }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        relaunch.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Also re-arms whenever Finder relaunches (or first starts after the app).
    func watchWindows() {
        if relaunch == nil {
            relaunch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.finder" else { return }
                if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
                (observer, titles, icons, unheard, busyUntil) = (nil, [:], [:], [], 0)
                missingSince = nil
                watchWindows()
            }
        }
        guard allowed, observer == nil,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        var made: AXObserver?
        let heard: AXObserverCallback = { _, element, notification, me in
            Unmanaged<FinderDesktop>.fromOpaque(me!).takeUnretainedValue().heard(element, notification as String)
        }
        guard AXObserverCreate(finder.processIdentifier, heard, &made) == .success, let made else { return }
        observer = made
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        for notice in [kAXWindowCreatedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(made, app, notice as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        for window in attribute(app, "AXWindows") as? [AXUIElement] ?? [] { track(window) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
    }

    private func track(_ window: AXUIElement) {
        guard let observer, (attribute(window, "AXRole") as? String ?? "AXWindow") == "AXWindow",  // no answer: keep
              !["AXDialog", "AXSystemDialog"].contains(attribute(window, "AXSubrole") as? String ?? "") else { return }
        titles[window] = attribute(window, "AXTitle") as? String ?? ""
        let added = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
        if added != .success && added != .notificationAlreadyRegistered {
            titles[window] = nil  // its close would go unheard
        }
        if titles[window] == "" { nameLater(window, giveUp: true) }
    }

    /// Finder names a new window a moment after making it, and doesn't answer while busy: retry for 0.6 s.
    /// Still unnamed then (and `giveUp`): it may show any folder.
    private func nameLater(_ window: AXUIElement, giveUp: Bool) {
        for delay in [0.02, 0.05, 0.08, 0.12, 0.16, 0.2, 0.3, 0.45, 0.6] {  // the plain icon can show within 0.23 s
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !quiet, titles[window] == "" else { return }
                if let title = attribute(window, "AXTitle") as? String, !title.isEmpty {
                    titles[window] = title
                    windowChanged?(title)
                } else if giveUp && delay == 0.6 {
                    windowChangedQuietly?()
                }
            }
        }
    }

    private func catchUp() {
        let kept = unheard
        unheard = []
        for (element, notification) in kept { heard(element, notification) }
        for (window, title) in titles where title.isEmpty { nameLater(window, giveUp: false) }
    }

    private func heard(_ element: AXUIElement, _ notification: String) {
        if notification == kAXSelectedChildrenChangedNotification {  // after a drag, layout asks anyway
            if !quiet { selectionChanged?() }
            return
        }
        if quiet && !(notification == kAXUIElementDestroyedNotification && titles.keys.contains(element)) {
            // a known window's close needs nothing from Finder
            if notification != kAXUIElementDestroyedNotification { unheard.append((element, notification)) }
            windowChangedQuietly?()
            return
        }
        switch notification {
        case kAXWindowCreatedNotification:
            windowChanged?("")  // before asking Finder anything: it is busiest now
            track(element)
            titles[element].map { if !$0.isEmpty { windowChanged?($0) } }
        case kAXTitleChangedNotification where titles.keys.contains(element):
            let old = titles[element], (now, answered) = ask(element, "AXTitle")
            titles[element] = now as? String ?? ""
            if !answered { windowChanged?(""); nameLater(element, giveUp: true) }  // a folder Finder can't name yet
            for title in Set([old, titles[element]].compactMap { $0 }) where !title.isEmpty { windowChanged?(title) }
        case kAXUIElementDestroyedNotification:
            titles.removeValue(forKey: element).map { $0.isEmpty ? windowChangedQuietly?() : windowChanged?($0) }
        default: break
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? { ask(element, name).value }

    /// After a timeout, `answered` is false for 0.25 s: a busy Finder is waited out once, not per question.
    private func ask(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, answered: Bool) {
        guard ProcessInfo.processInfo.systemUptime >= busyUntil else { return (nil, false) }
        var value: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if answer == .cannotComplete { busyUntil = ProcessInfo.processInfo.systemUptime + 0.25 }
        return (answer == .success ? value : nil, answer != .cannotComplete)
    }
    private var busyUntil: TimeInterval = 0

    /// Every Desktop icon's frame (y down), re-indexed, to keep other icons out of the stand-in's sample.
    /// Nil if Finder doesn't answer (not an empty Desktop). Calls within 0.05 s reuse the last walk.
    func everyFrame() -> [CGRect]? {
        if ProcessInfo.processInfo.systemUptime - lastWalk.at > 0.05 {
            let frames = walk()
            lastWalk = (ProcessInfo.processInfo.systemUptime, frames)
        }
        return lastWalk.frames
    }
    private var lastWalk: (at: TimeInterval, frames: [CGRect]?) = (-1, nil)

    private func walk() -> [CGRect]? {
        guard allowed else { return [] }
        guard index() else { return nil }
        var frames: [CGRect] = []
        for icon in icons.values {
            let (rect, answered) = frame(of: icon)
            guard answered else { return nil }
            rect.map { frames.append($0) }
        }
        return frames
    }

    /// False, keeping the last index, if Finder didn't answer.
    @discardableResult
    private func index() -> Bool {
        // No Finder for 5 s: no icons (the glass goes). No Desktop (just relaunched, a menu open): unknown meanwhile.
        func none() -> Bool {
            let now = ProcessInfo.processInfo.systemUptime, since = missingSince ?? now
            missingSince = since
            guard now - since > 5 else { return false }
            icons = [:]
            return true
        }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return none() }
        func kids(_ element: AXUIElement) -> [AXUIElement]? {
            let (value, answered) = ask(element, "AXChildren")
            return answered ? value as? [AXUIElement] ?? [] : nil
        }
        var found: [String: AXUIElement] = [:], desktop = false, views: [AXUIElement] = []
        guard let areas = kids(AXUIElementCreateApplication(finder.processIdentifier)) else { return false }
        for area in areas {  // the Desktop's; the other is the menu bar's
            let (role, answered) = ask(area, "AXRole")
            guard answered else { return false }
            guard role as? String == "AXScrollArea" else { continue }
            desktop = true
            guard let groups = kids(area) else { return false }
            for group in groups {
                views.append(group)
                guard let icons = kids(group) else { return false }
                for icon in icons {
                    let (name, answered) = ask(icon, "AXFilename")
                    guard answered else { return false }
                    (name as? String).map { found[$0] = icon }
                }
            }
        }
        guard desktop else { return false }
        missingSince = nil
        icons = found
        groups = views
        if let observer {
            for group in views {
                AXObserverAddNotification(observer, group, kAXSelectedChildrenChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        return true
    }
}

/// Titles a Finder window showing `path` may have: display name, file name, or full path (if set to show paths).
func windowTitles(_ path: String) -> [String] {
    if let known = titleCache[path] { return known }  // asked every drag tick; displayName costs a file lookup
    let found = [FileManager.default.displayName(atPath: path), (path as NSString).lastPathComponent, path]
    titleCache[path] = found
    return found
}
private var titleCache: [String: [String]] = [:]  // never stale: a renamed folder has a new path

// -- the Desktop around an icon

/// Whether Finder takes a drop at `point` (screen, y up): on the picture's outline (see-through parts let drops
/// through) or on the name below.
func onFolder(_ point: CGPoint, _ icon: CGRect, name: String, items: Int?,
              labels: (text: CGFloat, info: Bool) = desktopLabels()) -> Bool {
    nameHit(icon, name: name, items: labels.info ? items : nil, text: labels.text).contains { $0.contains(point) }
        || outline(icon.width).contains(CGPoint(x: point.x - icon.minX, y: point.y - icon.minY))
}

/// Finder's Desktop View Options: label text size, and whether item counts show.
func desktopLabels() -> (text: CGFloat, info: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    if now - labelsRead.at > 0.5 {  // asked per icon per drag frame: read at most twice a second
        let options = UserDefaults(suiteName: "com.apple.finder")?.dictionary(forKey: "DesktopViewSettings")?["IconViewSettings"] as? [String: Any]
        labelsRead = (now, ((options?["textSize"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 12, (options?["showItemInfo"] as? NSNumber)?.boolValue ?? false))
    }
    return labelsRead.labels
}
private var labelsRead: (at: TimeInterval, labels: (text: CGFloat, info: Bool)) = (-1, (12, false))

/// Where Finder takes a drop on an icon's name (screen, y up): the name's line and the count's, each only as wide as
/// its text. Measured on macOS 26, 116 pt icons: name bold 12 pt, 13–22 pt below; count 10 pt, 28–36 pt below.
/// shortcut: measured at text size 12, English, labels at bottom, one line, re-measure if name drops miss elsewhere.
func nameHit(_ icon: CGRect, name: String, items: Int?, text: CGFloat = 12) -> [CGRect] {
    func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    let k = text / 12
    // + the iCloud glyph + padding
    let line = min(width(name, .boldSystemFont(ofSize: text)) + 18 * k + 12, icon.width + 36)
    var lines = [CGRect(x: icon.midX - line / 2, y: icon.minY - 25 * k, width: line, height: 15 * k)]
    if let items {
        let count = width(items == 0 ? "No items" : items == 1 ? "1 item" : "\(items) items", .systemFont(ofSize: text - 2)) + 8
        lines.append(CGRect(x: icon.midX - count / 2, y: icon.minY - 38 * k, width: count, height: 13 * k))
    }
    return lines
}

/// Where an icon's name lies (screen, y up): 10–56 pt below, a quarter wider each side, as names wrap wider.
/// shortcut: fixed for 116 pt icons and 12 pt text (Finder doesn't say), re-measure if other sizes matter.
func nameArea(_ icon: CGRect) -> CGRect {
    CGRect(x: icon.minX - icon.width / 4, y: icon.minY - 56, width: icon.width * 1.5, height: 46)
}

/// A Finder right-click menu shows as a Finder window at the pop-up menu level.
func finderMenuOpen() -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { $0[kCGWindowOwnerName as String] as? String == "Finder"
        && $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
}

/// Whether no app's window covers `point` (screen, y up). The Dock's don't count: after a wallpaper click it lays a
/// see-through window over the screen that lets drops through.
func desktopShows(_ point: CGPoint) -> Bool {
    guard let top = NSScreen.screens.first?.frame.height else { return false }  // none while displays change
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return !windows.contains { window in
        // layers 0..<20: apps' windows and panels
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        guard (0..<20).contains(layer), window[kCGWindowOwnerName as String] as? String != "Dock",
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        let frame = CGRect(x: bounds["X"] ?? 0, y: top - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0), width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        return frame.contains(point)
    }
}

/// What the stand-in for the icon at `frame` keeps out of its sample, in window coordinates: nearby icons
/// (`others`, Finder's y-down frames), every name (its own too, highlighted while selected), and anything off screen.
func cuts(_ frame: CGRect, _ around: CGRect, _ screen: CGRect, _ others: [CGRect], displays: [CGRect] = NSScreen.screens.map(\.frame)) -> [CGRect] {
    let iconsAround: [CGRect] = others.map { (icon: CGRect) -> CGRect in
        CGRect(x: icon.minX, y: screen.height - icon.minY - icon.height, width: icon.width, height: icon.height)
    }.filter { !frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }  // not its own, even slightly stale
    // -7: the selection box
    let kept: [CGRect] = iconsAround.map { $0.insetBy(dx: -7, dy: -7) } + (iconsAround + [frame]).map(nameArea)
    // Sample as far each side as the screen allows on the other: lopsided, a folder at the edge came out 4% too red.
    let display = displays.first { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? screen
    let across = min(frame.minX - display.minX, display.maxX - frame.maxX), upDown = min(frame.minY - display.minY, display.maxY - frame.maxY)
    let fair = frame.insetBy(dx: -max(0, across), dy: -max(0, upDown))
    let offScreen = [CGRect(x: around.minX, y: fair.maxY, width: around.width, height: max(0, around.maxY - fair.maxY)),
                     CGRect(x: fair.maxX, y: around.minY, width: max(0, around.maxX - fair.maxX), height: around.height),
                     CGRect(x: around.minX, y: around.minY, width: max(0, fair.minX - around.minX), height: around.height),
                     CGRect(x: around.minX, y: around.minY, width: around.width, height: max(0, fair.minY - around.minY))]
    return (kept + offScreen).filter { $0.width > 0 && $0.height > 0 && $0.intersects(around) }
        .map { $0.offsetBy(dx: -around.minX, dy: -around.minY) }
}

/// Finder's y-down icon frame in AppKit's y-up coordinates.
func appKit(_ icon: CGRect, _ screen: CGRect) -> CGRect {
    CGRect(x: icon.minX, y: screen.height - icon.minY - icon.height, width: icon.width, height: icon.height)
}

func scale(of frame: CGRect) -> CGFloat { NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2 }

/// Room around the icon for the stand-in, the swell and a first sheet. Whole points: otherwise the window server
/// snaps the window to pixels and leaves the cover a fraction off Finder's icon.
func room(_ icon: CGRect) -> CGFloat {
    max(glassRoom, standInReach * icon.width, firstSheetPop.values[0] * icon.height).rounded(.up)
}
