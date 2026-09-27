import Foundation
import Testing
@testable import MornRunner

private final class ReleaseProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var fixture: (Int, Data) = (404, Data())
    static func respond(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        fixture = (status, Data(body.utf8))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let fixture = Self.fixture; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct UpdaterTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MORN_SIGNED_UPDATE_SOURCE"] != nil))
    func signedBundleReplacement() throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MORN_SIGNED_UPDATE_SOURCE"]))
        let current = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MornRunner.app")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("MornRunner.app")
        let updated = root.appendingPathComponent("Incoming.app")
        try FileManager.default.copyItem(at: current, to: installed)
        try FileManager.default.copyItem(at: source, to: updated)
        let team = try Updater.teamID(app: installed)
        try Updater.validateSignature(app: updated, expectedTeam: team)
        #expect(throws: (any Error).self) { try Updater.validateSignature(app: updated, expectedTeam: "WRONGTEAM") }
        try Updater.installVerifiedApp(updated, at: installed)
        try Updater.validateSignature(app: installed, expectedTeam: team)
        let data = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(info?["CFBundleShortVersionString"] as? String == "0.2.0")
    }

    @Test func semanticVersionComparison() {
        #expect(Updater.isNewer(latestTag: "v0.10.0", current: "0.9.9"))
        #expect(!Updater.isNewer(latestTag: "v0.3", current: "0.3.0"))
        #expect(!Updater.isNewer(latestTag: "v0.2.9", current: "0.3.0"))
        for invalid in ["", "v", "1..2", "1.-2.3", "+1.0", "1.0-beta", "99999999999999999999999", "１.0"] {
            #expect(Updater.parseVersion(invalid) == nil)
        }
    }

    @Test @MainActor func releaseCheckStates() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let updater = Updater(session: session)
        ReleaseProtocol.respond(status: 404, body: "{}")
        await updater.check()
        #expect(updater.state == .failed("公開リリースはまだありません"))
        ReleaseProtocol.respond(status: 200, body: "{\"tag_name\":\"v0.2.0\",\"assets\":[]}")
        await updater.check()
        #expect(updater.state == .upToDate)
        let hash = "sha256:" + String(repeating: "a", count: 64)
        ReleaseProtocol.respond(status: 200, body: "{\"tag_name\":\"v0.3.0\",\"assets\":[{\"name\":\"MornRunner.app.zip\",\"browser_download_url\":\"https://github.com/TsukumiStudio/MornRunner/releases/download/v0.3.0/MornRunner.app.zip\",\"digest\":\"\(hash)\"}]}")
        await updater.check()
        #expect(updater.state == .available("v0.3.0"))
        ReleaseProtocol.respond(status: 200, body: "{\"tag_name\":\"v0.3.0\",\"assets\":[]}")
        await updater.check()
        if case .failed = updater.state {} else { Issue.record("An incomplete release must not be installable") }
        ReleaseProtocol.respond(status: 403, body: "{}")
        await updater.check()
        if case .failed = updater.state {} else { Issue.record("HTTP errors must be shown") }
    }

    @Test func rejectForeignDownload() {
        let release = AppRelease(tag_name: "v1.0.0", assets: [.init(name: "MornRunner.app.zip", browser_download_url: URL(string: "https://evil.test/MornRunner.app.zip")!, digest: "sha256:" + String(repeating: "a", count: 64))])
        #expect(throws: (any Error).self) { try release.archive() }
    }

    @Test func validateInstalledVersionAndIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        func write(_ identifier: String, _ version: String) throws {
            let dict = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        }
        try write("studio.tsukumi.MornRunner", "0.3.0")
        try Updater.validateVersion(app: root, target: "v0.3.0", previous: "0.2.0")
        #expect(throws: (any Error).self) { try Updater.validateVersion(app: root, target: "v0.4.0", previous: "0.2.0") }
        try write("other.app", "0.3.0")
        #expect(throws: (any Error).self) { try Updater.validateVersion(app: root, target: "v0.3.0", previous: "0.2.0") }
    }
}
