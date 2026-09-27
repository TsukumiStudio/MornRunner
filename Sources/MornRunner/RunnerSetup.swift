import CryptoKit
import Foundation

struct GitHubTarget: Equatable {
    let owner: String
    let repository: String?

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = text.contains("://") ? text : (text.lowercased().hasPrefix("github.com/") ? "https://" + text : "https://github.com/" + text)
        guard let url = URLComponents(string: urlText), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else {
            throw RunnerError.message("github.com の Organization またはリポジトリの URL を入力してください")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(valid.contains) }),
              !["settings", "organizations", "enterprises"].contains(parts[0].lowercased()) else {
            throw RunnerError.message("Organization は owner、リポジトリは owner/repository の形式で入力してください")
        }
        owner = parts[0]
        repository = parts.count == 2 ? parts[1] : nil
    }
    var url: String { "https://github.com/" + owner + (repository.map { "/" + $0 } ?? "") }
    var registrationPage: URL {
        URL(string: repository == nil
            ? "https://github.com/organizations/\(owner)/settings/actions/runners/new"
            : url + "/settings/actions/runners/new")!
    }
    var tokenEndpoint: String {
        repository.map { "repos/\(owner)/\($0)/actions/runners/registration-token" }
            ?? "orgs/\(owner)/actions/runners/registration-token"
    }
}

struct SetupRequest {
    let target: GitHubTarget
    let name: String
    let labels: String
    let root: URL

    init(target: String, name: String, labels: String, root: URL) throws {
        self.target = try GitHubTarget(target)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !name.isEmpty, name.count <= 64, name != ".", name != "..", name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RunnerError.message("ランナー名は 64 文字以内の英数字・ハイフン・アンダースコア・ピリオドで入力してください")
        }
        let labels = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 64 && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw RunnerError.message("追加ラベルは英数字・ハイフンなどを使い、カンマで区切ってください")
        }
        self.name = name
        self.labels = labels.joined(separator: ",")
        self.root = root.standardizedFileURL
    }
    var arguments: [String] {
        var result = ["--unattended", "--url", target.url, "--name", name, "--work", "_work"]
        if !labels.isEmpty { result += ["--labels", labels] }
        return result
    }
}

struct RunnerRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    let tag_name: String
    let assets: [Asset]

    func asset(architecture: String) throws -> Asset {
        let version = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              let asset = assets.first(where: { $0.name == "actions-runner-osx-\(architecture)-\(version).tar.gz" }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/actions/runner/releases/download/\(tag_name)/\(asset.name)",
              let digest = asset.digest, digest.range(of: #"^sha256:[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw RunnerError.message("この Mac 用の公式ランナー、または検証用 SHA-256 が見つかりません")
        }
        return asset
    }
}

struct InstallReceipt: Codable, Equatable {
    let target: String
    let name: String
    let labels: String
}

struct SetupOutcome {
    let root: URL
    let snapshot: RunnerSnapshot
}

enum RunnerInstaller {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }
    static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MornRunner/Runners")
    }
    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func registrationToken(for target: GitHubTarget) throws -> String {
        guard let gh = ghPath else { throw RunnerError.message("GitHub CLI が見つかりません。GitHub の画面から登録トークンをコピーしてください") }
        let result = try LocalRunner.command(gh, ["api", "--hostname", "github.com", "--method", "POST", target.tokenEndpoint], timeout: 30)
        guard result.status == 0 else {
            throw RunnerError.message("GitHub CLI からトークンを取得できませんでした。ログイン状態と登録先の管理権限を確認するか、GitHub の画面からコピーしてください")
        }
        struct Token: Decodable { let token: String }
        guard let data = result.output.data(using: .utf8), let token = try? JSONDecoder().decode(Token.self, from: data), !token.token.isEmpty else {
            throw RunnerError.message("GitHub から有効な登録トークンを取得できませんでした")
        }
        return token.token
    }

    static func latestRelease() async throws -> RunnerRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/actions/runner/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MornRunner", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RunnerError.message("公式ランナーの情報を取得できませんでした。ネットワークや GitHub API の利用制限を確認してください")
        }
        return try JSONDecoder().decode(RunnerRelease.self, from: data)
    }

    static func verify(archive: URL, digest: String) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == digest.lowercased() else { throw RunnerError.message("ダウンロードの SHA-256 が一致しません。ファイルは実行せずに中止しました") }
    }

    /// Existing installations are never overwritten. Only this app's matching incomplete install can resume.
    static func validateDestination(_ request: SetupRequest) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: request.root.path) else { return false }
        let marker = request.root.appendingPathComponent(".mornrunner-install.json")
        let expected = InstallReceipt(target: request.target.url, name: request.name, labels: request.labels)
        guard let data = try? Data(contentsOf: marker), let receipt = try? JSONDecoder().decode(InstallReceipt.self, from: data), receipt == expected else {
            throw RunnerError.message("保存先は既に使われています。既存ランナーを追加するか、別のランナー名・保存先を選んでください")
        }
        return true
    }

    static func install(_ request: SetupRequest, token: String,
                        progress: @escaping @Sendable (String) async -> Void) async throws -> SetupOutcome {
        let fm = FileManager.default
        let resume = try validateDestination(request)
        let configured = fm.fileExists(atPath: request.root.appendingPathComponent(".runner").path)
        if configured {
            var data = try Data(contentsOf: request.root.appendingPathComponent(".runner"))
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
            let existing = try JSONDecoder().decode(RunnerConfiguration.self, from: data)
            guard existing.agentName == request.name,
                  try GitHubTarget(existing.gitHubUrl).url.lowercased() == request.target.url.lowercased() else {
                throw RunnerError.message("保存先には別のランナーが登録されています。既存ランナーとして追加してください")
            }
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configured || !token.isEmpty else { throw RunnerError.message("GitHub の登録トークンを入力してください") }
        if !resume {
            await progress("公式ランナーのバージョンを確認中…")
            let release = try await latestRelease()
            let asset = try release.asset(architecture: architecture)
            await progress("\(asset.name) をダウンロード中…")
            var download = URLRequest(url: asset.browser_download_url)
            download.timeoutInterval = 300
            let (archive, response) = try await URLSession.shared.download(for: download)
            defer { try? fm.removeItem(at: archive) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RunnerError.message("ランナーのダウンロードに失敗しました") }
            await progress("ダウンロードを検証中…")
            try verify(archive: archive, digest: asset.digest!)
            let parent = request.root.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".mornrunner-staging-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            await progress("ランナーを展開中…")
            let extracted = try LocalRunner.command("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path], timeout: 120)
            guard extracted.status == 0, fm.fileExists(atPath: staging.appendingPathComponent("config.sh").path) else {
                throw RunnerError.message("ランナーを展開できませんでした")
            }
            let receipt = InstallReceipt(target: request.target.url, name: request.name, labels: request.labels)
            try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent(".mornrunner-install.json"), options: .atomic)
            try fm.moveItem(at: staging, to: request.root)
        }
        if !configured {
            await progress("GitHub にランナーを登録中…")
            let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            let environment = try LocalRunner.command("/bin/bash", [request.root.appendingPathComponent("env.sh").path],
                directory: request.root, environment: ["PATH": path])
            guard environment.status == 0 else { throw RunnerError.message("ランナーの実行環境を準備できませんでした") }
            // The runner consumes and clears this env var; tokens never enter shell text, argv, or preferences.
            // config.sh's macOS path is env.sh followed by Runner.Listener configure.
            // Execute the listener directly so a timeout cannot leave a registration child behind.
            let result = try LocalRunner.command(request.root.appendingPathComponent("bin/Runner.Listener").path, ["configure"] + request.arguments,
                directory: request.root, environment: ["ACTIONS_RUNNER_INPUT_TOKEN": token, "PATH": path], timeout: 180)
            guard result.status == 0 else {
                let message = result.output.replacingOccurrences(of: token, with: "[redacted]")
                throw RunnerError.message("GitHub への登録に失敗しました。期限切れ・管理権限・同名ランナーを確認し、新しいトークンで再試行してください。\n" + String(message.suffix(1800)))
            }
        }
        await progress("ログイン時に起動するサービスを設定中…")
        try installService(root: request.root)
        await progress("ランナーを起動中…")
        try LocalRunner.control(root: request.root, start: true)
        await progress("GitHub への接続を確認中…")
        var snapshot = LocalRunner.snapshot(root: request.root)
        for _ in 0..<15 {
            if snapshot.state == .idle || snapshot.state == .busy { break }
            try await Task.sleep(for: .seconds(2))
            snapshot = LocalRunner.snapshot(root: request.root)
        }
        return SetupOutcome(root: request.root, snapshot: snapshot)
    }

    static func installService(root: URL) throws {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".service").path) {
            _ = try LocalRunner.service(root: root)
            return
        }
        let result = try LocalRunner.command("/bin/bash", [root.appendingPathComponent("svc.sh").path, "install"], directory: root, timeout: 30)
        guard result.status == 0 else { throw RunnerError.message("サービスの設定に失敗しました。\n" + String(result.output.suffix(1200))) }
        _ = try LocalRunner.service(root: root)
    }
}
