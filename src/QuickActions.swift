import AppKit

// "Liquify" and "Unliquify" Quick Actions in Finder's right-click menu, as Automator workflows in ~/Library/Services.
// Each writes the folders' paths to a file the app watches (takeRequests).

private let quickActions = [(name: "Liquify", slashed: false), (name: "Unliquify", slashed: true)]
private let pbs = "pbs" as CFString, servicesStatus = "NSServicesStatus" as CFString  // which services are switched on

private func workflow(_ name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(name).workflow")
}

private func statusKey(_ name: String) -> String { "(null) - \(name) - runWorkflowAsService" }

/// Rewrites both and switches them on, unless one was switched off.
func installQuickActions() {
    var status = CFPreferencesCopyAppValue(servicesStatus, pbs) as? [String: Any] ?? [:]
    for (name, slashed) in quickActions {
        let contents = workflow(name).appendingPathComponent("Contents"), request = name.lowercased()
        try? FileManager.default.removeItem(at: workflow(name))
        try? FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let script = """
            d="$HOME/Library/Application Support/LiquidFolder"; mkdir -p "$d"
            printf '%s\\n' "$@" > "$d/\(request)-$$.tmp" && mv "$d/\(request)-$$.tmp" "$d/\(request)-$$"
            pgrep -qx liquidfolder || open -g -b net.liquidfolder.app
            """
        let action: [String: Any] = [
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action", "BundleIdentifier": "com.apple.RunShellScript",
            "ActionParameters": ["COMMAND_STRING": script, "inputMethod": 1, "shell": "/bin/zsh", "source": ""],
            "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.string"]],
            "AMProvides": ["Container": "List", "Types": ["com.apple.cocoa.string"]]]
        write(["AMDocumentVersion": "2", "actions": [["action": action]], "connectors": [String: Any](),
               "workflowMetaData": ["workflowTypeIdentifier": "com.apple.Automator.servicesMenu", "serviceApplicationBundleID": "com.apple.finder",
                                    "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject.folder"]],
              to: contents.appendingPathComponent("document.wflow"))
        // Finder lists a Quick Action only with an icon.
        write(["NSServices": [["NSMenuItem": ["default": name], "NSMessage": "runWorkflowAsService", "NSIconName": "workflowCustomImageTemplate",
                               "NSRequiredContext": ["NSApplicationIdentifier": "com.apple.finder"], "NSSendFileTypes": ["public.folder"]]]],
              to: contents.appendingPathComponent("Info.plist"))
        try? dropIcon(slashed: slashed)?.write(to: contents.appendingPathComponent("Resources/workflowCustomImageTemplate.png"))
        if status[statusKey(name)] == nil {
            status[statusKey(name)] = ["presentation_modes": ["ContextMenu": 1, "FinderPreview": 1, "ServicesMenu": 1, "TouchBar": 0]]
        }
    }
    CFPreferencesSetAppValue(servicesStatus, status as CFDictionary, pbs)
    CFPreferencesAppSynchronize(pbs)
    NSUpdateDynamicServices()
}

func removeQuickActions() {
    var status = CFPreferencesCopyAppValue(servicesStatus, pbs) as? [String: Any] ?? [:]
    for (name, _) in quickActions {
        try? FileManager.default.removeItem(at: workflow(name))
        status[statusKey(name)] = nil
    }
    CFPreferencesSetAppValue(servicesStatus, status as CFDictionary, pbs)
    CFPreferencesAppSynchronize(pbs)
}

private func write(_ plist: [String: Any], to url: URL) {
    try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
}

/// The "drop" symbol, struck through for Unliquify: black on clear, 18 pt at 2x (Finder tints templates).
private func dropIcon(slashed: Bool) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 36 * 4, bitsPerPixel: 32),
          let drop = NSImage(systemSymbolName: "drop", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.black])))
    else { return nil }
    rep.size = NSSize(width: 18, height: 18)  // before the context: it draws in points
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let box = NSRect(x: (18 - drop.size.width) / 2, y: (18 - drop.size.height) / 2, width: drop.size.width, height: drop.size.height)
    drop.draw(in: box)
    if slashed {
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: box.minX + 1.5, y: box.maxY - 3.4))
        slash.line(to: NSPoint(x: box.maxX - 1.3, y: box.minY + 1.5))
        slash.lineCapStyle = .round
        slash.lineWidth = 3
        context.compositingOperation = .clear  // a gap either side of the slash
        slash.stroke()
        context.compositingOperation = .sourceOver
        slash.lineWidth = 1.3
        NSColor.black.setStroke()
        slash.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}
