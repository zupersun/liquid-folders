import AppKit

// Finder's side of things, read through the Accessibility interface: where its Desktop icons are, and when its windows
// open, close or change what they show. Finder may not answer while it is busy with a drag; nothing here may hold the
// agent up then.

/// Reads Desktop icon frames from Finder through the Accessibility interface (Finder's scripting interface reports no
/// positions on a sorted Desktop, so this is the only source), and hears its windows open, close and change.
final class FinderDesktop {
    let allowed = AXIsProcessTrusted()
    private var icons: [String: AXUIElement] = [:]  // file name -> Finder's icon element

    init() {
        // A Finder busy with a drag may not answer for a while; the default wait is 6 seconds, which
        // would freeze the glass (and its animations) until Finder came back.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Each icon's frame in points, y measured down from the top of the main display. Missing where
    /// Finder shows no such icon, or without Accessibility permission.
    /// Nil when Finder didn't answer (busy, with a drop say): not knowing isn't "the icon is gone".
    func frames(_ names: [String]) -> [String: CGRect]? {
        guard allowed else { return [:] }
        var (found, answered) = lookUp(names)
        if found.count < names.count && answered {  // first run, or Finder rebuilt its icons: walk the Desktop once and retry
            guard index() else { return nil }
            (found, answered) = lookUp(names)
        }
        return answered ? found : nil
    }

    /// The icons' frames, as far as Finder answered: it stops at the first it can't answer for (a hung Finder must not
    /// hold the agent up a quarter second per icon).
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

    /// An icon's frame, nil if it has none (gone); `answered` false if Finder didn't answer.
    private func frame(of icon: AXUIElement) -> (CGRect?, answered: Bool) {
        var rect = CGRect.zero
        let (value, answered) = ask(icon, "AXFrame")
        return (value.map { AXValueGetValue($0 as! AXValue, .cgRect, &rect) } == true ? rect : nil, answered)
    }

    /// Whether Finder shows the icon by this name selected; nil if it won't say (busy, or in a drag).
    func selected(_ name: String) -> Bool? {
        guard allowed, !quiet, let icon = icons[name] else { return nil }
        return ask(icon, "AXSelected").value as? Bool
    }

    /// Clear Finder's selection on the Desktop (after "Liquify": the new glass shows as it will stay).
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

    /// Called with a window's title when a Finder window opens, closes or changes what it shows (once with the old
    /// title, once with the new): Finder may then redraw a folder with that name as its plain icon (see setStandIn).
    /// A window opening is told first with "" (any folder's), before Finder is asked what it shows.
    var windowChanged: ((String) -> Void)?
    /// Called instead when that happens during a drag (see quiet): a window opening then is spring-loaded, for the
    /// folder under the pointer.
    var windowChangedQuietly: (() -> Void)?
    /// While a drag is under way Finder may not answer (and must not hold the agent up): what is heard then is kept
    /// and looked at once the drag is over.
    var quiet = false { didSet { if !quiet && oldValue { catchUp() } } }
    private var unheard: [(AXUIElement, String)] = []
    private var observer: AXObserver?
    private var titles: [AXUIElement: String] = [:]  // Finder's open windows, by what they show ("" if it wouldn't say)
    private var relaunch: NSObjectProtocol?
    private var missingSince: TimeInterval?  // when Finder (or its Desktop) was last found missing, while it still is

    /// Whether a Finder window showing a folder by any of these names is open.
    func showing(_ names: [String]) -> Bool { titles.values.contains { $0.isEmpty || names.contains($0) } }  // (untitled: any)

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        relaunch.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Start hearing about Finder's windows, and again whenever Finder is relaunched (or first starts, after the agent).
    func watchWindows() {
        if relaunch == nil {
            relaunch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.finder" else { return }
                if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
                (observer, titles, icons, unheard, busyUntil) = (nil, [:], [:], [], 0)  // (the old Finder's silence says nothing)
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
        guard let observer, (attribute(window, "AXRole") as? String ?? "AXWindow") == "AXWindow",  // (no answer: keep it)
              !["AXDialog", "AXSystemDialog"].contains(attribute(window, "AXSubrole") as? String ?? "") else { return }  // (alerts show no folder)
        titles[window] = attribute(window, "AXTitle") as? String ?? ""
        let added = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
        if added != .success && added != .notificationAlreadyRegistered {  // (already: its close will be heard)
            titles[window] = nil  // gone already (opened and closed within one drag), or Finder too busy to say: its close would go unheard
        }
        if titles[window] == "" { nameLater(window, giveUp: true) }
    }

    /// Finder names a new window a moment after making it (6 opens in 48 went unheard so), and doesn't answer while busy:
    /// ask again over 0.6 s; if it is still unnamed then (and `giveUp`), it may show any folder, as its close is taken.
    private func nameLater(_ window: AXUIElement, giveUp: Bool) {
        for delay in [0.02, 0.05, 0.08, 0.12, 0.16, 0.2, 0.3, 0.45, 0.6] {  // (its plain icon can follow in 0.23 s)
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
        for (window, title) in titles where title.isEmpty { nameLater(window, giveUp: false) }  // (not asked during the drag)
    }

    private func heard(_ element: AXUIElement, _ notification: String) {
        if quiet && !(notification == kAXUIElementDestroyedNotification && titles.keys.contains(element)) {
            // (a known window's close needs nothing from Finder; one opened and closed within the drag is unknown)
            if notification != kAXUIElementDestroyedNotification { unheard.append((element, notification)) }
            windowChangedQuietly?()
            return
        }
        switch notification {
        case kAXWindowCreatedNotification:
            windowChanged?("")  // first, before asking Finder anything (it is busiest now): which folder it shows comes later
            track(element)
            titles[element].map { if !$0.isEmpty { windowChanged?($0) } }
        case kAXTitleChangedNotification where titles.keys.contains(element):
            let old = titles[element], (now, answered) = ask(element, "AXTitle")
            titles[element] = now as? String ?? ""
            if !answered { windowChanged?(""); nameLater(element, giveUp: true) }  // turned to a folder Finder can't name yet
            for title in Set([old, titles[element]].compactMap { $0 }) where !title.isEmpty { windowChanged?(title) }
        case kAXUIElementDestroyedNotification:
            titles.removeValue(forKey: element).map { $0.isEmpty ? windowChangedQuietly?() : windowChanged?($0) }  // (untitled: any folder's)
        default: break
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? { ask(element, name).value }

    /// One of Finder's answers; `answered` false if it didn't answer, or didn't a moment ago: busy, every question asked
    /// at once would hold the agent up a quarter second more (a busy spell is waited out once, not per question).
    private func ask(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, answered: Bool) {
        guard ProcessInfo.processInfo.systemUptime >= busyUntil else { return (nil, false) }
        var value: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if answer == .cannotComplete { busyUntil = ProcessInfo.processInfo.systemUptime + 0.25 }
        return (answer == .success ? value : nil, answer != .cannotComplete)
    }
    private var busyUntil: TimeInterval = 0

    /// Every Desktop icon's frame (y down), freshly indexed (new items come and go): to keep other icons out of what the
    /// stand-in samples. Nil as soon as Finder doesn't answer: a hung Finder must not hold the agent up, nor read as an
    /// empty Desktop. Asked again within a moment (several stand-ins going up at once), the last walk stands.
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

    /// Walk the Desktop's icons afresh; false (keeping the last walk) if Finder didn't answer.
    @discardableResult
    private func index() -> Bool {
        // No Finder: not knowing for 5 s, then no icons (the glass goes). No Desktop (only just relaunched, a menu open):
        // not knowing, for as long as that lasts.
        func none() -> Bool {  // missing for 5 s on end (not a moment's blip): no icons
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
        var found: [String: AXUIElement] = [:], desktop = false
        guard let areas = kids(AXUIElementCreateApplication(finder.processIdentifier)) else { return false }
        for area in areas {  // the Desktop's (the other is the menu bar's); any question unanswered: keep the last walk
            let (role, answered) = ask(area, "AXRole")
            guard answered else { return false }
            guard role as? String == "AXScrollArea" else { continue }
            desktop = true
            guard let groups = kids(area) else { return false }
            for group in groups {
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
        return true
    }
}

/// What a Finder window showing the folder at `path` may be titled: its name as Finder shows it (":" as "/",
/// localized names), its file name, or its whole path (when Finder is set to show paths in titles).
func windowTitles(_ path: String) -> [String] {
    if let known = titleCache[path] { return known }  // (asked every tick of a drag: the display name costs a file lookup)
    let found = [FileManager.default.displayName(atPath: path), (path as NSString).lastPathComponent, path]
    titleCache[path] = found
    return found
}
private var titleCache: [String: [String]] = [:]  // (a renamed folder has a new path: no stale entry is ever asked for)

// -- the Desktop around an icon

/// Whether Finder takes a drop at `point` for the folder whose icon is `icon` (both on screen, y up): on its picture's
/// outline (Finder lets clicks and drops through the see-through parts of an icon) or on its name below.
func onFolder(_ point: CGPoint, _ icon: CGRect, name: String, items: Int?,
              labels: (text: CGFloat, info: Bool) = desktopLabels()) -> Bool {
    nameHit(icon, name: name, items: labels.info ? items : nil, text: labels.text).contains { $0.contains(point) }
        || outline(icon.width).contains(CGPoint(x: point.x - icon.minX, y: point.y - icon.minY))
}

/// Finder's Desktop View Options: its labels' text size, and whether it shows item counts under them.
func desktopLabels() -> (text: CGFloat, info: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    if now - labelsRead.at > 0.5 {  // (asked for every icon, every frame of a drag: read twice a second at most)
        let options = UserDefaults(suiteName: "com.apple.finder")?.dictionary(forKey: "DesktopViewSettings")?["IconViewSettings"] as? [String: Any]
        labelsRead = (now, ((options?["textSize"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 12, (options?["showItemInfo"] as? NSNumber)?.boolValue ?? false))
    }
    return labelsRead.labels
}
private var labelsRead: (at: TimeInterval, labels: (text: CGFloat, info: Bool)) = (-1, (12, false))

/// Where Finder takes a press or a drop on a Desktop icon's name (on screen, y up): its name's line and its item count's,
/// each only as wide as its own text, with a little room — wider would take in bare wallpaper or another icon placed
/// just below. Measured on macOS 26 (116 pt icons, text size 12): the name in bold 12 pt with
/// room for the iCloud glyph, 13–22 pt below the icon, Finder taking drops 62 pt from its middle; the count in 10 pt,
/// 28–36 pt below, Finder refusing them 45 pt from its middle. shortcut: measured at text size 12 only (other sizes
/// scale those lines with the text), in English ("No items", "1 item"), with labels at the bottom; a name too long for
/// one line wraps in Finder, this keeps it to one (capped). Measure again if drops on a name go wrong at other settings.
/// (nameArea, wider, is what the stand-in keeps out of its sample.)
func nameHit(_ icon: CGRect, name: String, items: Int?, text: CGFloat = 12) -> [CGRect] {
    func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    let k = text / 12
    let line = min(width(name, .boldSystemFont(ofSize: text)) + 18 * k + 12, icon.width + 36)  // + the iCloud glyph, + padding
    var lines = [CGRect(x: icon.midX - line / 2, y: icon.minY - 25 * k, width: line, height: 15 * k)]
    if let items {
        let count = width(items == 0 ? "No items" : items == 1 ? "1 item" : "\(items) items", .systemFont(ofSize: text - 2)) + 8
        lines.append(CGRect(x: icon.midX - count / 2, y: icon.minY - 38 * k, width: count, height: 13 * k))
    }
    return lines
}

/// Where a Desktop icon's name lies, below it (on screen, y up). shortcut: Finder doesn't say; with 116 pt icons and
/// 12 pt text the name sits 13–22 pt below the icon and the item count 28–36 pt (measured),
/// and names wrap wider than the icon: this takes from 10 to 56 pt down and a quarter more on each side.
func nameArea(_ icon: CGRect) -> CGRect {
    CGRect(x: icon.minX - icon.width / 4, y: icon.minY - 56, width: icon.width * 1.5, height: 46)
}

/// Whether one of Finder's menus is open (a right-click menu: Finder's own window at the pop-up menu level).
func finderMenuOpen() -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { $0[kCGWindowOwnerName as String] as? String == "Finder"
        && $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
}

/// Whether the Desktop shows at `point` (on screen, y up): no app's window lies over it. (The Dock's own don't count:
/// with the Desktop shown by a click on the wallpaper it lays a see-through window over the whole screen, which lets
/// clicks and drops through to the icons.)
func desktopShows(_ point: CGPoint) -> Bool {
    guard let top = NSScreen.screens.first?.frame.height else { return false }  // (no screen for a moment while displays change)
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return !windows.contains { window in
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        guard (0..<20).contains(layer), window[kCGWindowOwnerName as String] as? String != "Dock",
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }  // apps' windows and panels
        let frame = CGRect(x: bounds["X"] ?? 0, y: top - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0), width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        return frame.contains(point)
    }
}

/// What the stand-in of the folder whose icon is `frame`, in a window at `around`, keeps out of what it samples (in
/// the window): the other icons nearby (`others`, Finder's frames, y down) and every name (names wrap wider than icons),
/// the folder's own included (it is closest, and highlighted while selected), whatever lies off `screen`, and as much on
/// each side as lies off it on the other.
func cuts(_ frame: CGRect, _ around: CGRect, _ screen: CGRect, _ others: [CGRect], displays: [CGRect] = NSScreen.screens.map(\.frame)) -> [CGRect] {
    let iconsAround: [CGRect] = others.map { (icon: CGRect) -> CGRect in
        CGRect(x: icon.minX, y: screen.height - icon.minY - icon.height, width: icon.width, height: icon.height)  // AppKit's y runs up
    }.filter { !frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }  // (its own, even a point or two stale)
    let kept: [CGRect] = iconsAround.map { $0.insetBy(dx: -7, dy: -7) } + (iconsAround + [frame]).map(nameArea)  // (with their selection box)
    // Sampled no further on one side than the screen lets it go on the other: lopsided, a folder by the screen's edge took
    // its tone from one side only (4% too red right under the menu bar). Off the screen is never sampled.
    let display = displays.first { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? screen  // (the one it is on)
    let across = min(frame.minX - display.minX, display.maxX - frame.maxX), upDown = min(frame.minY - display.minY, display.maxY - frame.maxY)
    let fair = frame.insetBy(dx: -max(0, across), dy: -max(0, upDown))
    let offScreen = [CGRect(x: around.minX, y: fair.maxY, width: around.width, height: max(0, around.maxY - fair.maxY)),
                     CGRect(x: fair.maxX, y: around.minY, width: max(0, around.maxX - fair.maxX), height: around.height),
                     CGRect(x: around.minX, y: around.minY, width: max(0, fair.minX - around.minX), height: around.height),
                     CGRect(x: around.minX, y: around.minY, width: around.width, height: max(0, fair.minY - around.minY))]
    return (kept + offScreen).filter { $0.width > 0 && $0.height > 0 && $0.intersects(around) }
        .map { $0.offsetBy(dx: -around.minX, dy: -around.minY) }
}

/// Finder's frame for an icon (y down from the top of the main screen) in AppKit's (y up).
func appKit(_ icon: CGRect, _ screen: CGRect) -> CGRect {
    CGRect(x: icon.minX, y: screen.height - icon.minY - icon.height, width: icon.width, height: icon.height)
}

func scale(of frame: CGRect) -> CGFloat { NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2 }

/// The room a folder's window has around its icon: for the stand-in, the swell, a first sheet. Whole points, or the
/// window server would snap the window to whole pixels and leave the cover a fraction of a pixel off Finder's icon.
func room(_ icon: CGRect) -> CGFloat {
    max(glassRoom, standInReach * icon.width, firstSheetPop.values[0] * icon.height).rounded(.up)
}
