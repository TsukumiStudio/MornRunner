import Foundation

struct JobRecord: Identifiable, Hashable {
    let name: String
    let started: Date
    var finished: Date?
    var result: String?
    var id: Date { started }
    var isRunning: Bool { finished == nil && result == nil }
    var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }

    var resultTitle: String {
        switch result {
        case nil: return "実行中"
        case "Succeeded": return "成功"
        case "Failed": return "失敗"
        case "Canceled": return "キャンセル"
        case let other?: return other
        }
    }
}

struct RunnerEvent: Identifiable, Hashable {
    enum Kind: String, Hashable { case listenerStarted, connected, connectError, reconnected, sleep, wake }
    let date: Date
    let kind: Kind
    let message: String
    var id: String { "\(date.timeIntervalSince1970)-\(kind.rawValue)-\(message)" }
}

struct JobProgress: Hashable {
    var totalSteps: Int?
    var completedSteps = 0
    var currentStep: String?
}

struct RunnerActivity: Hashable {
    var jobs: [JobRecord] = []          // newest first
    var events: [RunnerEvent] = []      // newest first
    var progress: JobProgress?
    var runnerLogPath: String?
    var workerLogPath: String?
    var runnerLogTail = ""
    var workerLogTail = ""
    var runnerLogEssentials = ""
    var workerLogEssentials = ""
    var currentJob: JobRecord? { jobs.first.flatMap { $0.isRunning ? $0 : nil } }
}

/// Reads the official runner's diagnostic logs (and the Mac's sleep log) into a local activity view.
/// Everything here is a heuristic over log text; nothing talks to GitHub.
enum ActivityLog {
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Parses "yyyy-MM-dd HH:mm:ss" at the start of `text` as UTC, optionally adjusted by a "+HHMM" offset at index 20.
    static func date(from text: Substring) -> Date? {
        let bytes = Array(text.utf8.prefix(25))
        guard bytes.count >= 19 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              bytes[4] == 45, bytes[7] == 45, bytes[13] == 58, bytes[16] == 58 else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard var date = utcCalendar.date(from: components) else { return nil }
        if bytes.count >= 25, bytes[19] == 32, bytes[20] == 43 || bytes[20] == 45,
           let offsetHours = number(21..<23), let offsetMinutes = number(23..<25) {
            let offset = TimeInterval(offsetHours * 3600 + offsetMinutes * 60)
            date = date.addingTimeInterval(bytes[20] == 43 ? -offset : offset)
        }
        return date
    }

    /// Timestamp of a "[yyyy-MM-dd HH:mm:ssZ LEVEL Source] message" diagnostic line.
    static func lineDate(_ line: Substring) -> Date? {
        guard line.first == "[" else { return nil }
        return date(from: line.dropFirst())
    }

    /// Jobs and lifecycle events recorded by one Runner_*.log. Jobs come back oldest first.
    static func parseRunnerLog(_ text: String) -> (jobs: [JobRecord], events: [RunnerEvent]) {
        var jobs: [JobRecord] = []
        var events: [RunnerEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let date = lineDate(line) else { continue }
            if let range = line.range(of: "Running job: ") {
                jobs.append(JobRecord(name: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces), started: date))
            } else if line.contains(" completed with result: "), let range = line.range(of: "Job ") {
                let parts = line[range.upperBound...].components(separatedBy: " completed with result: ")
                guard parts.count == 2 else { continue }
                let name = parts[0], result = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = jobs.lastIndex(where: { $0.name == name && $0.isRunning }) {
                    jobs[index].finished = date
                    jobs[index].result = result
                } else {
                    jobs.append(JobRecord(name: name, started: date, finished: date, result: result))
                }
            } else if line.contains("Listening for Jobs") {
                events.append(RunnerEvent(date: date, kind: .connected, message: "GitHub に接続しました"))
            } else if let range = line.range(of: "Runner connect error: ") {
                var message = String(line[range.upperBound...])
                if let end = message.range(of: ". Retrying until reconnected.") { message = String(message[..<end.lowerBound]) }
                events.append(RunnerEvent(date: date, kind: .connectError, message: message))
            } else if line.contains("Runner reconnected.") {
                events.append(RunnerEvent(date: date, kind: .reconnected, message: "GitHub に再接続しました"))
            }
        }
        return (jobs, events)
    }

    /// Step progress from a Worker_*.log.
    static func parseWorkerProgress(_ text: String) -> JobProgress {
        var progress = JobProgress()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let range = line.range(of: "Total job steps: ") {
                progress.totalSteps = Int(line[range.upperBound...].prefix(while: \.isNumber))
            } else if let range = line.range(of: "Processing step: DisplayName='") {
                let rest = line[range.upperBound...]
                progress.currentStep = String(rest[..<(rest.lastIndex(of: "'") ?? rest.endIndex)])
            } else if line.contains("StepsRunner] Step result:") {
                progress.completedSteps += 1
            }
        }
        return progress
    }

    /// Sleep and wake entries from `pmset -g log`, oldest first. Maintenance dark wakes are left out.
    static func parseSleepLog(_ text: String, since: Date) -> [RunnerEvent] {
        var events: [RunnerEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 26, let date = date(from: line), date >= since,
                  let tab = line.firstIndex(of: "\t") else { continue }
            let kind = line[line.index(line.startIndex, offsetBy: 26)..<tab].trimmingCharacters(in: .whitespaces)
            var message = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            if let end = message.range(of: " Using ") { message = String(message[..<end.lowerBound]) }
            if let range = message.range(of: "due to ") { message = String(message[range.upperBound...]) }
            if message.hasPrefix("'"), let close = message.dropFirst().firstIndex(of: "'") {
                message = String(message[message.index(after: message.startIndex)..<close])
            }
            switch kind {
            case "Sleep": events.append(RunnerEvent(date: date, kind: .sleep, message: "スリープ: " + message))
            case "Wake": events.append(RunnerEvent(date: date, kind: .wake, message: "スリープ解除: " + message))
            default: continue
            }
        }
        return events
    }

    /// Lifecycle lines only, with local times, for a readable log view.
    static func essentials(_ text: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm:ss"
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let date = lineDate(line) else { continue }
            var message: String
            if let range = line.range(of: "] WRITE LINE: ") ?? line.range(of: "] WRITE ERROR: ") {
                message = String(line[range.upperBound...])
                if message.count > 22, message.dropFirst(19).hasPrefix("Z: "), self.date(from: Substring(message)) != nil {
                    message = String(message.dropFirst(22))
                }
            } else if let range = line.range(of: "Processing step: DisplayName='") {
                let rest = line[range.upperBound...]
                message = "ステップ: " + rest[..<(rest.lastIndex(of: "'") ?? rest.endIndex)]
            } else if let range = line.range(of: "Total job steps: ") {
                message = "ステップ数: " + line[range.upperBound...].prefix(while: \.isNumber)
            } else if let range = line.range(of: "Update job result with current step result ") {
                message = "ジョブ結果: " + line[range.upperBound...].replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .punctuationCharacters)
            } else if line.contains("Listening for Jobs") {
                message = "Listening for Jobs"
            } else {
                continue
            }
            lines.append(formatter.string(from: date) + "  " + message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n")
    }

    static func lastLines(_ text: String, count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Reads the diagnostic logs under `root/_diag`. `busy` says whether the listener currently reports a running job,
    /// which decides if an unfinished job in the newest log is live or was cut off.
    static func collect(root: URL, busy: Bool, sleepLog: String?, now: Date = Date(), logFiles: Int = 5) -> RunnerActivity {
        var activity = RunnerActivity()
        let diag = root.appendingPathComponent("_diag")
        let files = ((try? FileManager.default.contentsOfDirectory(at: diag, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
        let runnerLogs = files.filter { $0.lastPathComponent.hasPrefix("Runner_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(logFiles)
        var jobs: [JobRecord] = []
        var events: [RunnerEvent] = []
        for (index, url) in runnerLogs.enumerated() {
            guard let text = try? LocalRunner.tail(url, bytes: 4 * 1_048_576) else { continue }
            if let started = LogStatus.date(of: url.lastPathComponent) {
                events.append(RunnerEvent(date: started, kind: .listenerStarted, message: "ランナーを起動しました"))
            }
            let parsed = parseRunnerLog(text)
            var fileJobs = parsed.jobs
            let isNewest = index == runnerLogs.count - 1
            for jobIndex in fileJobs.indices where fileJobs[jobIndex].isRunning {
                if !(isNewest && busy && jobIndex == fileJobs.indices.last) { fileJobs[jobIndex].result = "中断" }
            }
            jobs += fileJobs
            events += parsed.events
            if isNewest {
                activity.runnerLogPath = url.path
                activity.runnerLogTail = lastLines(text, count: 400)
                activity.runnerLogEssentials = lastLines(essentials(text), count: 200)
            }
        }
        if let sleepLog {
            events += parseSleepLog(sleepLog, since: now.addingTimeInterval(-14 * 86_400))
        }
        activity.jobs = jobs.sorted { $0.started > $1.started }
        activity.events = Array(events.sorted { $0.date > $1.date }.prefix(200))
        if let current = activity.currentJob,
           let worker = files.filter({ $0.lastPathComponent.hasPrefix("Worker_") })
               .compactMap({ url -> (URL, Date)? in
                   guard let date = LogStatus.date(of: "Runner_" + url.lastPathComponent.dropFirst(7)) else { return nil }
                   return (url, date)
               })
               .filter({ $0.1 >= current.started.addingTimeInterval(-60) })
               .max(by: { $0.1 < $1.1 }),
           let text = try? LocalRunner.tail(worker.0, bytes: 4 * 1_048_576) {
            activity.workerLogPath = worker.0.path
            activity.workerLogTail = lastLines(text, count: 400)
            activity.workerLogEssentials = lastLines(essentials(text), count: 200)
            activity.progress = parseWorkerProgress(text)
        }
        return activity
    }
}
