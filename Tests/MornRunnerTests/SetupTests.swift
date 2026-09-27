import Foundation
import Testing
@testable import MornRunner

struct SetupTests {
    @Test func registrationTargets() throws {
        let org = try GitHubTarget(" https://github.com/example/ ")
        #expect(org.url == "https://github.com/example")
        #expect(org.tokenEndpoint == "orgs/example/actions/runners/registration-token")
        #expect(org.registrationPage.absoluteString == "https://github.com/organizations/example/settings/actions/runners/new")
        let repo = try GitHubTarget("example/project")
        #expect(repo.tokenEndpoint == "repos/example/project/actions/runners/registration-token")
        #expect(repo.registrationPage.absoluteString == "https://github.com/example/project/settings/actions/runners/new")
        #expect(try GitHubTarget("github.com/example/project") == repo)
        for invalid in ["", "https://evil.test/org", "http://github.com/org", "https://github.com@evil.test/org", "https://user@github.com/org", "org/repo/settings", "org/..", "org/repo?token=x", "org/repo#fragment", "https://github.com:8443/org"] {
            #expect(throws: (any Error).self) { try GitHubTarget(invalid) }
        }
    }

    @Test func configArgumentsAndNameValidation() throws {
        let request = try SetupRequest(target: "org/repo", name: "mac-1", labels: "build, unity", root: URL(fileURLWithPath: "/tmp/mac-1"))
        #expect(request.arguments == ["--unattended", "--url", "https://github.com/org/repo", "--name", "mac-1", "--work", "_work", "--labels", "build,unity"])
        #expect(!request.arguments.contains("--replace"))
        #expect(!request.arguments.contains("--token"))
        for invalid in ["", "../existing", ".", "..", "a/b", "$(touch test)", String(repeating: "a", count: 65)] {
            #expect(throws: (any Error).self) { try SetupRequest(target: "org", name: invalid, labels: "", root: URL(fileURLWithPath: "/tmp/test")) }
        }
    }

    @Test func preserveExistingDestinationAndResumeOnlyMatchingRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try SetupRequest(target: "org/repo", name: "my-mac", labels: "", root: root)
        #expect(try !RunnerInstaller.validateDestination(request))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try RunnerInstaller.validateDestination(request) }
        let receipt = InstallReceipt(target: request.target.url, name: request.name, labels: request.labels)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(".mornrunner-install.json"))
        #expect(try RunnerInstaller.validateDestination(request))
        let other = try SetupRequest(target: "other/repo", name: "my-mac", labels: "", root: root)
        #expect(throws: (any Error).self) { try RunnerInstaller.validateDestination(other) }
    }

    @Test func verifyArchiveRejectsTampering() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        try RunnerInstaller.verify(archive: file, digest: "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(throws: (any Error).self) { try RunnerInstaller.verify(archive: file, digest: "sha256:" + String(repeating: "0", count: 64)) }
    }

    @Test func officialAssetSelection() throws {
        let hash = "sha256:" + String(repeating: "a", count: 64)
        let asset = RunnerRelease.Asset(name: "actions-runner-osx-arm64-2.337.0.tar.gz", browser_download_url: URL(string: "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-osx-arm64-2.337.0.tar.gz")!, digest: hash)
        let release = RunnerRelease(tag_name: "v2.337.0", assets: [asset])
        #expect(try release.asset(architecture: "arm64").name == asset.name)
        #expect(throws: (any Error).self) { try release.asset(architecture: "x64") }
        let unverified = RunnerRelease(tag_name: "v2.337.0", assets: [.init(name: asset.name, browser_download_url: asset.browser_download_url, digest: nil)])
        #expect(throws: (any Error).self) { try unverified.asset(architecture: "arm64") }
    }

    @Test func discoverSavedAndServiceRunners() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent("actions-runner")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"agentName\":\"Existing\",\"gitHubUrl\":\"https://github.com/example\"}".utf8).write(to: root.appendingPathComponent(".runner"))
        let profiles = RunnerProfile.discover(savedPaths: [root.path, root.path, "/missing"], home: home)
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Existing")
    }

    @Test func subprocessTimeoutAndFailure() throws {
        #expect(try LocalRunner.command("/usr/bin/false", []).status != 0)
        #expect(throws: (any Error).self) { try LocalRunner.command("/bin/sleep", ["20"], timeout: 0.1) }
    }
}
