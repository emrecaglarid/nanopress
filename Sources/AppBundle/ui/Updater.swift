import AppKit
import Common
import CryptoKit

let nanopressRepo = URL(string: "https://github.com/emrecaglarid/nanopress").orDie()

/// Checks GitHub for a newer release and installs it in place: downloads the release's zip, checks it against the
/// checksum GitHub keeps for it, puts the new app where this one is, and restarts. Anything that can't be done in
/// place, like an app that isn't in a folder it may write to, falls back to the release page
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let page: URL
        let zip: URL?
        /// "sha256:…" from GitHub. Nil for releases published before GitHub kept checksums
        let digest: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        /// What it's doing, like "Downloading…"
        case installing(String)
        /// Why it failed, and where to download the release by hand
        case failed(String, URL?)
    }

    @Published private(set) var state = State.idle

    var isBusy: Bool {
        switch state {
            case .checking, .installing: true
            default: false
        }
    }

    private struct ReleaseJson: Decodable {
        let tag_name: String
        let html_url: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
    }

    func check() async {
        state = .checking
        let api = URL(string: "https://api.github.com/repos/emrecaglarid/nanopress/releases/latest").orDie()
        do {
            let (data, response) = try await URLSession.shared.data(from: api)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                state = .failed("No releases published yet.", nil)
                return
            }
            let json = try JSONDecoder().decode(ReleaseJson.self, from: data)
            let version = json.tag_name.hasPrefix("v") ? String(json.tag_name.dropFirst()) : json.tag_name
            let zip = json.assets.first { $0.name == "nanopress-v\(version).zip" }
            let release = Release(version: version, page: json.html_url, zip: zip?.browser_download_url, digest: zip?.digest)
            state = isNewerVersion(version, than: aeroSpaceAppVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed("Couldn't reach GitHub. Check your connection and try again.", nil)
        }
    }

    /// Whether this copy can replace itself. A debug build runs from the build folder, not from an app
    static var canInstallInPlace: Bool { canReplace(Bundle.main.bundleURL) }

    static func canReplace(_ app: URL) -> Bool {
        app.pathExtension == "app" && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    /// `installed` and `restart` are for the end-to-end test, which installs into a folder of its own
    func install(_ release: Release, replacing installed: URL = Bundle.main.bundleURL, restart: Bool = true) async {
        do {
            guard Self.canReplace(installed) else { throw UpdateError("nanopress can't replace itself where it's installed.") }
            guard let zipUrl = release.zip, let digest = release.digest else {
                throw UpdateError("This release can't be checked before installing.")
            }
            state = .installing("Downloading…")
            let (downloaded, _) = try await URLSession.shared.download(from: zipUrl)
            let work = FileManager.default.temporaryDirectory.appending(path: "nanopress-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appending(path: "nanopress.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            state = .installing("Checking…")
            guard try sha256Digest(of: zip) == digest.lowercased() else {
                throw UpdateError("The download doesn't match the release. Nothing was changed.")
            }
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let folder = work.appending(path: "nanopress-v\(release.version)")
            let app = folder.appending(path: "nanopress.app")
            let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
            guard version == release.version else { throw UpdateError("The download isn't nanopress \(release.version). Nothing was changed.") }
            // Signed ad hoc, so this proves no file in the app was changed or is missing, not who made it. The
            // checksum above, from GitHub, is what ties the download to the release
            try await run("/usr/bin/codesign", ["--verify", "--deep", app.path])
            try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            state = .installing("Installing…")
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: app)
            guard restart else {
                state = .upToDate
                return
            }
            replaceCommandLineTool(with: folder.appending(path: "bin/nanopress"))

            state = .installing("Restarting…")
            relaunch(installed)
        } catch {
            let reason = (error as? UpdateError)?.message ?? "The update couldn't be installed: \(error.localizedDescription)"
            state = .failed(reason, release.page)
        }
    }

    /// The `nanopress` command Homebrew links (used by `nanopress mcp`) should match the app. It lives outside the
    /// app, so it's replaced where the link points, if nanopress may write there
    private func replaceCommandLineTool(with new: URL) {
        guard FileManager.default.fileExists(atPath: new.path) else { return }
        for link in ["/opt/homebrew/bin/nanopress", "/usr/local/bin/nanopress"] {
            let target = URL(filePath: link).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: target.path), FileManager.default.isWritableFile(atPath: target.path) else { continue }
            let copy = target.deletingLastPathComponent().appending(path: ".nanopress-update")
            try? FileManager.default.removeItem(at: copy)
            guard (try? FileManager.default.copyItem(at: new, to: copy)) != nil else { continue }
            _ = try? FileManager.default.replaceItemAt(target, withItemAt: copy)
        }
    }

    /// Opens the new app once this one has quit. The shell outlives this process
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}

private struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// "sha256:…", the way GitHub writes an asset's digest
func sha256Digest(of file: URL) throws -> String {
    let hash = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
    return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
}

/// Compares the numbers of "1.2.3". A snapshot build counts as older than any release
func isNewerVersion(_ latest: String, than current: String) -> Bool {
    func numbers(_ version: String) -> [Int] {
        version.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = numbers(latest)
    let b = numbers(current)
    for index in 0 ..< max(a.count, b.count) {
        let x = a.getOrNil(atIndex: index) ?? 0
        let y = b.getOrNil(atIndex: index) ?? 0
        if x != y { return x > y }
    }
    return current.contains("SNAPSHOT") && !latest.contains("SNAPSHOT")
}

@MainActor
private func run(_ tool: String, _ arguments: [String]) async throws {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        process.terminationHandler = { process in
            if process.terminationStatus == 0 {
                continuation.resume()
            } else {
                continuation.resume(throwing: UpdateError("The update couldn't be unpacked or checked. Nothing was changed."))
            }
        }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}
