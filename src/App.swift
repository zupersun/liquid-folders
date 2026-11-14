import AppKit
import ServiceManagement

// Menu bar app: starts at login with no Dock icon, asks for Accessibility, installs the Quick Actions,
// and offers an on/off switch and an uninstaller.

let enabledKey = "enabled"  // off keeps the folder list but shows no glass

final class App: NSObject, NSApplicationDelegate {
    private var glass: Liquify?
    private var item: NSStatusItem?
    private var defaults: UserDefaults { .standard }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [enabledKey: true])
        if SMAppService.mainApp.status == .notRegistered { try? SMAppService.mainApp.register() }  // start at login
        // Accessibility: to read Finder's icon positions and follow Mission Control. macOS prompts the first time.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        installQuickActions()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Liquid Folder")
        item.menu = NSMenu()
        self.item = item
        if defaults.bool(forKey: enabledKey) { glass = Liquify() }
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
