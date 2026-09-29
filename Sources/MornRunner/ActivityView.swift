import AppKit
import SwiftUI

@MainActor
final class ActivityModel: ObservableObject {
    @Published var activity = RunnerActivity()
    @Published var loaded = false
    private var refreshing = false
    private var sleepLog: (text: String, at: Date)?

    func refresh(root: URL, busy: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        let cached = sleepLog.flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.text : nil }
        let value = await Task.detached(priority: .utility) { () -> (RunnerActivity, String?) in
            // The sleep log is large and changes rarely; refresh it once a minute.
            let sleep = cached ?? (try? LocalRunner.command("/usr/bin/pmset", ["-g", "log"]).output)
            return (ActivityLog.collect(root: root, busy: busy, sleepLog: sleep), sleep)
        }.value
        if cached == nil, let text = value.1 { sleepLog = (text, Date()) }
        activity = value.0
        loaded = true
        refreshing = false
    }
}

struct ActivityView: View {
    @ObservedObject var monitor: RunnerMonitor
    @ObservedObject var model: ActivityModel
    @State private var showWorker = false
    @State private var essentialsOnly = true

    var body: some View {
        VStack(spacing: 0) {
            ActivityHeader(snapshot: monitor.snapshot, activity: model.activity)
                .padding(20)
            Divider()
            HStack(spacing: 0) {
                JobHistoryPanel(jobs: model.activity.jobs, loaded: model.loaded)
                    .frame(maxWidth: .infinity)
                Divider()
                EventPanel(events: model.activity.events, loaded: model.loaded)
                    .frame(width: 320)
            }
            .frame(height: 250)
            Divider()
            LogPanel(activity: model.activity, showWorker: $showWorker, essentialsOnly: $essentialsOnly)
        }
        .frame(minWidth: 780, minHeight: 640)
        .task(id: monitor.root) {
            while !Task.isCancelled {
                await model.refresh(root: monitor.root, busy: monitor.snapshot.state == .busy)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct ActivityHeader: View {
    let snapshot: RunnerSnapshot
    let activity: RunnerActivity

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: snapshot.state.symbol)
                .font(.system(size: 40)).foregroundStyle(snapshot.state.color)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.state.title).font(.title.bold())
                Text(snapshot.detail).foregroundStyle(.secondary).textSelection(.enabled)
                if let job = activity.currentJob {
                    CurrentJobCard(job: job, progress: activity.progress).padding(.top, 6)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(snapshot.name).font(.headline)
                Text(snapshot.githubURL.replacingOccurrences(of: "https://github.com/", with: ""))
                    .font(.caption).foregroundStyle(.secondary)
                Text("確認: \(snapshot.checkedAt, style: .time)")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

struct CurrentJobCard: View {
    let job: JobRecord
    let progress: JobProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "gearshape.2.fill").foregroundStyle(.blue)
                Text(job.name).font(.headline).lineLimit(1)
                Spacer()
                Text(job.started, style: .timer).monospacedDigit().foregroundStyle(.secondary)
            }
            if let progress, let total = progress.totalSteps, total > 0 {
                ProgressView(value: Double(min(progress.completedSteps, total)), total: Double(total))
                Text("\(progress.completedSteps)/\(total) ステップ完了" + (progress.currentStep.map { " · \($0)" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else if let step = progress?.currentStep {
                Text("ステップ: \(step)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("ジョブの準備中").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct JobHistoryPanel: View {
    let jobs: [JobRecord]
    let loaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ジョブ履歴").font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if jobs.isEmpty {
                Placeholder(text: loaded ? "記録されたジョブはありません" : "読み込み中…")
            } else {
                List(jobs.prefix(50)) { job in
                    HStack(spacing: 10) {
                        Image(systemName: icon(job).0).foregroundStyle(icon(job).1).frame(width: 16)
                        Text(job.name).lineLimit(1).help(job.name)
                        Spacer()
                        Text(job.started, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary).monospacedDigit()
                        Group {
                            if job.isRunning { Text(job.started, style: .timer) }
                            else if let duration = job.duration { Text(Self.format(duration)) }
                            else { Text("—") }
                        }
                        .frame(width: 64, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .help(job.resultTitle)
                }
                .listStyle(.inset)
            }
        }
    }

    func icon(_ job: JobRecord) -> (String, Color) {
        switch job.result {
        case nil: return ("gearshape.2.fill", .blue)
        case "Succeeded": return ("checkmark.circle.fill", .green)
        case "Failed": return ("xmark.circle.fill", .red)
        case "Canceled": return ("minus.circle.fill", .orange)
        default: return ("exclamationmark.circle", .secondary)
        }
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct EventPanel: View {
    let events: [RunnerEvent]
    let loaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("接続とスリープ").font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if events.isEmpty {
                Placeholder(text: loaded ? "イベントはありません" : "読み込み中…")
            } else {
                List(events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(event.kind).0).foregroundStyle(icon(event.kind).1).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.message).font(.callout).lineLimit(2).help(event.message)
                            Text(event.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    func icon(_ kind: RunnerEvent.Kind) -> (String, Color) {
        switch kind {
        case .listenerStarted: return ("power", .secondary)
        case .connected: return ("checkmark.circle", .green)
        case .connectError: return ("wifi.exclamationmark", .red)
        case .reconnected: return ("arrow.triangle.2.circlepath", .green)
        case .sleep: return ("moon.zzz.fill", .indigo)
        case .wake: return ("sun.max.fill", .orange)
        }
    }
}

struct LogPanel: View {
    let activity: RunnerActivity
    @Binding var showWorker: Bool
    @Binding var essentialsOnly: Bool

    private var useWorker: Bool { showWorker && activity.workerLogPath != nil }
    private var path: String? { useWorker ? activity.workerLogPath : activity.runnerLogPath }
    private var text: String {
        if essentialsOnly { return useWorker ? activity.workerLogEssentials : activity.runnerLogEssentials }
        return useWorker ? activity.workerLogTail : activity.runnerLogTail
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(useWorker ? "ジョブのログ" : "ランナーのログ").font(.headline)
                if activity.workerLogPath != nil {
                    Picker("", selection: $showWorker) {
                        Text("ランナー").tag(false)
                        Text("実行中のジョブ").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                Toggle("要点のみ", isOn: $essentialsOnly).toggleStyle(.checkbox)
                Spacer()
                Button("Finder で表示", systemImage: "folder") {
                    if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .disabled(path == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(verbatim: text.isEmpty ? (essentialsOnly ? "要点になる行がまだありません" : "ログがありません") : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onAppear { proxy.scrollTo("bottom") }
                .onChange(of: text) { proxy.scrollTo("bottom") }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
