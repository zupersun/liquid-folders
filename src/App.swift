import AppKit
import ServiceManagement

// Menu bar app: starts at login with no Dock icon, asks for Accessibility, installs the Quick Actions,
// and offers an on/off switch, updates and an uninstaller.

let enabledKey = "enabled"  // off keeps the folder list but shows no glass

final class App: NSObject, NSApplicationDelegate {
    private var glass: Liquify?
    private var item: NSStatusItem?
    private var defaults: UserDefaults { .standard }
    private let updater = Updater()
    private var updating = false
    private var requests: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [enabledKey: true])
        let firstRun = !FileManager.default.fileExists(atPath: configURL.path)  // also after Uninstall
        if SMAppService.mainApp.status == .notRegistered { try? SMAppService.mainApp.register() }  // start at login
        // Accessibility: to read Finder's icon positions and follow Mission Control. macOS prompts the first time.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        installQuickActions()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "LiquidFolder"  // its own name for macOS to remember it by (not the default "Item-0")
        item.isVisible = true
        item.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Liquid Folder")
        item.menu = NSMenu()
        self.item = item
        if firstRun { liquifyArrivals(Set(desktopFolders().values)) }  // a fresh install makes the Desktop's folders glass
        if defaults.bool(forKey: enabledKey) { glass = Liquify() }
        if !AXIsProcessTrusted() { startOnAccess() }
        updater.changed = { [weak self] in self?.rebuildMenu() }
        // The "Update Available" Quick Action leaves an "update-" file beside the settings.
        let folder = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        requests = watchPath(folder.path, [.write]) { [weak self] _, _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let asked = names.filter { $0.hasPrefix("update-") && !$0.hasSuffix(".tmp") }
            for name in asked { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            if !asked.isEmpty { self?.update() }
        }
        rebuildMenu()
    }

    /// Live glass needs Accessibility, which is granted after launch (macOS asks then): start it the moment it is.
    private func startOnAccess() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            guard let self, glass != nil else { return }  // switched off: Liquify starts with access when switched on
            glass = nil
            glass = Liquify()
        }
    }

    private func rebuildMenu() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems()
        let on = defaults.bool(forKey: enabledKey)
        let toggle = NSMenuItem(title: "Liquify", action: #selector(toggle), keyEquivalent: "")
        toggle.state = on ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        let available = updater.available != nil
        if available {
            let update = NSMenuItem(title: updating ? "Updating…" : "Update Available", action: updating ? nil : #selector(update),
                                    keyEquivalent: "")
            update.target = self
            update.onStateImage = dot(8)  // in the checkmark's place, left of the title
            update.state = .on
            menu.addItem(update)
        }
        menu.addItem(.separator())
        let uninstall = NSMenuItem(title: "Uninstall", action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        item?.button?.appearsDisabled = !on
        showBadge(available && !updating)
        showUpdateAction(available && !updating)
    }

    @objc private func update() {
        guard updater.available != nil, !updating else { return }
        updating = true
        rebuildMenu()
        updater.install { [weak self] problem in
            guard let self else { return }
            updating = false
            rebuildMenu()
            let alert = NSAlert()
            alert.messageText = "Couldn't update Liquid Folder"
            alert.informativeText = problem
            alert.addButton(withTitle: "Download Manually")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://github.com/zupersun/liquid-folders/releases/latest")!)
            }
        }
    }

    /// A blue dot on the menu bar icon while an update waits. A view over the icon, so the icon stays a template.
    private func showBadge(_ shown: Bool) {
        guard let button = item?.button else { return }
        let id = NSUserInterfaceItemIdentifier("badge")
        button.subviews.first { $0.identifier == id }?.removeFromSuperview()
        guard shown else { return }
        let badge = NSImageView(image: dot(6))
        badge.identifier = id
        badge.frame = NSRect(x: button.bounds.maxX - 8, y: button.isFlipped ? 3 : button.bounds.maxY - 9, width: 6, height: 6)
        button.addSubview(badge)
    }

    private func dot(_ size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    @objc private func toggle() {
        let on = !defaults.bool(forKey: enabledKey)
        defaults.set(on, forKey: enabledKey)
        if on {
            glass = Liquify()
        } else {
            glass = nil
            restoreIcons()
        }
        rebuildMenu()
    }

    /// Leaves nothing behind: icons, login item, Quick Actions, settings, the app itself.
    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Liquid Folder?"
        alert.informativeText = "Your folders get their normal icons back, and the app is moved to the Trash."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        glass = nil
        restoreIcons()
        try? SMAppService.mainApp.unregister()
        removeQuickActions()
        try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in NSApp.terminate(nil) }
    }

    private func restoreIcons() {
        for path in ((try? loadConfig()) ?? [:]).keys { NSWorkspace.shared.setIcon(nil, forFile: path, options: []) }
    }
}
