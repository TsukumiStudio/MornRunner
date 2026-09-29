import Foundation
import Testing
@testable import MornRunner

struct ActivityTests {
    let runnerLog = """
    [2026-09-29 14:55:28Z ERR  Terminal] WRITE ERROR: 2026-09-29 14:55:28Z: Runner connect error: The HTTP request timed out after 00:01:40.. Retrying until reconnected.
       at System.Net.Http.HttpConnection.SendAsync(HttpRequestMessage request)
    [2026-09-29 15:09:44Z INFO Terminal] WRITE LINE: 2026-09-29 15:09:44Z: Running job: web
    [2026-09-29 15:10:37Z INFO Terminal] WRITE LINE: 2026-09-29 15:10:37Z: Job web completed with result: Succeeded
    [2026-09-29 16:15:01Z INFO Terminal] WRITE LINE: 2026-09-29 16:15:01Z: Running job: Build mac app

    """

    @Test func parsesJobsAndConnectionEvents() throws {
        let parsed = ActivityLog.parseRunnerLog(runnerLog)
        #expect(parsed.jobs.map(\.name) == ["web", "Build mac app"])
        #expect(parsed.jobs[0].result == "Succeeded")
        #expect(parsed.jobs[0].duration == 53)
        #expect(parsed.jobs[1].isRunning)
        #expect(parsed.events.map(\.kind) == [.connectError])
        #expect(parsed.events[0].message == "The HTTP request timed out after 00:01:40.")
        #expect(parsed.events[0].date == ISO8601DateFormatter().date(from: "2026-09-29T14:55:28Z"))
    }

    @Test func parsesWorkerProgress() {
        let log = """
        [2026-09-28 13:01:55Z INFO JobRunner] Total job steps: 24.
        [2026-09-28 13:01:55Z INFO StepsRunner] Processing step: DisplayName='Checkout'
        [2026-09-28 13:02:01Z INFO StepsRunner] Step result: 
        [2026-09-28 13:02:01Z INFO StepsRunner] Processing step: DisplayName='Install Godot'
        """
        let progress = ActivityLog.parseWorkerProgress(log)
        #expect(progress.totalSteps == 24)
        #expect(progress.completedSteps == 1)
        #expect(progress.currentStep == "Install Godot")
    }

    @Test func parsesSleepLogInLocalOffsetsAndSkipsWakeRequests() throws {
        let log = """
        2026-09-29 20:08:30 +0900 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:97%) 3615 secs 
        2026-09-29 23:11:31 +0900 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7198]
        2026-09-29 23:55:28 +0900 Wake                \tWake from Deep Idle [CDNVA] : due to smc.70070000 lid SMC.OutboxNotEmpty/HID Activity Using BATT (Charge:97%)
        """
        let since = try #require(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        let events = ActivityLog.parseSleepLog(log, since: since)
        #expect(events.map(\.kind) == [.sleep, .wake])
        #expect(events[1].date == ISO8601DateFormatter().date(from: "2026-09-29T14:55:28Z"))
        #expect(events[0].message == "スリープ: Maintenance Sleep")
        #expect(events[1].message.hasPrefix("スリープ解除: smc.70070000 lid"))
        #expect(ActivityLog.parseSleepLog(log, since: since.addingTimeInterval(60 * 86_400)).isEmpty)
    }

    @Test func essentialsKeepLifecycleLinesOnly() {
        let text = ActivityLog.essentials(runnerLog + "[2026-09-29 16:15:02Z INFO StepsRunner] Processing step: DisplayName='Checkout'\n")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 5)
        #expect(lines[0].hasSuffix("Runner connect error: The HTTP request timed out after 00:01:40.. Retrying until reconnected."))
        #expect(lines[1].hasSuffix("  Running job: web"))
        #expect(lines[4].hasSuffix("  ステップ: Checkout"))
        #expect(!text.contains("HttpConnection"))
    }

    @Test func collectsFromDiagnosticFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MornRunner activity \(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let diag = root.appendingPathComponent("_diag")
        try fm.createDirectory(at: diag, withIntermediateDirectories: true)
        let older = "[2026-09-27 10:00:00Z INFO Terminal] WRITE LINE: 2026-09-27 10:00:00Z: Running job: cut off\n"
        try older.write(to: diag.appendingPathComponent("Runner_20260927-095054-utc.log"), atomically: true, encoding: .utf8)
        try runnerLog.write(to: diag.appendingPathComponent("Runner_20260929-140000-utc.log"), atomically: true, encoding: .utf8)
        let worker = "[2026-09-29 16:15:02Z INFO JobRunner] Total job steps: 3.\n[2026-09-29 16:15:02Z INFO StepsRunner] Processing step: DisplayName='Checkout'\n"
        try worker.write(to: diag.appendingPathComponent("Worker_20260929-161502-utc.log"), atomically: true, encoding: .utf8)

        let busy = ActivityLog.collect(root: root, busy: true, sleepLog: nil)
        #expect(busy.currentJob?.name == "Build mac app")
        #expect(busy.progress?.totalSteps == 3)
        #expect(busy.progress?.currentStep == "Checkout")
        #expect(busy.workerLogPath?.hasSuffix("Worker_20260929-161502-utc.log") == true)
        #expect(busy.jobs.map(\.name) == ["Build mac app", "web", "cut off"])
        #expect(busy.jobs[2].result == "中断")
        #expect(busy.events.map(\.kind) == [.connectError, .listenerStarted, .listenerStarted])
        #expect(busy.runnerLogPath?.hasSuffix("Runner_20260929-140000-utc.log") == true)
        #expect(busy.runnerLogEssentials.components(separatedBy: "\n").count == 4)
        #expect(busy.workerLogEssentials.hasSuffix("ステップ: Checkout"))

        let idle = ActivityLog.collect(root: root, busy: false, sleepLog: nil)
        #expect(idle.currentJob == nil)
        #expect(idle.jobs[0].result == "中断")
        #expect(idle.workerLogPath == nil)
    }
}
