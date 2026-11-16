import Foundation

/// After a network drop the listener can keep polling without ever receiving jobs while GitHub still shows it online.
/// Its log looks the same as a healthy idle runner (poll timeouts are routine), so the signal comes from GitHub:
/// a job this runner could take has been queued for a while and the runner is idle both locally and on GitHub.
enum StuckWatch {
    static let queuedLimit: TimeInterval = 600
    static let cooldown: TimeInterval = 1800
    static let checkInterval: TimeInterval = 60

    struct QueuedJob { let labels: [String]; let createdAt: Date }

    static func isStuck(runnerLabels: [String], busyOnGitHub: Bool, jobs: [QueuedJob], now: Date = Date()) -> Bool {
        guard !busyOnGitHub else { return false }
        let own = Set(runnerLabels.map { $0.lowercased() })
        return jobs.contains { job in
            !job.labels.isEmpty && Set(job.labels.map { $0.lowercased() }).isSubset(of: own)
                && now.timeIntervalSince(job.createdAt) >= queuedLimit
        }
    }

    /// Repository runners only; organization runners would need every repository's queue.
    static func repository(of githubURL: String) -> String? {
        guard let target = try? GitHubTarget(githubURL), let repository = target.repository else { return nil }
        return target.owner + "/" + repository
    }

    static func check(name: String, githubURL: String) throws -> Bool {
        guard let repo = repository(of: githubURL) else { return false }
        guard let gh = RunnerInstaller.ghPath else { throw RunnerError.message("GitHub CLI が見つかりません") }
        func api<T: Decodable>(_ path: String, _ type: T.Type) throws -> T {
            let result = try LocalRunner.command(gh, ["api", "--hostname", "github.com", path], timeout: 30)
            guard result.status == 0 else { throw RunnerError.message("GitHub API に失敗しました: \(path)") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: Data(result.output.utf8))
        }
        struct Label: Decodable { let name: String }
        struct Runner: Decodable { let name: String; let busy: Bool; let labels: [Label] }
        struct Runners: Decodable { let runners: [Runner] }
        struct Run: Decodable { let id: Int }
        struct Runs: Decodable { let workflow_runs: [Run] }
        struct Job: Decodable { let status: String; let labels: [String]; let created_at: Date }
        struct Jobs: Decodable { let jobs: [Job] }

        guard let runner = try api("repos/\(repo)/actions/runners?per_page=100", Runners.self).runners.first(where: { $0.name == name }) else { return false }
        var jobs: [QueuedJob] = []
        for status in ["queued", "in_progress"] {
            for run in try api("repos/\(repo)/actions/runs?status=\(status)&per_page=20", Runs.self).workflow_runs {
                jobs += try api("repos/\(repo)/actions/runs/\(run.id)/jobs?filter=latest&per_page=100", Jobs.self).jobs
                    .filter { $0.status == "queued" }
                    .map { QueuedJob(labels: $0.labels, createdAt: $0.created_at) }
            }
        }
        return isStuck(runnerLabels: runner.labels.map(\.name), busyOnGitHub: runner.busy, jobs: jobs)
    }

    static func restart(root: URL) throws {
        let svc = try LocalRunner.service(root: root)
        let response = try LocalRunner.command("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(svc.label)"])
        guard response.status == 0 else { throw RunnerError.message(response.output) }
    }
}
