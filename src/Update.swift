import AppKit

// Updates from GitHub Releases: a check on launch and about once a day, and an in-place install on request.
// Only a release signed by the same developer as the running app is installed.

private let releases = URL(string: "https://github.com/zupersun/liquid-folders/releases")!
let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

final class Updater {
    /// A newer version on GitHub, if there is one.
    private(set) var available: String?
    var changed: () -> Void = {}
    private let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.zupersun.liquidfolder.update")

    init() {
        check()
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60
        scheduler.schedule { [weak self] done in
            DispatchQueue.main.async { self?.check() }
            done(.finished)
        }
    }

    deinit { scheduler.invalidate() }

    /// GitHub redirects releases/latest to the newest tag's page, so the version is read off where it lands.
    func check() {
        var request = URLRequest(url: releases.appendingPathComponent("latest"))
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let tag = response?.url?.lastPathComponent, tag.hasPrefix("v") else { return }
            let version = String(tag.dropFirst())
            DispatchQueue.main.async {
                guard let self else { return }
                let newer = isNewer(version, than: currentVersion) ? version : nil
                if newer != self.available {
                    self.available = newer
                    self.changed()
                }
            }
        }.resume()
    }

    /// Downloads the release, checks it, swaps it in for this app and relaunches. `failed` runs on the main queue.
    func install(failed: @escaping (String) -> Void) {
        guard let version = available else { return }
        let zip = releases.appendingPathComponent("download/v\(version)/Liquid-Folder.zip")
        URLSession.shared.downloadTask(with: zip) { file, response, error in
            let result = Result { try unpack(file, response, error, version) }
            DispatchQueue.main.async {
                do { try relaunch(as: result.get()) } catch { failed(error.localizedDescription) }
            }
        }.resume()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// Unzips the download next to this app (same volume, so it can be swapped in) and checks it is this app,
/// the expected version, signed by the same developer.
private func unpack(_ file: URL?, _ response: URLResponse?, _ error: Error?, _ version: String) throws -> URL {
    if let error { throw error }
    guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download didn't arrive.") }
    let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                             appropriateFor: Bundle.main.bundleURL, create: true)
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzip.arguments = ["-x", "-k", file.path, folder.path]
    try unzip.run()
    unzip.waitUntilExit()
    let app = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    let info = Bundle(url: app)
    guard unzip.terminationStatus == 0, info?.bundleIdentifier == Bundle.main.bundleIdentifier,
          info?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
    else { throw UpdateError("The download isn't Liquid Folder \(version).") }
    guard signedLikeThisApp(app) else { throw UpdateError("The download isn't signed by Liquid Folder's developer.") }
    return app
}

/// Whether `app` meets this app's designated requirement: same identifier, same signing certificate.
/// An ad hoc build's requirement is its own hash, so a build from source never takes an update.
private func signedLikeThisApp(_ app: URL) -> Bool {
    var running: SecCode?, me: SecStaticCode?, requirement: SecRequirement?, candidate: SecStaticCode?
    guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
          SecCodeCopyStaticCode(running, [], &me) == errSecSuccess, let me,
          SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess,
          SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
    else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
}

/// Puts `app` where this one is, then quits and opens it once this process has gone.
private func relaunch(as app: URL) throws {
    let here = Bundle.main.bundleURL
    _ = try FileManager.default.replaceItemAt(here, withItemAt: app)
    let reopen = Process()
    reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
    reopen.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                        here.path, String(ProcessInfo.processInfo.processIdentifier)]
    try reopen.run()
    NSApp.terminate(nil)
}

/// Dotted versions compared number by number: 1.10.0 is newer than 1.9.2; missing parts count as 0.
func isNewer(_ version: String, than other: String) -> Bool {
    let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = other.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : 0) != (i < b.count ? b[i] : 0) {
        return (i < a.count ? a[i] : 0) > (i < b.count ? b[i] : 0)
    }
    return false
}
