import Foundation
import Testing
@testable import MornRunner

struct RunnerStatusTests {
    @Test func testLifecycleAndFailedJobRemainAvailable() {
        let ready = "[INFO Terminal] Listening for Jobs\n"
        #expect(LogStatus.parse(ready).0 == .idle)
        let busy = ready + "[INFO Terminal] Running job: Build mac app\n"
        #expect(LogStatus.parse(busy).0 == .busy)
        #expect(LogStatus.parse(busy).1 == "Build mac app")
        #expect(LogStatus.parse(busy + "Job Build mac app completed with result: Failed").0 == .idle)
    }

    @Test func testConnectionFailureAndRecovery() {
        let failed = "Listening for Jobs\n[ERR BrokerMessageListener] Connection failed\n"
        #expect(LogStatus.parse(failed).0 == .offline)
        #expect(LogStatus.parse(failed + "Runner reconnected.").0 == .idle)
        #expect(LogStatus.parse("Runner connect error: timeout").0 == .offline)
        #expect(LogStatus.parse("").0 == .connecting)
    }

    // The runner does not log "Runner reconnected." when polling recovers, e.g. after the Mac wakes from sleep.
    @Test func testQuietPeriodAfterConnectErrorCountsAsRecovery() throws {
        let log = """
        [2026-09-29 14:55:28Z ERR  Terminal] WRITE ERROR: 2026-09-29 14:55:28Z: Runner connect error: The HTTP request timed out after 00:01:40.. Retrying until reconnected.
        [2026-09-29 15:00:34Z ERR  BrokerServer] Catch exception during request
        [2026-09-29 15:00:34Z WARN BrokerServer] Back off 10.068 seconds before next retry. 4 attempt left.

        """
        let lastError = try #require(ISO8601DateFormatter().date(from: "2026-09-29T15:00:34Z"))
        #expect(LogStatus.parse(log, now: lastError.addingTimeInterval(60)).0 == .offline)
        #expect(LogStatus.parse(log, now: lastError.addingTimeInterval(LogStatus.recoveryGrace + 1)).0 == .idle)
        #expect(LogStatus.parse(log, now: lastError.addingTimeInterval(LogStatus.recoveryGrace + 1)).1 == "接続エラーから復帰しました")
        let stillFailing = log + "[2026-09-29 15:04:00Z ERR  BrokerMessageListener] Catch exception during get next message\n"
        #expect(LogStatus.parse(stillFailing, now: lastError.addingTimeInterval(LogStatus.recoveryGrace + 1)).0 == .offline)
    }

    @Test func testOldLogsCannotMakeNewProcessLookReady() throws {
        let started = try #require(LogStatus.date(of: "Runner_20260927-095054-utc.log"))
        #expect(LogStatus.belongsToCurrentListener(filename: "Runner_20260927-095054-utc.log", started: started))
        #expect(!LogStatus.belongsToCurrentListener(filename: "Runner_20260915-012702-utc.log", started: started))
        #expect(!LogStatus.belongsToCurrentListener(filename: "Worker_20260927-095054-utc.log", started: started))
    }

    @Test func testLaterVersionCheckLogDoesNotHideListenerLog() throws {
        let started = try #require(LogStatus.date(of: "Runner_20261103-075930-utc.log"))
        let names = ["Runner_20261031-123917-utc.log", "Runner_20261103-075930-utc.log", "Runner_20261106-101446-utc.log", "Worker_20261108-003326-utc.log"]
        #expect(LogStatus.currentListenerLog(filenames: names, started: started) == "Runner_20261103-075930-utc.log")
        #expect(LogStatus.currentListenerLog(filenames: ["Runner_20261031-123917-utc.log"], started: started) == nil)
    }

    @Test func testVersionInvocationIsNotRunLog() {
        #expect(LogStatus.isRunLog("[2026-11-03 07:59:31Z INFO CommandSettings] Command 'run': 'True'\n"))
        #expect(!LogStatus.isRunLog("[2026-11-06 10:14:46Z INFO CommandSettings] Flag 'version': 'True'\n"))
    }

    @Test func testMissingConfigurationShowsSetup() {
        let snapshot = LocalRunner.snapshot(root: URL(fileURLWithPath: "/nonexistent-mornrunner-test"))
        #expect(snapshot.state == .notConfigured)
        #expect(!snapshot.listenerRunning)
    }

    @Test func testBoundedTailRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("old\nListening for Jobs".utf8).write(to: file)
        #expect(try LocalRunner.tail(file, bytes: 18) == "Listening for Jobs")
    }

    @Test func testIncrementalLogScan() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        try Data("Listening for Jobs\n".utf8).write(to: file)
        #expect(try LogCache.scan(file).state == .idle)
        try append("Running job: Build\nJob Build completed")
        #expect(try LogCache.scan(file).detail == "Build")
        try append(" with result: Failed\n")
        #expect(try LogCache.scan(file).detail == "前回のジョブ: Failed")
        // A replaced, shorter file is scanned from scratch.
        try Data("Runner connect error: x\n".utf8).write(to: file)
        #expect(try LogCache.scan(file).state == .offline)
    }

    // Explicitly enabled on a logged-in Mac. Uses its own disposable service, never the real runner.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MORN_RUN_SERVICE_TEST"] == "1"))
    func testServiceStartStop() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MornRunner smoke \(UUID().uuidString)")
        let label = "actions.runner.MornRunnerSmoke.\(UUID().uuidString)"
        let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            _ = try? LocalRunner.command("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try? fm.removeItem(at: plist)
            try? fm.removeItem(at: root)
        }
        let configuration: [String: Any] = [
            "Label": label, "ProgramArguments": ["/bin/sleep", "60"],
            "WorkingDirectory": root.path, "RunAtLoad": true
        ]
        try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0).write(to: plist)
        try plist.path.write(to: root.appendingPathComponent(".service"), atomically: true, encoding: .utf8)
        let config = "\u{FEFF}{\"agentName\":\"Smoke test\",\"gitHubUrl\":\"https://github.com/TsukumiStudio\"}"
        try config.write(to: root.appendingPathComponent(".runner"), atomically: true, encoding: .utf8)
        #expect(LocalRunner.snapshot(root: root).state == .stopped)
        try LocalRunner.control(root: root, start: true)
        #expect(LocalRunner.snapshot(root: root).serviceLoaded)
        try LocalRunner.control(root: root, start: false)
        #expect(!LocalRunner.snapshot(root: root).serviceLoaded)
        #expect(LocalRunner.snapshot(root: root).state == .stopped)
    }
}

struct StuckWatchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let labels = ["self-hosted", "macOS", "ARM64", "kimekyawa-mac-mini"]

    @Test func testLongQueuedMatchingJobOnIdleRunnerIsStuck() {
        let job = StuckWatch.QueuedJob(labels: ["self-hosted", "Kimekyawa-Mac-Mini"], createdAt: now.addingTimeInterval(-StuckWatch.queuedLimit))
        #expect(StuckWatch.isStuck(runnerLabels: labels, busyOnGitHub: false, jobs: [job], now: now))
        #expect(!StuckWatch.isStuck(runnerLabels: labels, busyOnGitHub: true, jobs: [job], now: now))
    }

    @Test func testFreshOrForeignJobsAreNotStuck() {
        let fresh = StuckWatch.QueuedJob(labels: ["self-hosted"], createdAt: now.addingTimeInterval(-60))
        let otherRunner = StuckWatch.QueuedJob(labels: ["self-hosted", "kimekyawa-book-air"], createdAt: now.addingTimeInterval(-3600))
        let hosted = StuckWatch.QueuedJob(labels: ["ubuntu-latest"], createdAt: now.addingTimeInterval(-3600))
        let unlabeled = StuckWatch.QueuedJob(labels: [], createdAt: now.addingTimeInterval(-3600))
        #expect(!StuckWatch.isStuck(runnerLabels: labels, busyOnGitHub: false, jobs: [fresh, otherRunner, hosted, unlabeled], now: now))
    }

    @Test func testOnlyRepositoryRunnersAreWatched() {
        #expect(StuckWatch.repository(of: "https://github.com/TsukumiStudio/KimekyawaGodot") == "TsukumiStudio/KimekyawaGodot")
        #expect(StuckWatch.repository(of: "https://github.com/TsukumiStudio") == nil)
    }
}
