import AppKit
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    @Published var target = ""
    @Published var name = "my-mac"
    @Published var labels = ""
    @Published var token = ""
    @Published var parent = RunnerInstaller.baseDirectory
    @Published var isWorking = false
    @Published var fetchingToken = false
    @Published var progress = ""
    @Published var error: String?
    @Published var outcome: SetupOutcome?

    var request: SetupRequest? {
        try? SetupRequest(target: target, name: name, labels: labels, root: parent.appendingPathComponent(name))
    }
    var targetURL: GitHubTarget? { try? GitHubTarget(target) }
    var workflow: String {
        let architecture = RunnerInstaller.architecture == "arm64" ? "ARM64" : "X64"
        let extra = (request?.labels ?? "").split(separator: ",").map(String.init)
        return "runs-on: [" + (["self-hosted", "macOS", architecture] + extra).joined(separator: ", ") + "]"
    }

    func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "ランナーの保存先フォルダを選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    func fetchToken() {
        guard !fetchingToken, !isWorking, let targetURL else { return }
        fetchingToken = true
        error = nil
        Task {
            do { token = try await Task.detached { try RunnerInstaller.registrationToken(for: targetURL) }.value }
            catch { self.error = error.localizedDescription }
            fetchingToken = false
        }
    }

    func install(monitor: RunnerMonitor) {
        guard !isWorking, !fetchingToken else { return }
        do {
            let request = try SetupRequest(target: target, name: name, labels: labels, root: parent.appendingPathComponent(name))
            _ = try RunnerInstaller.validateDestination(request)
            let registrationToken = token
            token = ""
            isWorking = true
            monitor.isInstalling = true
            error = nil
            outcome = nil
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await RunnerInstaller.install(request, token: registrationToken) { message in
                            await MainActor.run { self.progress = message }
                        }
                    }.value
                    outcome = result
                    monitor.addRunner(result.root)
                } catch {
                    self.error = error.localizedDescription
                    // Registration may have succeeded before service setup failed.
                    if FileManager.default.fileExists(atPath: request.root.appendingPathComponent(".runner").path) {
                        monitor.addRunner(request.root)
                    }
                }
                isWorking = false
                monitor.isInstalling = false
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var monitor: RunnerMonitor
    @ObservedObject var updater: Updater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("ランナーを追加", systemImage: "desktopcomputer").font(.title2.bold())
                if let result = model.outcome {
                    completion(result)
                } else {
                    setupFields
                }
            }
            .padding(28)
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 500, idealHeight: 580)
        .disabled(updater.isWorking || updater.state == .updated)
    }

    private var setupFields: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("登録先").font(.headline)
                    TextField("owner または owner/repository", text: $model.target)
                        .textFieldStyle(.roundedBorder)
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ランナー").font(.headline)
                    LabeledContent("名前") { TextField("my-mac", text: $model.name).textFieldStyle(.roundedBorder) }
                    DisclosureGroup("詳細") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("ラベル") { TextField("任意", text: $model.labels).textFieldStyle(.roundedBorder) }
                            HStack {
                                Text(model.parent.appendingPathComponent(model.name).path).font(.caption).textSelection(.enabled)
                                Spacer()
                                Button("保存先…") { model.chooseParent() }
                            }
                        }.padding(.top, 8)
                    }
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("登録トークン").font(.headline)
                    HStack {
                        Button("GitHub で取得", systemImage: "arrow.up.right.square") {
                            if let url = model.targetURL?.registrationPage { NSWorkspace.shared.open(url) }
                        }.disabled(model.targetURL == nil)
                        if RunnerInstaller.ghPath != nil {
                            Button(model.fetchingToken ? "取得中…" : "CLI で取得") { model.fetchToken() }
                                .disabled(model.targetURL == nil || model.fetchingToken)
                        }
                    }
                    SecureField("--token の値を貼り付け", text: $model.token).textFieldStyle(.roundedBorder)
                        .help("GitHub の Configure 欄にある --token の値。有効期限は1時間です。")
                }.padding(8)
            }
        }
        .disabled(model.isWorking || model.fetchingToken)
        .safeAreaInset(edge: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if model.isWorking {
                    HStack { ProgressView().controlSize(.small); Text(model.progress) }
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(model.error == nil ? "登録して起動" : "再試行") { model.install(monitor: monitor) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking || model.fetchingToken || model.request == nil)
                }
            }
        }
    }

    private func completion(_ result: SetupOutcome) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(result.snapshot.state == .idle || result.snapshot.state == .busy ? "セットアップ完了" : "登録済み", systemImage: "checkmark.circle.fill")
                .font(.title2).foregroundStyle(.green)
            Text("現在の状態: \(monitor.root == result.root ? monitor.snapshot.state.title : result.snapshot.state.title)")
            Text("ワークフロー設定").font(.headline)
            Text(model.workflow).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.workflow, forType: .string)
                }
                Button("ログ") { NSWorkspace.shared.open(result.root.appendingPathComponent("_diag")) }
                Spacer()
                Button("追加") {
                    model.outcome = nil
                    model.token = ""
                    model.name += "-2"
                }
            }
            Toggle("ログイン時に起動", isOn: Binding(get: { monitor.loginEnabled }, set: { monitor.setLogin($0) }))
                .toggleStyle(.switch)
        }
    }
}
