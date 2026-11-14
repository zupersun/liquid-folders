import AppKit
import ServiceManagement

// The app around the agent, for everyday use: it starts at login with no Dock icon, asks for the one permission it
// needs, adds "Liquify" and "Unliquify" to a folder's right-click menu (Quick Actions), and puts one switch and an
// uninstaller in a small menu bar menu.

let enabledKey = "enabled"  // in the app's own defaults: off keeps the list of glass folders but shows none

final class App: NSObject, NSApplicationDelegate {
    private var agent: Agent?
    private var item: NSStatusItem?
    private var defaults: UserDefaults { .standard }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [enabledKey: true])
        if SMAppService.mainApp.status == .notRegistered { try? SMAppService.mainApp.register() }  // start at login
        // The one permission: Accessibility, to know where Finder puts the folder on the Desktop and to follow
        // Mission Control's swipe. macOS shows its own prompt the first time.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        installQuickActions()
        NSUpdateDynamicServices()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Liquid Folder")
        item.menu = NSMenu()
        self.item = item
        if defaults.bool(forKey: enabledKey) { agent = Agent() }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems()
        let on = defaults.bool(forKey: enabledKey)
        let toggle = NSMenuItem(title: "Liquid Glass", action: #selector(toggle), keyEquivalent: "")
        toggle.state = on ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let uninstall = NSMenuItem(title: "Uninstall Liquid Folder…", action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        item?.button?.appearsDisabled = !on
    }

    /// Off: every glass folder gets its normal icon back and the Desktop glass goes; the list is kept for turning on.
    @objc private func toggle() {
        let on = !defaults.bool(forKey: enabledKey)
        defaults.set(on, forKey: enabledKey)
        if on {
            agent = Agent()
        } else {
            agent = nil
            restoreIcons()
        }
        rebuildMenu()
    }

    /// Give every folder back its normal icon, take the app out of login items, delete its settings, and put the
    /// app in the Trash: nothing of it is left behind.
    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Liquid Folder?"
        alert.informativeText = "Your folders get their normal icons back, and the app is moved to the Trash."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        agent = nil
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

    /// "Liquify" and "Unliquify" in Finder's right-click menu, under Quick Actions (one folder or many), installed where
    /// Finder lists Quick Actions from. They leave the folders' paths for the agent (see takeRequests).
    private let quickActions = ["Liquify", "Unliquify"]
    private func quickAction(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(name).workflow")
    }
    private func statusKey(_ name: String) -> String { "(null) - \(name) - runWorkflowAsService" }
    private let servicesStatus = "NSServicesStatus" as CFString

    /// Install the Quick Actions from the app (afresh, so that they are always this version's), switched on in Finder's
    /// Quick Actions as the user would in its Customize list (unless they switched one off).
    private func installQuickActions() {
        var status = CFPreferencesCopyAppValue(servicesStatus, "pbs" as CFString) as? [String: Any] ?? [:]
        for name in quickActions {
            guard let source = Bundle.main.url(forResource: name, withExtension: "workflow") else { continue }
            try? FileManager.default.createDirectory(at: quickAction(name).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: quickAction(name))
            try? FileManager.default.copyItem(at: source, to: quickAction(name))
            if status[statusKey(name)] == nil {
                status[statusKey(name)] = ["presentation_modes": ["ContextMenu": 1, "FinderPreview": 1, "ServicesMenu": 1, "TouchBar": 0]]
            }
        }
        CFPreferencesSetAppValue(servicesStatus, status as CFDictionary, "pbs" as CFString)
        CFPreferencesAppSynchronize("pbs" as CFString)
    }

    private func removeQuickActions() {
        var status = CFPreferencesCopyAppValue(servicesStatus, "pbs" as CFString) as? [String: Any] ?? [:]
        for name in quickActions {
            try? FileManager.default.removeItem(at: quickAction(name))
            status[statusKey(name)] = nil
        }
        CFPreferencesSetAppValue(servicesStatus, status as CFDictionary, "pbs" as CFString)
        CFPreferencesAppSynchronize("pbs" as CFString)
    }
}
