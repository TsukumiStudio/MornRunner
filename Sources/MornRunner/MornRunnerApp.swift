import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class RunnerMonitor: ObservableObject {
    @Published var snapshot = RunnerSnapshot()
    /// Every discovered runner's latest state, keyed by `RunnerProfile.id`.
    @Published var snapshots: [String: RunnerSnapshot] = [:]
    /// Runners the user unchecked for the menu bar. Stored as hidden so newly added runners appear by default.
    @Published var hiddenInMenuBar = Set(UserDefaults.standard.stringArray(forKey: "menuBarHiddenRunners") ?? [])
    @Published var root: URL
    @Published var isWorking = false
    @Published var isInstalling = false
    @Published var profiles: [RunnerProfile] = []
    @Published var error: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private var refreshing = false
    private var timer: Timer?

    init() {
        let path = UserDefaults.standard.string(forKey: "runnerPath")
        root = path.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("actions-runner")
        reloadProfiles()
        if !profiles.contains(where: { $0.root == root }), let first = profiles.first { root = first.root }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        reloadProfiles()
        let roots = profiles.map(\.root) + (profiles.contains { $0.root.path == root.path } ? [] : [root])
        // ponytail: sequential ps/launchctl per runner; share one ps call if many runners make this slow.
        let values = await Task.detached(priority: .utility) { roots.map { ($0.path, LocalRunner.snapshot(root: $0)) } }.value
        snapshots = Dictionary(values) { _, new in new }
        snapshot = snapshots[root.path] ?? RunnerSnapshot()
        loginEnabled = SMAppService.mainApp.status == .enabled
        refreshing = false
    }

    func control(start: Bool, root target: URL? = nil) {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        let selectedRoot = target ?? root
        Task {
            do {
                try await Task.detached { try LocalRunner.control(root: selectedRoot, start: start) }.value
            } catch { self.error = error.localizedDescription }
            await refresh()
            isWorking = false
        }
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "actions-runner フォルダを選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".runner").path) else {
            error = ".runner を含む、登録済みのランナーフォルダを選択してください"
            return
        }
        addRunner(url)
    }

    func reloadProfiles() {
        let saved = UserDefaults.standard.stringArray(forKey: "runnerPaths") ?? []
        profiles = RunnerProfile.discover(savedPaths: saved + [root.path])
    }

    func addRunner(_ url: URL) {
        var saved = UserDefaults.standard.stringArray(forKey: "runnerPaths") ?? []
        if !saved.contains(url.path) { saved.append(url.path) }
        UserDefaults.standard.set(saved, forKey: "runnerPaths")
        selectRunner(url)
        reloadProfiles()
    }

    func selectRunner(_ url: URL) {
        root = url.standardizedFileURL
        UserDefaults.standard.set(root.path, forKey: "runnerPath")
        snapshot = snapshots[root.path] ?? RunnerSnapshot()
        Task { await refresh() }
    }

    func setShownInMenuBar(_ shown: Bool, id: String) {
        if shown { hiddenInMenuBar.remove(id) } else { hiddenInMenuBar.insert(id) }
        UserDefaults.standard.set(Array(hiddenInMenuBar), forKey: "menuBarHiddenRunners")
    }

    func repairService(root target: URL) {
        guard !isWorking, !isInstalling else { return }
        isWorking = true
        let selectedRoot = target
        Task {
            do {
                try await Task.detached {
                    try RunnerInstaller.installService(root: selectedRoot)
                    try LocalRunner.control(root: selectedRoot, start: true)
                }.value
                error = nil
            } catch { self.error = error.localizedDescription }
            await refresh()
            isWorking = false
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { self.error = error.localizedDescription }
    }

    func openGitHub(_ snapshot: RunnerSnapshot) {
        guard let url = URL(string: snapshot.githubURL), url.scheme == "https", url.host == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }

    func openLogs(_ snapshot: RunnerSnapshot, root: URL) {
        if let path = snapshot.logPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else { NSWorkspace.shared.open(root.appendingPathComponent("_diag")) }
    }
}

extension RunnerState {
    var color: Color {
        switch self {
        case .idle: return .green
        case .busy: return .blue
        case .connecting: return .orange
        case .offline: return .red
        case .notConfigured, .unknown, .stopped: return .secondary
        }
    }
}

#if !PREVIEW
@main
@MainActor
struct MornRunnerApp: App {
    @StateObject private var monitor = RunnerMonitor()
    @StateObject private var setup = SetupModel()
    @StateObject private var updater = Updater()
    @StateObject private var activity = ActivityModel()

    init() {
        // A read-only diagnostic mode uses the same implementation as the menu bar.
        if CommandLine.arguments.contains("--status") {
            let arguments = CommandLine.arguments
            let root: URL
            if let index = arguments.firstIndex(of: "--runner-path"), arguments.indices.contains(index + 1) {
                root = URL(fileURLWithPath: arguments[index + 1])
            } else {
                root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("actions-runner")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let snapshot = LocalRunner.snapshot(root: root)
            if let data = try? encoder.encode(snapshot) { print(String(decoding: data, as: UTF8.self)) }
            exit(snapshot.state == .unknown ? 1 : 0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Dashboard(monitor: monitor, updater: updater)
        } label: {
            let shown = monitor.profiles.filter { !monitor.hiddenInMenuBar.contains($0.id) }
            let states = shown.map { monitor.snapshots[$0.id]?.state ?? .unknown }
            Group {
                if states.isEmpty { Image(systemName: "desktopcomputer") }
                else { Image(nsImage: MenuBarIcons.render(states)) }
            }
            .accessibilityLabel("MornRunner: " + zip(shown, states).map { "\($0.name) \($1.title)" }.joined(separator: "、"))
        }
        .menuBarExtraStyle(.window)
        Window("MornRunner — セットアップ", id: "setup") {
            SetupView(model: setup, monitor: monitor, updater: updater)
        }
        .defaultSize(width: 560, height: 580)
        Window("MornRunner — アクティビティ", id: "activity") {
            ActivityView(monitor: monitor, model: activity)
        }
        .defaultSize(width: 880, height: 700)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("MornRunner を終了") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .disabled(monitor.isInstalling || updater.isWorking)
            }
        }
    }
}

#endif

struct Dashboard: View {
    @ObservedObject var monitor: RunnerMonitor
    @ObservedObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MornRunner", systemImage: "desktopcomputer").font(.headline)
                Spacer()
                Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("状態を更新")
            }
            if monitor.profiles.isEmpty {
                Text(monitor.snapshot.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(monitor.profiles) { profile in
                RunnerRow(monitor: monitor, profile: profile, snapshot: monitor.snapshots[profile.id] ?? RunnerSnapshot()) {
                    confirmStop(profile)
                }
            }
            if let error = monitor.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("新規設定", systemImage: "plus") {
                    openWindow(id: "setup")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("既存を追加…") { monitor.selectFolder() }.disabled(monitor.isWorking || monitor.isInstalling)
            }
            Toggle("ログイン時に起動", isOn: Binding(get: { monitor.loginEnabled }, set: { monitor.setLogin($0) }))
                .toggleStyle(.switch).controlSize(.small)
            Divider()
            UpdateControls(updater: updater).disabled(monitor.isWorking || monitor.isInstalling)
            HStack {
                Text("v\(Updater.version)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("アプリを終了") { NSApp.terminate(nil) }.disabled(monitor.isInstalling || updater.isWorking)
            }
        }
        .padding(20).frame(width: 420)
    }

    /// A sheet inside the menu bar popover cannot take key focus in an accessory app, so its buttons never respond.
    /// Present a standalone modal alert instead.
    func confirmStop(_ profile: RunnerProfile) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(profile.name) を停止しますか？"
        alert.informativeText = "実行中のジョブは中断されます。"
        alert.alertStyle = .warning
        let stop = alert.addButton(withTitle: "停止")
        stop.hasDestructiveAction = true
        stop.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn { monitor.control(start: false, root: profile.root) }
    }
}

struct RunnerRow: View {
    @ObservedObject var monitor: RunnerMonitor
    let profile: RunnerProfile
    let snapshot: RunnerSnapshot
    let confirmStop: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let busy = monitor.isWorking || monitor.isInstalling
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: snapshot.state.symbol)
                .font(.title2).foregroundStyle(snapshot.state.color).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(snapshot.state.title).font(.caption.bold()).foregroundStyle(snapshot.state.color)
                }
                if !snapshot.githubURL.isEmpty {
                    Text(snapshot.githubURL.replacingOccurrences(of: "https://github.com/", with: ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if [.busy, .offline, .unknown].contains(snapshot.state) {
                    Text(snapshot.detail).font(.caption).lineLimit(2).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Button { monitor.control(start: true, root: profile.root) } label: { Image(systemName: "play.fill") }
                        .help("起動")
                        .disabled(busy || snapshot.listenerRunning || snapshot.state == .unknown || snapshot.state == .notConfigured)
                    Button(action: confirmStop) { Image(systemName: "stop.fill") }
                        .help("停止")
                        .disabled(busy || !snapshot.serviceLoaded)
                    Button {
                        monitor.selectRunner(profile.root)
                        openWindow(id: "activity")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: { Image(systemName: "list.bullet.rectangle") }.help("アクティビティ")
                    Button { monitor.openLogs(snapshot, root: profile.root) } label: { Image(systemName: "doc.text") }.help("ログ")
                    Button { monitor.openGitHub(snapshot) } label: { Image(systemName: "arrow.up.right.square") }
                        .help("GitHub").disabled(snapshot.githubURL.isEmpty)
                    Spacer()
                    Toggle("メニューバー", isOn: Binding(
                        get: { !monitor.hiddenInMenuBar.contains(profile.id) },
                        set: { monitor.setShownInMenuBar($0, id: profile.id) }
                    )).toggleStyle(.checkbox).font(.caption)
                }
                .controlSize(.small)
                if snapshot.state == .unknown && !FileManager.default.fileExists(atPath: profile.root.appendingPathComponent(".service").path) {
                    Button("サービスを設定して起動") { monitor.repairService(root: profile.root) }
                        .controlSize(.small).disabled(busy)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
    }
}

/// The menu bar label is a single image, so the checked runners' colored state icons are drawn side by side into one.
enum MenuBarIcons {
    @MainActor static func render(_ states: [RunnerState]) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let content = HStack(spacing: 3) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Image(systemName: state.symbol).foregroundStyle(state.color)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage()
    }
}
