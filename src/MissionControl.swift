import AppKit

/// Fades the Desktop folders' glass out and in with Mission Control and App Exposé, where it stands and
/// with the swipe, as macOS fades the Desktop's icons. (The glass is stationary, so that a click on the
/// wallpaper leaves it in place; Mission Control would leave it showing too.)
///
/// A three-finger swipe reaches the Dock as a stream of private "dock swipe" events, which a listen-only
/// event tap sees as well: how far the swipe has gone, 1 being all the way, and how fast it was going when
/// let go. Mission Control follows it exactly, and the icons are as faded as it is far along (measured on
/// macOS 26). Let go, it carries on at that speed to the end (or back, if the fingers were turning back).
/// Opened or closed by a key, it runs a set course: see pressed. The Dock then says where it ended up, which
/// also covers Mission Control opened any other way (a hot corner, a click), though only once it is done.
final class MissionControlFade {
    /// One for the whole process: its event taps and its thread live as long as the process does, so an agent switched
    /// off and on again takes it up again rather than starting more of them. shortcut: while the glass is switched off
    /// the taps (passing every event straight through) and the activity that keeps the agent from napping stay on; give
    /// it a way to stop them if that ever matters.
    static let shared = MissionControlFade()
    private(set) var shown: CGFloat = 1   // the glass's opacity now
    private(set) var target: CGFloat = 1  // and where it is headed
    var show: ((CGFloat) -> Void)?        // sets the glass's opacity (the agent's, while there is one)
    private var open = false   // Mission Control or App Exposé shows, as the Dock says (or will, see expected)
    private var front = false  // and it is App Exposé
    private var expected = false  // open was flipped on letting go of a swipe, and the Dock has yet to say so
    private var swipes = 0        // swipes begun: only the latest one's check counts
    private var swipeEnds = Date.distantPast
    private var from: CGFloat = 1     // the glass's opacity when the swipe began
    private var ignoring = false      // this swipe goes nowhere: see swiped
    private var ramp: Timer?
    private var taps: [CFMachPort] = []
    private var observer: AXObserver?
    // A napping background app is run late and in bursts: the glass was seen to freeze through
    // a swipe and then jump. This keeps the agent awake and its timers exact; it costs nothing while idle.
    private let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                              reason: "The glass follows Mission Control's swipe as it happens")

    init(show: ((CGFloat) -> Void)? = nil) {  // (tests make their own)
        self.show = show
        listen()
        watchDock()
    }

    /// One dock swipe event. progress: signed, up is negative; phase: 1 began, 2 moved, 4 let go, 8 cancelled;
    /// speed: when let go, in progress per second.
    /// A swipe moves Mission Control on from wherever it is, even part way through finishing the last one;
    /// but one begun while it is still closing is let pass (measured on quick swipes).
    func swiped(_ progress: CGFloat, _ phase: Int64, _ speed: CGFloat) {
        if phase == 1 {
            ignoring = !open && expected
            if !ignoring { (swipes, swipeEnds, from) = (swipes + 1, .distantFuture, shown) }  // the Dock's word must not cut in
        }
        guard !ignoring else { return }
        let appExposeSwipe = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "showAppExposeGestureEnabled") ?? false
        let way: CGFloat = open ? (front ? -1 : 1) : progress < 0 ? -1 : appExposeSwipe ? 1 : 0  // the way that leads somewhere
        let along = min(1, max(0, progress * way))
        if phase == 4 || phase == 8 {
            let onward = speed * way  // shortcut: the Dock's choice guessed from the speed alone; its word puts it right
            let end: CGFloat = (onward > 0) == open ? 1 : 0  // closing, or staying closed: all of the glass
            head(to: end, seconds: min(0.4, max(0.05, Double(abs(end - shown) / max(abs(onward), 0.01)))), front: way > 0)
        } else {
            fadeTo(min(1, max(0, from + (open ? along : -along))), 0)  // at once: events come as often as frames
        }
    }

    /// A key pressed: F3 (Mission Control's key) opens or closes it, Escape closes it. Opened by a key, the
    /// Desktop's icons fade out eased in and out from 0.07 s to 0.31 s after it; closed, back in from 0.03 s
    /// to 0.25 s (measured frame by frame against the screen). The glass starts sooner (0.03 s, 0.015 s
    /// closing, as measured), as its changes reach the screen that much later.
    func pressed(_ key: Int64) {
        guard key == 160 && !(open && front) || key == 53 && open else { return }  // F3 in App Exposé goes to Mission Control
        if open { head(to: 1, seconds: 0.22, after: 0.015, eased: true) } else { head(to: 0, seconds: 0.24, after: 0.04, eased: true) }
    }

    /// Send the glass to `end` (1: Mission Control closed). A change is counted as done at once, so that a
    /// quick next gesture is read the right way, and checked once the Dock should have said so.
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
        if expected && opened != open { return }  // late word of an earlier swipe; the last one is yet to be told
        expected = false
        open = opened
        if opened { front = name == "AXExposeShowFrontWindows" }
        if Date() > swipeEnds { settle() }  // after a swipe, the glass is on its way already
    }

    private func settle() { fadeTo(open ? 0 : 1, 0.2) }

    /// Go to `opacity` at once, or over `seconds` after `delay`, evenly or eased in and out, step by step from
    /// a timer of our own: AppKit's window-opacity animations were seen to stall behind Mission Control.
    private func fadeTo(_ opacity: CGFloat, _ seconds: Double, after delay: Double = 0, eased: Bool = false) {
        if opacity == target && (ramp != nil || shown == opacity) { return }  // on its way there, or there
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

    /// The Dock's swipes (its own event type, 30) and the F3 and Escape keys. Filtering taps, which take only the
    /// Accessibility permission (listening ones take Input Monitoring; an AppKit key monitor never sees F3, a
    /// system shortcut). They let every event straight through, from a thread of their own, and hand only the
    /// few that matter to the main thread: a busy agent must never hold up the keyboard or the Dock.
    private func listen() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        Thread.detachNewThread { [self] in
            let callback: CGEventTapCallBack = { _, type, event, context in
                let me = Unmanaged<MissionControlFade>.fromOpaque(context!).takeUnretainedValue()
                let field = { (number: UInt32) in unsafeBitCast(number, to: CGEventField.self) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    me.taps.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
                } else if type == .keyDown {
                    let key = event.getIntegerValueField(.keyboardEventKeycode)  // only F3 and Escape are read; the rest pass untouched
                    if (key == 160 || key == 53) && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        DispatchQueue.main.async { me.pressed(key) }
                    }
                } else if event.getIntegerValueField(field(110)) == 23, event.getIntegerValueField(field(123)) == 2 {  // a dock swipe, up or down
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
