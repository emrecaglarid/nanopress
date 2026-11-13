@testable import AppBundle
import XCTest

@MainActor
final class UpdaterTest: XCTestCase {
    func testVersionsCompareByNumber() {
        XCTAssertTrue(isNewerVersion("0.2.0", than: "0.1.3"))
        XCTAssertTrue(isNewerVersion("0.10.0", than: "0.9.9"))
        XCTAssertFalse(isNewerVersion("0.2.0", than: "0.2.0"))
        XCTAssertFalse(isNewerVersion("0.1.3", than: "0.2.0"))
        XCTAssertTrue(isNewerVersion("0.2.0", than: "0.2.0-SNAPSHOT"))
    }

    func testDigestIsWrittenTheWayGitHubWritesIt() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "nanopress-digest-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try sha256Digest(of: file), "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Installs the latest published release over a copy of an app, the way the button in Settings does, without
    /// restarting. Needs the network, so it only runs when asked: NANOPRESS_UPDATE_E2E=1 swift test --filter UpdaterTest
    func testInstallsTheLatestReleaseInPlace() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NANOPRESS_UPDATE_E2E"] == "1")
        let folder = FileManager.default.temporaryDirectory.appending(path: "nanopress-e2e-\(UUID().uuidString)")
        let app = folder.appending(path: "nanopress.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let updates = UpdateChecker()
        await updates.check()
        guard case .available(let release) = updates.state else { return XCTFail("No release offered: \(updates.state)") }
        await updates.install(release, replacing: app, restart: false)
        XCTAssertEqual(updates.state, .upToDate, "\(updates.state)")
        XCTAssertEqual(Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String, release.version)
    }

    /// A download that doesn't match GitHub's checksum is never installed
    func testAMismatchedDownloadChangesNothing() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NANOPRESS_UPDATE_E2E"] == "1")
        let folder = FileManager.default.temporaryDirectory.appending(path: "nanopress-e2e-\(UUID().uuidString)")
        let app = folder.appending(path: "nanopress.app")
        let marker = app.appending(path: "Contents/old")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data().write(to: marker)
        defer { try? FileManager.default.removeItem(at: folder) }

        let updates = UpdateChecker()
        await updates.check()
        guard case .available(let release) = updates.state else { return XCTFail("No release offered: \(updates.state)") }
        let tampered = UpdateChecker.Release(version: release.version, page: release.page, zip: release.zip, digest: "sha256:" + String(repeating: "0", count: 64))
        await updates.install(tampered, replacing: app, restart: false)
        guard case .failed = updates.state else { return XCTFail("Installed anyway: \(updates.state)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The installed app was changed")
    }
}
