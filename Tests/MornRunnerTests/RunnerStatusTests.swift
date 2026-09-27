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

    @Test func testOldLogsCannotMakeNewProcessLookReady() throws {
        let started = try #require(LogStatus.date(of: "Runner_20260927-095054-utc.log"))
        #expect(LogStatus.belongsToCurrentListener(filename: "Runner_20260927-095054-utc.log", started: started))
        #expect(!LogStatus.belongsToCurrentListener(filename: "Runner_20260915-012702-utc.log", started: started))
        #expect(!LogStatus.belongsToCurrentListener(filename: "Worker_20260927-095054-utc.log", started: started))
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
