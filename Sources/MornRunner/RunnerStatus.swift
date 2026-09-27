import Foundation

enum RunnerState: String, Codable {
    case notConfigured, stopped, connecting, idle, busy, offline, unknown

    var title: String {
        switch self {
        case .notConfigured: return "未設定"
        case .stopped: return "停止中"
        case .connecting: return "接続中"
        case .idle: return "待機中"
        case .busy: return "ジョブ実行中"
        case .offline: return "接続エラー"
        case .unknown: return "確認できません"
        }
    }
    var symbol: String {
        switch self {
        case .notConfigured: return "plus.circle"
        case .stopped: return "stop.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .idle: return "checkmark.circle.fill"
        case .busy: return "gearshape.2.fill"
        case .offline: return "wifi.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct RunnerConfiguration: Decodable {
    let agentName: String
    let gitHubUrl: String
}

struct RunnerSnapshot: Codable {
    var name = "GitHub Actions Runner"
    var githubURL = ""
    var state: RunnerState = .unknown
    var detail = "状態を確認しています…"
    var serviceLoaded = false
    var listenerRunning = false
    var checkedAt = Date()
    var logPath: String?
}

/// Interpret only a log belonging to the currently running listener.
enum LogStatus {
    static func parse(_ log: String) -> (RunnerState, String) {
        var state: RunnerState = .connecting
        var detail = "GitHub への接続を確認しています"
        for line in log.components(separatedBy: .newlines) {
            // Terminal messages describe the runner lifecycle; a job's failure is not a connection failure.
            if line.contains("Listening for Jobs") {
                state = .idle; detail = "ジョブを受け付けています"
            } else if let range = line.range(of: "Running job: ") {
                state = .busy; detail = String(line[range.upperBound...])
            } else if line.contains("Job ") && line.contains(" completed with result:") {
                state = .idle; detail = "前回のジョブ: " + String(line.components(separatedBy: "completed with result:").last ?? "").trimmingCharacters(in: .whitespaces)
            } else if line.contains("Runner connect error:") || line.contains("Failed to create session") || line.contains("MessageListener]") && line.contains("ERR ") {
                state = .offline; detail = "GitHub との通信に失敗しています。ログを確認してください"
            } else if line.contains("Runner reconnected.") {
                state = .idle; detail = "GitHub に再接続しました"
            } else if line.contains("exiting") && line.contains("Listener]") {
                state = .connecting; detail = "ランナーの再接続を待っています"
            }
        }
        return (state, detail)
    }

    static func date(of filename: String) -> Date? {
        guard filename.hasPrefix("Runner_"), filename.count >= 22 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(filename.dropFirst(7).prefix(15)))
    }

    static func belongsToCurrentListener(filename: String, started: Date) -> Bool {
        guard let date = date(of: filename) else { return false }
        return date >= started.addingTimeInterval(-2)
    }
}

struct CommandResult {
    let status: Int32
    let output: String
}

enum RunnerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum LocalRunner {
    // Invoked from a detached task. File-backed output avoids pipe buffer deadlocks.
    static func command(_ executable: String, _ arguments: [String], directory: URL? = nil,
                        environment extra: [String: String] = [:], timeout: TimeInterval = 15) throws -> CommandResult {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(3)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw RunnerError.message("コマンドがタイムアウトしました。状態を再確認してください")
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: try String(contentsOf: outputURL, encoding: .utf8))
    }

    static func service(root: URL) throws -> (url: URL, label: String) {
        let file = try String(contentsOf: root.appendingPathComponent(".service"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: file)
        let allowedDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == allowedDirectory else {
            throw RunnerError.message("ユーザーの LaunchAgents に登録されたランナーを選択してください")
        }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        guard let label = plist?["Label"] as? String,
              label.hasPrefix("actions.runner."),
              let workingDirectory = plist?["WorkingDirectory"] as? String,
              URL(fileURLWithPath: workingDirectory).standardizedFileURL == root.standardizedFileURL else {
            throw RunnerError.message("ランナーフォルダとサービス設定が一致しません")
        }
        return (url, label)
    }

    static func tail(_ url: URL, bytes: UInt64 = 524_288) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
    }

    static func snapshot(root: URL) -> RunnerSnapshot {
        var result = RunnerSnapshot()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".runner").path) else {
            result.state = .notConfigured
            result.detail = "新しいランナーをセットアップするか、既存のランナーを追加してください"
            return result
        }
        do {
            var data = try Data(contentsOf: root.appendingPathComponent(".runner"))
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
            let config = try JSONDecoder().decode(RunnerConfiguration.self, from: data)
            result.name = config.agentName
            result.githubURL = config.gitHubUrl
            let svc = try service(root: root)
            let launch = try command("/bin/launchctl", ["print", "gui/\(getuid())/\(svc.label)"])
            result.serviceLoaded = launch.status == 0
            let processes = try command("/bin/ps", ["-axo", "lstart=,command="])
            guard processes.status == 0 else { throw RunnerError.message("プロセスを確認できません") }
            let listener = root.appendingPathComponent("bin/Runner.Listener").path + " run"
            let processLine = processes.output.components(separatedBy: .newlines).first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count > 25 else { return false }
                let command = String(trimmed.dropFirst(25)).trimmingCharacters(in: .whitespaces)
                return command == listener || command.hasPrefix(listener + " ")
            }
            guard let processLine else {
                result.state = result.serviceLoaded && launch.output.contains("state = running") ? .connecting : .stopped
                result.detail = result.state == .stopped ? "ランナーは起動していません" : "ランナープロセスの起動を待っています"
                return result
            }
            result.listenerRunning = true
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            guard let started = formatter.date(from: String(processLine.trimmingCharacters(in: .whitespaces).prefix(24))) else {
                throw RunnerError.message("プロセスの開始時刻を確認できません")
            }
            let logs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("_diag"), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Runner_") && $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            guard let latest = logs.first, LogStatus.belongsToCurrentListener(filename: latest.lastPathComponent, started: started) else {
                result.state = .connecting
                result.detail = "現在のプロセスの接続ログを待っています"
                return result
            }
            result.logPath = latest.path
            let parsed = LogStatus.parse(try tail(latest))
            result.state = parsed.0
            result.detail = parsed.1
        } catch {
            result.state = .unknown
            result.detail = error.localizedDescription
        }
        return result
    }

    static func control(root: URL, start: Bool) throws {
        let svc = try service(root: root)
        let domain = "gui/\(getuid())"
        if start {
            let current = snapshot(root: root)
            if current.listenerRunning { return }
            let enable = try command("/bin/launchctl", ["enable", "\(domain)/\(svc.label)"])
            guard enable.status == 0 else { throw RunnerError.message(enable.output) }
            let args = current.serviceLoaded ? ["kickstart", "\(domain)/\(svc.label)"] : ["bootstrap", domain, svc.url.path]
            let response = try command("/bin/launchctl", args)
            guard response.status == 0 else { throw RunnerError.message(response.output) }
        } else {
            let response = try command("/bin/launchctl", ["bootout", "\(domain)/\(svc.label)"])
            guard response.status == 0 else { throw RunnerError.message(response.output) }
        }
    }
}
