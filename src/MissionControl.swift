import AppKit

/// Fades the glass like Desktop icons with Mission Control and App Exposé (stationary windows stay showing).
/// Follows swipes through private "dock swipe" events; the Dock's own notifications settle where it ended up.
final class MissionControlFade {
    /// One per process: its taps and thread live as long as the process, so the app switched back on reuses them.
    /// shortcut: taps and the no-nap activity stay on while the glass is off, add a way to stop them if that matters.
    static let shared = MissionControlFade()
    private(set) var shown: CGFloat = 1   // opacity now
    private(set) var target: CGFloat = 1  // opacity heading to
    var show: ((CGFloat) -> Void)?        // applies the opacity
    private var open = false   // Mission Control or App Exposé is open (or about to be, see expected)
    private var front = false  // it is App Exposé
    private var expected = false  // open was guessed at a swipe's end; the Dock hasn't confirmed yet
    private var swipes = 0        // only the latest gesture's check counts
    private var swipeEnds = Date.distantPast
    private var from: CGFloat = 1     // opacity when the swipe began
    private var ignoring = false      // this swipe goes nowhere, see swiped
    private var ramp: Timer?
    private var taps: [CFMachPort] = []
    private var observer: AXObserver?
    // A napping background app runs late and in bursts: the glass froze through a swipe, then jumped. Free when idle.
    private let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                              reason: "The glass follows Mission Control's swipe as it happens")

    init(show: ((CGFloat) -> Void)? = nil) {  // tests make their own
        self.show = show
        listen()
        watchDock()
    }

    /// progress: signed, up is negative (1 = all the way); phase: 1 began, 2 moved, 4 let go, 8 cancelled;
    /// speed: progress per second at let-go. A swipe begun while Mission Control is still closing goes nowhere.
    func swiped(_ progress: CGFloat, _ phase: Int64, _ speed: CGFloat) {
        if phase == 1 {
            ignoring = !open && expected
            if !ignoring { (swipes, swipeEnds, from) = (swipes + 1, .distantFuture, shown) }  // Dock may not cut in
        }
        guard !ignoring else { return }
        let appExposeSwipe = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "showAppExposeGestureEnabled") ?? false
        let way: CGFloat = open ? (front ? -1 : 1) : progress < 0 ? -1 : appExposeSwipe ? 1 : 0  // useful direction
        let along = min(1, max(0, progress * way))
        if phase == 4 || phase == 8 {
            // shortcut: the Dock's choice is guessed from speed alone (its word corrects it), refine if misses show
            let onward = speed * way
            let end: CGFloat = (onward > 0) == open ? 1 : 0  // closing or staying closed: full glass
            head(to: end, seconds: min(0.4, max(0.05, Double(abs(end - shown) / max(abs(onward), 0.01)))), front: way > 0)
        } else {
            fadeTo(min(1, max(0, from + (open ? along : -along))), 0)  // at once: events come as often as frames
        }
    }

    /// F3 toggles Mission Control, Escape closes it. Measured: icons fade out 0.07–0.31 s after the key, back in
    /// 0.03–0.25 s. The glass leads by 0.03 s (0.015 s closing), as its changes reach the screen that much later.
    func pressed(_ key: Int64) {
        // F3 in App Exposé goes to Mission Control
        guard key == 160 && !(open && front) || key == 53 && open else { return }
        if open { head(to: 1, seconds: 0.22, after: 0.015, eased: true) } else { head(to: 0, seconds: 0.24, after: 0.04, eased: true) }
    }

    /// `end` 1 is closed. Counted as done at once so a quick next gesture reads right; checked once the Dock should
    /// have confirmed it.
    private func head(to end: CGFloat, seconds: Double, after delay: Double = 0, eased: Bool = false, front: Bool = false) {
        swipes += 1
        swipeEnds = Date() + delay + seconds
        fadeTo(end, seconds, after: delay, eased: eased)
        if (end == 0) != open { (open, self.front, expected) = (end == 0, end == 0 && front, true) }
        let ticket = swipes
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + seconds + 0.4) { [weak self] in
            guard let self, self.swipes == ticket else { return }  // a newer gesture has taken over
            if self.expected { self.open.toggle(); self.expected = false }  // the Dock never said so: it went back
            self.settle()
        }
    }

    func dockSays(_ name: String) {
        let opened: Bool
        switch name {
        case "AXExposeShowAllWindows", "AXExposeShowFrontWindows": opened = true
        case "AXExposeExit": opened = false
        default: return  // AXExposeShowDesktop: the icons stay
        }
        if expected && opened != open { return }  // late word of an earlier gesture
        expected = false
        open = opened
        if opened { front = name == "AXExposeShowFrontWindows" }
        if Date() > swipeEnds { settle() }  // during a gesture the glass is on its way already
    }

    private func settle() { fadeTo(open ? 0 : 1, 0.2) }

    /// Steps on its own timer: AppKit's window-opacity animations stall behind Mission Control.
    private func fadeTo(_ opacity: CGFloat, _ seconds: Double, after delay: Double = 0, eased: Bool = false) {
        if opacity == target && (ramp != nil || shown == opacity) { return }  // there, or on its way
        ramp?.invalidate()
        ramp = nil
        target = opacity
        guard seconds > 0 else { return set(opacity) }
        let from = shown, start = Date() + delay
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            let done = min(1, max(0, Date().timeIntervalSince(start) / seconds))
            self?.set(from + (opacity - from) * CGFloat(eased ? done * done * (3 - 2 * done) : done))
            if done == 1 { timer.invalidate(); self?.ramp = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        ramp = timer
    }

    private func set(_ opacity: CGFloat) {
        guard opacity != shown else { return }
        shown = opacity
        show?(opacity)
    }

    /// Taps for dock swipes (event type 30) and F3/Escape. Filtering taps need only Accessibility (listen-only ones
    /// need Input Monitoring; AppKit never sees F3). Own thread, all events passed on: a busy app can't hold up input.
    private func listen() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        Thread.detachNewThread { [self] in
            let callback: CGEventTapCallBack = { _, type, event, context in
                let me = Unmanaged<MissionControlFade>.fromOpaque(context!).takeUnretainedValue()
                let field = { (number: UInt32) in unsafeBitCast(number, to: CGEventField.self) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    me.taps.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
                } else if type == .keyDown {
                    let key = event.getIntegerValueField(.keyboardEventKeycode)
                    if (key == 160 || key == 53) && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        DispatchQueue.main.async { me.pressed(key) }
                    }
                } else if event.getIntegerValueField(field(110)) == 23, event.getIntegerValueField(field(123)) == 2 {
                    // a vertical dock swipe
                    let swipe = (event.getDoubleValueField(field(124)), event.getIntegerValueField(field(132)), event.getDoubleValueField(field(129)))
                    DispatchQueue.main.async { me.swiped(swipe.0, swipe.1, swipe.2) }
                }
                return Unmanaged.passUnretained(event)
            }
            for mask in [CGEventMask(1 << 30), CGEventMask(1 << CGEventType.keyDown.rawValue)] {
                guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                                  eventsOfInterest: mask, callback: callback, userInfo: context) else { continue }
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                taps.append(tap)
            }
            if taps.count < 2 { print("Without Accessibility permission, the glass will fade only once Mission Control has opened or closed.") }
            CFRunLoopRun()
        }
    }

    private func watchDock() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let created = AXObserverCreate(dock.processIdentifier, { _, _, name, context in
            Unmanaged<MissionControlFade>.fromOpaque(context!).takeUnretainedValue().dockSays(name as String)
        }, &observer)
        guard created == .success, let observer else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for name in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeExit"] {
            AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
