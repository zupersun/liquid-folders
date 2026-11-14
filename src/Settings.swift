import AppKit

// Settings: one small file, folder path -> style.

var configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LiquidFolder/folders.json")
let iconFile = "Icon\r"  // where macOS keeps a folder's custom icon

struct Style: Codable, Equatable {
    var design = "glass"
    var colour = "clear"
    var tint = 0.6
}

struct SettingsError: Error, CustomStringConvertible {
    let description: String
}

func loadConfig() throws -> [String: Style] {
    guard FileManager.default.fileExists(atPath: configURL.path) else { return [:] }
    do {
        return try JSONDecoder().decode([String: Style].self, from: Data(contentsOf: configURL))
    } catch {
        throw SettingsError(description: "\(configURL.path) is not valid (\(error)). Fix or delete it.")
    }
}

func saveConfig(_ folders: [String: Style]) throws {
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(folders).write(to: configURL, options: .atomic)  // swapped in whole: never read half-written
}

/// Carry a folder's settings over to where it is now (it was renamed or moved).
func renameInConfig(from old: String, to new: String) throws {
    var folders = try loadConfig()
    guard let style = folders.removeValue(forKey: old) else { return }
    folders[new] = style
    try saveConfig(folders)
}

// Which look a folder's custom icon shows, written on its icon file: an icon is only ever replaced by a different one.
let stampName = "net.liquidfolder.look"

func iconKey(_ style: Style, sheets: Int = 0) -> String { "\(pictureVersion) \(style.design) \(style.colour) \(style.tint) \(sheets)" }

/// How many sheets the folder's custom icon shows, as stamped on it (none if it has no current one).
func stampedSheets(_ folder: String) -> Int {
    iconStamp(folder).flatMap { $0.hasPrefix("\(pictureVersion) ") ? Int($0.split(separator: " ").last ?? "") : nil } ?? 0
}

func iconStamp(_ folder: String) -> String? {
    let file = folder + "/" + iconFile
    let size = getxattr(file, stampName, nil, 0, 0, 0)
    guard size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard getxattr(file, stampName, &bytes, size, 0, 0) == size else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}

func setIconStamp(_ folder: String, _ key: String) {
    _ = setxattr(folder + "/" + iconFile, stampName, key, key.utf8.count, 0, 0)
}

/// Why this settings entry cannot be used, or nil if it is fine.
func problemWith(path: String, style: Style) -> String? {
    var isFolder: ObjCBool = false
    if !FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) || !isFolder.boolValue { return "not a folder" }
    if style.design != "glass" { return "unknown design" }
    if colourNames.firstIndex(of: style.colour) == nil { return "unknown colour" }
    if !(0...1).contains(style.tint) { return "tint must be between 0 and 1" }
    return nil
}

/// Visible items in a folder, counted only as far as the icon can show.
func countItems(_ path: String, enough: Int = 5) throws -> Int {
    guard let folder = opendir(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { closedir(folder) }
    var count = 0
    while count < enough, let entry = readdir(folder) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if !name.hasPrefix(".") && name != iconFile { count += 1 }
    }
    return count
}

/// How many sheets a folder shows: none, one, two for a few items (2-4), three for many.
func sheetCount(_ items: Int) -> Int {
    items < 1 ? 0 : items == 1 ? 1 : items < 5 ? 2 : 3
}

/// A path as the settings store it: absolute, with symbolic links resolved.
func resolved(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    guard let real = realpath(expanded, nil) else { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
    defer { free(real) }
    return String(cString: real)
}

// Apple's folder colours, in the order Finder's tag menu shows them. "clear" is plain glass, the default.
let colourNames = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink",
                   "brown", "graphite", "clear"]

func systemColour(_ name: String) -> NSColor? {
    switch name {
    case "red": return .systemRed
    case "orange": return .systemOrange
    case "yellow": return .systemYellow
    case "green": return .systemGreen
    case "mint": return .systemMint
    case "teal": return .systemTeal
    case "cyan": return .systemCyan
    case "blue": return .systemBlue
    case "indigo": return .systemIndigo
    case "purple": return .systemPurple
    case "pink": return .systemPink
    case "brown": return .systemBrown
    case "graphite": return .systemGray
    default: return nil
    }
}

/// A colour's sRGB components, or nil for plain glass.
func rgb(_ name: String) -> (CGFloat, CGFloat, CGFloat)? {
    guard let colour = systemColour(name)?.usingColorSpace(.sRGB) else { return nil }
    return (colour.redComponent, colour.greenComponent, colour.blueComponent)
}

// -- watching a folder

/// Watch `path` (followed if renamed) for `events`, on the main queue: `changed` gets what was seen and the handle.
func watchPath(_ path: String, _ events: DispatchSource.FileSystemEvent,
               _ changed: @escaping (DispatchSource.FileSystemEvent, Int32) -> Void) -> DispatchSourceFileSystemObject? {
    let handle = open(path, O_EVTONLY)  // for change notifications only
    guard handle >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: events, queue: .main)
    source.setEventHandler { [unowned source] in changed(source.data, handle) }
    source.setCancelHandler { close(handle) }
    source.resume()
    return source
}

/// A glass folder was renamed or moved (to the Trash, too): its settings go with it. Its icon has gone with it already;
/// the settings watch then lays it out afresh under its new name.
func followMove(_ path: String, _ handle: Int32) {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(handle, F_GETPATH, &buffer) == 0 else { return }
    let now = resolved(String(cString: buffer))
    guard now != path else { return }
    do { try renameInConfig(from: path, to: now) } catch { print(error) }
}

func removeFromConfig(_ path: String) throws {
    var folders = try loadConfig()
    guard folders.removeValue(forKey: path) != nil else { return }
    try saveConfig(folders)
}

/// The folder's colour tags, as stored (Finder redraws the folder plain for a moment when they change).
func tagData(_ folder: String) -> Data? { attribute(folder, "com.apple.metadata:_kMDItemUserTags") }

/// Whether the folder was given a look of the user's own in Finder (Customize Folder's colour or symbol, which macOS
/// keeps in a "com.apple.icon.folder" attribute, or another icon in Get Info) or had its icon taken away.
/// shortcut: the attribute's name was not seen on this Mac; another icon or a removed one is caught either way.
func customizedByUser(_ folder: String) -> Bool {
    let size = listxattr(folder, nil, 0, 0)
    var names = [CChar](repeating: 0, count: max(0, size))
    if size > 0, listxattr(folder, &names, size, 0) == size,
       names.split(separator: 0).contains(where: { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("com.apple.icon.folder") }) {
        return true
    }
    return iconStamp(folder) == nil  // no icon file, or not this app's
}

private func attribute(_ file: String, _ name: String) -> Data? {
    let size = getxattr(file, name, nil, 0, 0, 0)
    guard size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    return getxattr(file, name, &bytes, size, 0, 0) == size ? Data(bytes) : nil
}

/// Folders the Quick Actions asked for: "Liquify" and "Unliquify" leave their paths, a line each, in "liquify-*" and
/// "unliquify-*" files next to the settings (no helper programs to start: at once). They are put in (or taken out of,
/// with their normal icon back) the settings and the files removed; true if any were taken.
func takeRequests() -> Bool {
    let folder = configURL.deletingLastPathComponent()
    let requests = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { ($0.hasPrefix("liquify-") || $0.hasPrefix("unliquify-")) && !$0.hasSuffix(".tmp") }
    guard !requests.isEmpty, var folders = try? loadConfig() else { return false }
    for request in requests {
        let file = folder.appendingPathComponent(request)
        for line in ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n") {
            let path = resolved(String(line))
            if request.hasPrefix("unliquify-") {
                if folders.removeValue(forKey: path) != nil { NSWorkspace.shared.setIcon(nil, forFile: path, options: []) }
            } else if problemWith(path: path, style: Style()) == nil {
                folders[path] = folders[path] ?? Style()
                // A look of the user's own (Customize Folder's symbol or colour, another icon) goes: it would show over the glass.
                removexattr(path, "com.apple.icon.folder#S", 0)
                if iconStamp(path) == nil { NSWorkspace.shared.setIcon(nil, forFile: path, options: []) }
            }
        }
        try? FileManager.default.removeItem(at: file)
    }
    try? saveConfig(folders)
    return true
}
