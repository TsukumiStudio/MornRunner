import AppKit
import SwiftUI

struct AppRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    let tag_name: String
    let assets: [Asset]

    func archive() throws -> Asset {
        guard Updater.parseVersion(tag_name) != nil,
              let asset = assets.first(where: { $0.name == "MornRunner.app.zip" }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/TsukumiStudio/MornRunner/releases/download/\(tag_name)/MornRunner.app.zip",
              let digest = asset.digest, digest.range(of: #"^sha256:[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw RunnerError.message("検証可能な更新ファイルがまだ公開されていません")
        }
        return asset
    }
}

@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(String), updating, updated, failed(String)
    }
    @Published private(set) var state: State = .idle
    private var release: AppRelease?
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    nonisolated static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }
    nonisolated static let cask = "tsukumistudio/tap/mornrunner"
    var isWorking: Bool { state == .checking || state == .updating }

    nonisolated static func parseVersion(_ raw: String) -> [Int]? {
        let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    nonisolated static func isNewer(latestTag: String, current: String) -> Bool {
        guard let latest = parseVersion(latestTag), let current = parseVersion(current) else { return false }
        for index in 0..<max(latest.count, current.count) {
            let lhs = index < latest.count ? latest[index] : 0
            let rhs = index < current.count ? current[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    func check() async {
        guard !isWorking, state != .updated else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/TsukumiStudio/MornRunner/releases/latest")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MornRunner", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                throw RunnerError.message("公開リリースはまだありません")
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let latest = try JSONDecoder().decode(AppRelease.self, from: data)
            guard Self.parseVersion(latest.tag_name) != nil else { throw URLError(.cannotParseResponse) }
            if Self.isNewer(latestTag: latest.tag_name, current: Self.version) {
                _ = try latest.archive()
                release = latest
                state = .available(latest.tag_name)
            } else { state = .upToDate }
        } catch { state = .failed(error.localizedDescription) }
    }

    func update() async {
        guard case .available = state, let release else { return }
        state = .updating
        let app = Bundle.main.bundleURL
        do {
            try await Task.detached(priority: .userInitiated) {
                let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
                if app.path == "/Applications/MornRunner.app", let brew,
                   try LocalRunner.command(brew, ["list", "--cask", Self.cask], timeout: 30).status == 0 {
                    try Self.runBrew(brew, ["update"])
                    try Self.runBrew(brew, ["upgrade", "--cask", Self.cask])
                    try Self.validateVersion(app: app, target: release.tag_name, previous: Self.version)
                } else {
                    try await Self.replaceDirectly(app: app, release: release)
                }
            }.value
            state = .updated
        } catch { state = .failed(error.localizedDescription) }
    }

    nonisolated static func runBrew(_ brew: String, _ arguments: [String]) throws {
        let response = try LocalRunner.command(brew, arguments,
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOMEBREW_NO_ENV_HINTS": "1"], timeout: 900)
        guard response.status == 0 else {
            throw RunnerError.message("Homebrew の更新に失敗しました。\n" + String(response.output.suffix(1200)))
        }
    }

    nonisolated static func validateVersion(app: URL, target: String, previous: String) throws {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "studio.tsukumi.MornRunner",
              let installed = info?["CFBundleShortVersionString"] as? String,
              isNewer(latestTag: installed, current: previous), !isNewer(latestTag: target, current: installed) else {
            throw RunnerError.message("更新先のバージョンを確認できません。Homebrew 版では配信の反映を待って再試行してください")
        }
    }

    nonisolated static func teamID(app: URL) throws -> String {
        let result = try LocalRunner.command("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        guard result.status == 0,
              let line = result.output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw RunnerError.message("アプリの署名を確認できません")
        }
        let team = String(line.dropFirst("TeamIdentifier=".count))
        guard !team.isEmpty, team != "not set" else { throw RunnerError.message("自動更新には署名済みの配布版を使用してください") }
        return team
    }

    nonisolated static func replaceDirectly(app: URL, release: AppRelease) async throws {
        let fm = FileManager.default
        guard app.pathExtension == "app", fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw RunnerError.message("アプリの保存先に書き込めません。ユーザーの Applications フォルダへ移動するか Homebrew 版を使用してください")
        }
        let expectedTeam = try teamID(app: app)
        let asset = try release.archive()
        var request = URLRequest(url: asset.browser_download_url)
        request.timeoutInterval = 300
        let (archive, response) = try await URLSession.shared.download(for: request)
        defer { try? fm.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try RunnerInstaller.verify(archive: archive, digest: asset.digest!)
        let staging = app.deletingLastPathComponent().appendingPathComponent(".mornrunner-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let unpack = try LocalRunner.command("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path], timeout: 120)
        let updated = staging.appendingPathComponent("MornRunner.app")
        guard unpack.status == 0 else { throw RunnerError.message("更新ファイルを展開できません") }
        try validateVersion(app: updated, target: release.tag_name, previous: version)
        try validateSignature(app: updated, expectedTeam: expectedTeam)
        try installVerifiedApp(updated, at: app)
    }

    nonisolated static func validateSignature(app: URL, expectedTeam: String) throws {
        let verified = try LocalRunner.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verified.status == 0, try teamID(app: app) == expectedTeam else {
            throw RunnerError.message("更新ファイルの署名が配布元と一致しません")
        }
        let assessed = try LocalRunner.command("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: 60)
        guard assessed.status == 0 else { throw RunnerError.message("更新ファイルの Apple 公証を確認できません") }
    }

    nonisolated static func installVerifiedApp(_ updated: URL, at app: URL) throws {
        _ = try FileManager.default.replaceItemAt(app, withItemAt: updated, backupItemName: ".MornRunner-previous-\(UUID().uuidString).app", options: .usingNewMetadataOnly)
    }

    func restart() {
        guard state == .updated else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$1\"", "--", Bundle.main.bundlePath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); NSApp.terminate(nil) }
        catch { state = .failed("アプリを手動で再起動してください") }
    }
}

struct UpdateControls: View {
    @ObservedObject var updater: Updater
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updater.state {
            case .idle:
                Button("最新を確認") { Task { await updater.check() } }
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("確認中…") }
            case .upToDate:
                Button("最新版です · 再確認") { Task { await updater.check() } }
            case .available(let tag):
                HStack {
                    Text(tag).font(.caption)
                    Spacer()
                    Button("最新へ更新") { Task { await updater.update() } }.buttonStyle(.borderedProminent)
                }
            case .updating:
                HStack { ProgressView().controlSize(.small); Text("更新中…") }
            case .updated:
                Button("再起動して適用") { updater.restart() }.buttonStyle(.borderedProminent)
            case .failed(let message):
                Button("再試行") { Task { await updater.check() } }
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}
