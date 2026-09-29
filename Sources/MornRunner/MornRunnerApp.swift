import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class RunnerMonitor: ObservableObject {
    @Published var snapshot = RunnerSnapshot()
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
        let selectedRoot = root
        let value = await Task.detached(priority: .utility) { LocalRunner.snapshot(root: selectedRoot) }.value
        if root == selectedRoot { snapshot = value }
        loginEnabled = SMAppService.mainApp.status == .enabled
        refreshing = false
    }

    func control(start: Bool) {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        let selectedRoot = root
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
        snapshot = RunnerSnapshot()
        Task { await refresh() }
    }

    func repairService() {
        guard !isWorking, !isInstalling else { return }
        isWorking = true
        let selectedRoot = root
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

    func openGitHub() {
        guard let url = URL(string: snapshot.githubURL), url.scheme == "https", url.host == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }

    func openLogs() {
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
            Label("Runner · \(monitor.snapshot.state.title)", systemImage: monitor.snapshot.state.symbol)
                .accessibilityLabel("MornRunner: \(monitor.snapshot.state.title)")
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
    @State private var confirmStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MornRunner", systemImage: "desktopcomputer").font(.headline)
                Spacer()
                Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("状態を更新")
            }
            if !monitor.profiles.isEmpty {
                Picker("ランナー", selection: Binding(get: { monitor.root.path }, set: { monitor.selectRunner(URL(fileURLWithPath: $0)) })) {
                    ForEach(monitor.profiles) { profile in Text(profile.name).tag(profile.root.path) }
                }.disabled(monitor.isWorking || monitor.isInstalling)
            }
            HStack(spacing: 12) {
                Image(systemName: monitor.snapshot.state.symbol)
                    .font(.system(size: 32)).foregroundStyle(monitor.snapshot.state.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.snapshot.state.title).font(.title2.bold())
                }
                Spacer()
            }
            if [.busy, .offline, .unknown].contains(monitor.snapshot.state) {
                Text(monitor.snapshot.detail).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !monitor.snapshot.githubURL.isEmpty {
                Text(monitor.snapshot.githubURL.replacingOccurrences(of: "https://github.com/", with: ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("起動", systemImage: "play.fill") { monitor.control(start: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(monitor.isWorking || monitor.isInstalling || monitor.snapshot.listenerRunning || monitor.snapshot.state == .unknown || monitor.snapshot.state == .notConfigured)
                Button("停止", systemImage: "stop.fill") { confirmStop = true }
                    .disabled(monitor.isWorking || monitor.isInstalling || !monitor.snapshot.serviceLoaded)
                if monitor.isWorking { ProgressView().controlSize(.small) }
                Spacer()
            }
            .alert("ランナーを停止しますか？", isPresented: $confirmStop) {
                Button("キャンセル", role: .cancel) {}
                Button("停止", role: .destructive) { monitor.control(start: false) }
            } message: {
                Text("実行中のジョブは中断されます。")
            }
            if let error = monitor.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if monitor.snapshot.state == .unknown && !FileManager.default.fileExists(atPath: monitor.root.appendingPathComponent(".service").path) {
                Button("サービスを設定して起動") { monitor.repairService() }
                    .disabled(monitor.isWorking || monitor.isInstalling)
            }
            Divider()
            HStack {
                Button("新規設定", systemImage: "plus") {
                    openWindow(id: "setup")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("既存を追加…") { monitor.selectFolder() }.disabled(monitor.isWorking || monitor.isInstalling)
            }
            HStack {
                Button("アクティビティ", systemImage: "list.bullet.rectangle") {
                    openWindow(id: "activity")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("ログ", systemImage: "doc.text") { monitor.openLogs() }
                Button("GitHub", systemImage: "arrow.up.right.square") { monitor.openGitHub() }
                    .disabled(monitor.snapshot.githubURL.isEmpty)
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
        .padding(20).frame(width: 370)
    }
}
