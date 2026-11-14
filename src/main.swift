import AppKit

// Entry point: the liquidfolder command line, or the menu bar app when opened as a .app.
let usage = """
Liquid Glass folders for the macOS Desktop and Finder.

  liquidfolder add <folder> [--colour clear] [--tint 0.6]   opt a folder in, or change its look
  liquidfolder remove <folder>                              give a folder its normal icon back
  liquidfolder list                                         show opted-in folders
  liquidfolder run                                          run the glass without the app
  liquidfolder icon <folder.iconset>                        write the app's icon (build.sh uses it)

Colours: \(colourNames.joined(separator: ", ")). Tint: 0 = ultra clear, 1 = fully tinted.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())

func number(_ text: String, _ name: String) -> Double {
    guard let value = Double(text) else { fail("\(name) must be a number") }
    return value
}

/// Take `--name value` out of the arguments.
func option(_ name: String) -> String? {
    guard let at = arguments.firstIndex(of: name) else { return nil }
    guard at + 1 < arguments.count else { fail("\(name) needs a value") }
    defer { arguments.removeSubrange(at...at + 1) }
    return arguments[at + 1]
}

switch arguments.first {
case "run":
    NSApplication.shared.setActivationPolicy(.accessory)
    let glass = Liquify()
    withExtendedLifetime(glass) { NSApplication.shared.run() }

case "list":
    var folders: [String: Style] = [:]
    do { folders = try loadConfig() } catch { fail("\(error)") }
    for (path, style) in folders.sorted(by: { $0.key < $1.key }) {
        print("\(path)  \(style.design), \(style.colour), tint \(style.tint)")
    }

case "add", "remove":
    let colour = option("--colour"), tint = option("--tint"), design = option("--design")
    guard arguments.count == 2 else { fail(usage) }
    let path = resolved(arguments[1])
    var folders: [String: Style]
    do { folders = try loadConfig() } catch { fail("\(error)") }
    if arguments[0] == "add" {
        var style = folders[path] ?? Style()
        if let colour { style.colour = colour }
        if let tint { style.tint = number(tint, "--tint") }
        if let design { style.design = design }
        if let problem = problemWith(path: path, style: style) { fail("\(path): \(problem)") }
        folders[path] = style
    } else {
        guard folders.removeValue(forKey: path) != nil else { fail("\(path) is not a glass folder") }
        NSWorkspace.shared.setIcon(nil, forFile: path, options: [])  // back to the normal icon
    }
    do { try saveConfig(folders) } catch { fail("Could not save \(configURL.path): \(error)") }

case nil where Bundle.main.bundlePath.hasSuffix(".app"):  // opened as the app: Finder, login, or `open`
    let app = App()
    NSApplication.shared.delegate = app
    withExtendedLifetime(app) { NSApplication.shared.run() }

case "icon":  // the glass folder with two sheets, at every size an app icon needs
    guard arguments.count == 2 else { fail(usage) }
    let set = URL(fileURLWithPath: arguments[1])
    try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try? iconBitmap(points * scale, "clear", 0.6, sheets: 2).representation(using: .png, properties: [:])?
                .write(to: set.appendingPathComponent(name))
        }
    }

case "-h", "--help", nil:
    print(usage)

default:
    fail(usage)
}
