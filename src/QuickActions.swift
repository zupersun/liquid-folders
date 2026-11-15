import AppKit

// "Liquify" and "Unliquify" Quick Actions in Finder's right-click menu, as Automator workflows in ~/Library/Services,
// and "Update Available" while there is one. Each writes the folders' paths to a file the app watches (takeRequests;
// App watches for "update-").

private let quickActions = [(name: "Liquify", request: "liquify", symbol: "drop", slashed: false),
                            (name: "Unliquify", request: "unliquify", symbol: "drop", slashed: true)]
private let updateAction = (name: "Update Available", request: "update", symbol: "circle.fill", slashed: false)
private let pbs = "pbs" as CFString, servicesStatus = "NSServicesStatus" as CFString  // which services are switched on

private func workflow(_ name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(name).workflow")
}

private func statusKey(_ name: String) -> String { "(null) - \(name) - runWorkflowAsService" }

/// Rewrites both and switches them on, unless one was switched off.
func installQuickActions() {
    var status = CFPreferencesCopyAppValue(servicesStatus, pbs) as? [String: Any] ?? [:]
    for action in quickActions { writeQuickAction(action, &status) }
    CFPreferencesSetAppValue(servicesStatus, status as CFDictionary, pbs)
    CFPreferencesAppSynchronize(pbs)
    NSUpdateDynamicServices()
}

/// Adds or removes "Update Available". Always switched on: it only exists while there is an update.
func showUpdateAction(_ shown: Bool) {
    guard shown != FileManager.default.fileExists(atPath: workflow(updateAction.name).path) else { return }
    var status = CFPreferencesCopyAppValue(servicesStatus, pbs) as? [String: Any] ?? [:]
    status[statusKey(updateAction.name)] = nil
    if shown { writeQuickAction(updateAction, &status) } else { try? FileManager.default.removeItem(at: workflow(updateAction.name)) }
    CFPreferencesSetAppValue(servicesStatus, status as CFDictionary, pbs)
    CFPreferencesAppSynchronize(pbs)
    NSUpdateDynamicServices()
}

private func writeQuickAction(_ action: (name: String, request: String, symbol: String, slashed: Bool), _ status: inout [String: Any]) {
    let (name, request, symbol, slashed) = action
    let contents = workflow(name).appendingPathComponent("Contents")
    try? FileManager.default.removeItem(at: workflow(name))
    try? FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    let script = """
        d="$HOME/Library/Application Support/LiquidFolder"; mkdir -p "$d"
        printf '%s\\n' "$@" > "$d/\(request)-$$.tmp" && mv "$d/\(request)-$$.tmp" "$d/\(request)-$$"
        pgrep -qx liquidfolder || open -g -b io.github.zupersun.liquidfolder
        """
    let step: [String: Any] = [
        "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action", "BundleIdentifier": "com.apple.RunShellScript",
        "ActionParameters": ["COMMAND_STRING": script, "inputMethod": 1, "shell": "/bin/zsh", "source": ""],
        "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.string"]],
        "AMProvides": ["Container": "List", "Types": ["com.apple.cocoa.string"]]]
    write(["AMDocumentVersion": "2", "actions": [["action": step]], "connectors": [String: Any](),
           "workflowMetaData": ["workflowTypeIdentifier": "com.apple.Automator.servicesMenu", "serviceApplicationBundleID": "com.apple.finder",
                                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject.folder"]],
          to: contents.appendingPathComponent("document.wflow"))
    // Finder lists a Quick Action only with an icon.
    write(["NSServices": [["NSMenuItem": ["default": name], "NSMessage": "runWorkflowAsService", "NSIconName": "workflowCustomImageTemplate",
                           "NSRequiredContext": ["NSApplicationIdentifier": "com.apple.finder"], "NSSendFileTypes": ["public.folder"]]]],
          to: contents.appendingPathComponent("Info.plist"))
    try? symbolIcon(symbol, slashed: slashed)?.write(to: contents.appendingPathComponent("Resources/workflowCustomImageTemplate.png"))
    if status[statusKey(name)] == nil {
        status[statusKey(name)] = ["presentation_modes": ["ContextMenu": 1, "FinderPreview": 1, "ServicesMenu": 1, "TouchBar": 0]]
    }
}

func removeQuickActions() {
    var status = CFPreferencesCopyAppValue(servicesStatus, pbs) as? [String: Any] ?? [:]
    for name in quickActions.map(\.name) + [updateAction.name] {
        try? FileManager.default.removeItem(at: workflow(name))
        status[statusKey(name)] = nil
    }
    CFPreferencesSetAppValue(servicesStatus, status as CFDictionary, pbs)
    CFPreferencesAppSynchronize(pbs)
}

private func write(_ plist: [String: Any], to url: URL) {
    try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
}

/// An SF Symbol (struck through for Unliquify): black on clear, 18 pt at 2x (Finder tints templates).
private func symbolIcon(_ symbol: String, slashed: Bool) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 36 * 4, bitsPerPixel: 32),
          let drop = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbol == "drop" ? 14 : 7, weight: .regular)
                .applying(.init(paletteColors: [.black])))
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
