// Development-only view rendering: compile with -D PREVIEW alongside Sources/MornRunner/*.swift.
import AppKit
import SwiftUI

@main
struct Preview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        app.finishLaunching()
        let monitor = RunnerMonitor()
        monitor.snapshot = LocalRunner.snapshot(root: monitor.root)
        let setup = SetupModel()
        setup.target = "example/my-project"
        setup.name = "build-mac"
        let updater = Updater()
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try render(SetupView(model: setup, monitor: monitor, updater: updater), size: NSSize(width: 560, height: 580), to: destination.appendingPathComponent("setup.png"))
        try render(Dashboard(monitor: monitor, updater: updater), size: NSSize(width: 370, height: 500), to: destination.appendingPathComponent("dashboard.png"))
        let activity = ActivityModel()
        let sleep = try? LocalRunner.command("/usr/bin/pmset", ["-g", "log"]).output
        activity.activity = ActivityLog.collect(root: monitor.root, busy: monitor.snapshot.state == .busy, sleepLog: sleep)
        activity.loaded = true
        try render(ActivityView(monitor: monitor, model: activity), size: NSSize(width: 880, height: 700), to: destination.appendingPathComponent("activity.png"))
        var busy = activity.activity
        busy.jobs.insert(JobRecord(name: "Run tests and build distributions", started: Date().addingTimeInterval(-154)), at: 0)
        busy.progress = JobProgress(totalSteps: 24, completedSteps: 7, currentStep: "Import assets")
        var snapshot = monitor.snapshot
        snapshot.state = .busy
        snapshot.detail = "Run tests and build distributions"
        try render(ActivityHeader(snapshot: snapshot, activity: busy).padding(20), size: NSSize(width: 880, height: 190), to: destination.appendingPathComponent("activity-busy.png"))
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
