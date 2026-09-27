import Foundation

struct RunnerProfile: Identifiable, Hashable {
    let root: URL
    let name: String
    var id: String { root.path }

    static func discover(savedPaths: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [RunnerProfile] {
        let fm = FileManager.default
        var paths = savedPaths
        paths.append(home.appendingPathComponent("actions-runner").path)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        for file in (try? fm.contentsOfDirectory(at: launchAgents, includingPropertiesForKeys: nil)) ?? [] {
            guard file.lastPathComponent.hasPrefix("actions.runner."), file.pathExtension == "plist",
                  let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workingDirectory = plist["WorkingDirectory"] as? String else { continue }
            paths.append(workingDirectory)
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            let root = URL(fileURLWithPath: path).standardizedFileURL
            guard seen.insert(root.path).inserted,
                  var data = try? Data(contentsOf: root.appendingPathComponent(".runner")) else { return nil }
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
            guard let config = try? JSONDecoder().decode(RunnerConfiguration.self, from: data) else { return nil }
            return RunnerProfile(root: root, name: config.agentName)
        }
    }
}
