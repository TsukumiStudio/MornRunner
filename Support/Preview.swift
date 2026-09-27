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
        try render(SetupView(model: setup, monitor: monitor, updater: updater), size: NSSize(width: 620, height: 790), to: destination.appendingPathComponent("setup.png"))
        try render(Dashboard(monitor: monitor, updater: updater), size: NSSize(width: 370, height: 760), to: destination.appendingPathComponent("dashboard.png"))
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
