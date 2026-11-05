import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct CheckoutTests {
    /// A bare "remote" plus a data directory, both removed by `cleanUp()`.
    struct Fixture {
        let root: String
        let remote: String
        let layout: WorkspaceLayout

        init() throws {
            root = NSTemporaryDirectory() + "hangar-checkout-\(UUID().uuidString)"
            remote = root + "/remote.git"
            layout = WorkspaceLayout(dataDirectory: root + "/worker", appSlug: "app", jobID: UUID())
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try git(["init", "--bare", "-b", "main", remote])
        }

        func cleanUp() { try? FileManager.default.removeItem(atPath: root) }

        @discardableResult
        func git(_ arguments: [String], in directory: String? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=T", "-c", "user.email=t@example.com"] + arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1"]
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(process.terminationStatus == 0, "git \(arguments) failed: \(text)")
            return text
        }

        /// Commits `files` (path -> contents) through a scratch clone and pushes; returns the new commit SHA.
        func commit(_ files: [String: String], message: String) throws -> String {
            let work = root + "/work"
            if !FileManager.default.fileExists(atPath: work + "/.git") {
                try git(["clone", remote, work])
            }
            for (path, contents) in files {
                let url = URL(fileURLWithPath: work + "/" + path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            try git(["add", "-A"], in: work)
            try git(["commit", "-m", message], in: work)
            try git(["push", "origin", "HEAD:main"], in: work)
            return try git(["rev-parse", "HEAD"], in: work)
        }

        func head() throws -> String { try git(["-C", layout.repository, "rev-parse", "HEAD"]) }
    }

    static func checkout(
        _ fixture: Fixture, url: String? = nil, commit: String, token: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) async throws
        -> [String]
    {
        let lines = Mutex<[String]>([])
        try await Checkout(runner: LiveProcessRunner(), layout: fixture.layout, extraEnvironment: extraEnvironment)
            .run(repoURL: url ?? "file://" + fixture.remote, commit: commit, token: token) { line in
                lines.withLock { $0.append(line) }
            }
        return lines.withLock { $0 }
    }

    @Test func clonesThenReusesWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sha = try fixture.commit(["a.txt": "1"], message: "one")

        let first = try await Self.checkout(fixture, commit: sha)
        #expect(first.contains { $0.hasPrefix("git clone ") })
        let second = try await Self.checkout(fixture, commit: sha)
        #expect(!second.contains { $0.hasPrefix("git clone ") })
        #expect(second.contains { $0.contains("fetch --prune --tags --force origin") })
        #expect(try fixture.head() == sha)
    }

    @Test func cleansGeneratedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sha = try fixture.commit(["a.txt": "1"], message: "one")
        _ = try await Self.checkout(fixture, commit: sha)
        let generated = fixture.layout.repository + "/Generated.xcodeproj"
        try FileManager.default.createDirectory(atPath: generated, withIntermediateDirectories: true)
        try "x".write(toFile: generated + "/x", atomically: true, encoding: .utf8)

        _ = try await Self.checkout(fixture, commit: sha)
        #expect(!FileManager.default.fileExists(atPath: generated + "/x"))
    }

    @Test func resetsModifiedTrackedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sha = try fixture.commit(["project.yml": "name: A\n"], message: "one")
        let newer = try fixture.commit(["project.yml": "name: B\n"], message: "two")
        _ = try await Self.checkout(fixture, commit: newer)
        try "name: Edited\n".write(toFile: fixture.layout.repository + "/project.yml", atomically: true, encoding: .utf8)

        _ = try await Self.checkout(fixture, commit: sha)
        let contents = try String(contentsOfFile: fixture.layout.repository + "/project.yml", encoding: .utf8)
        #expect(contents == "name: A\n")
        #expect(try fixture.head() == sha)
    }

    @Test func checksOutExactCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let older = try fixture.commit(["a.txt": "1"], message: "one")
        let newer = try fixture.commit(["a.txt": "2"], message: "two")
        #expect(older != newer)

        _ = try await Self.checkout(fixture, commit: older)
        #expect(try fixture.head() == older)
        // A commit pushed after the cache was populated is found by the next fetch.
        _ = try await Self.checkout(fixture, commit: newer)
        #expect(try fixture.head() == newer)
    }

    @Test func tokenNeverWrittenToConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sha = try fixture.commit(["a.txt": "1"], message: "one")

        let logs = try await Self.checkout(fixture, commit: sha, token: "ghp_secret")
        _ = try await Self.checkout(fixture, commit: sha, token: "ghp_secret")

        #expect(!logs.contains { $0.contains("ghp_secret") })
        let gitDirectory = fixture.layout.repository + "/.git"
        let config = try String(contentsOfFile: gitDirectory + "/config", encoding: .utf8)
        #expect(!config.contains("ghp_secret"))
        let enumerator = FileManager.default.enumerator(atPath: gitDirectory)
        while let relative = enumerator?.nextObject() as? String {
            guard let data = FileManager.default.contents(atPath: gitDirectory + "/" + relative) else { continue }
            #expect(!data.contains(Data("ghp_secret".utf8)), "token found in .git/\(relative)")
        }
    }

    @Test func updatesRemoteWhenRepositoryMoved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sha = try fixture.commit(["a.txt": "1"], message: "one")
        _ = try await Self.checkout(fixture, commit: sha)
        let moved = fixture.root + "/moved.git"
        try fixture.git(["clone", "--bare", fixture.remote, moved])

        _ = try await Self.checkout(fixture, url: "file://" + moved, commit: sha)
        #expect(try fixture.git(["-C", fixture.layout.repository, "remote", "get-url", "origin"]) == "file://" + moved)
    }

    @Test func replacesBrokenCloneDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sha = try fixture.commit(["a.txt": "1"], message: "one")
        try FileManager.default.createDirectory(atPath: fixture.layout.repository, withIntermediateDirectories: true)
        try "junk".write(toFile: fixture.layout.repository + "/junk", atomically: true, encoding: .utf8)

        _ = try await Self.checkout(fixture, commit: sha)
        #expect(try fixture.head() == sha)
    }

    @Test func unknownCommitFailsWithGitFailed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.commit(["a.txt": "1"], message: "one")

        await #expect(throws: CheckoutError.self) {
            _ = try await Self.checkout(fixture, commit: String(repeating: "a", count: 40))
        }
    }

    @Test func removesNestedGitRepositories() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sha = try fixture.commit(["a.txt": "1"], message: "one")
        _ = try await Self.checkout(fixture, commit: sha)
        let nested = fixture.layout.repository + "/.build/checkouts/dep"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try fixture.git(["init", nested])
        try "x".write(toFile: nested + "/f", atomically: true, encoding: .utf8)

        _ = try await Self.checkout(fixture, commit: sha)
        #expect(!FileManager.default.fileExists(atPath: nested))
    }

    @Test func tokenEnvironmentIsScopedAndIsolated() {
        let environment = Checkout.environment(token: "ghp_secret")
        #expect(environment["GIT_CONFIG_COUNT"] == "3")
        #expect(environment["GIT_CONFIG_KEY_0"] == "credential.helper")
        #expect(environment["GIT_CONFIG_VALUE_0"] == "")
        #expect(environment["GIT_CONFIG_KEY_1"] == "credential.https://github.com.helper")
        #expect(environment["GIT_CONFIG_VALUE_1"] == "")
        #expect(environment["GIT_CONFIG_KEY_2"] == "credential.https://github.com.helper")
        #expect(environment["GIT_CONFIG_VALUE_2"]?.contains("$HANGAR_GITHUB_TOKEN") == true)
        #expect(environment["HANGAR_GITHUB_TOKEN"] == "ghp_secret")
        #expect(environment["GIT_CONFIG_GLOBAL"] == nil)
        #expect(environment.filter { $0.value.contains("ghp_secret") }.keys.sorted() == ["HANGAR_GITHUB_TOKEN"])

        let none = Checkout.environment(token: nil)
        #expect(!none.keys.contains { $0.hasPrefix("GIT_CONFIG_KEY") || $0 == "GIT_CONFIG_COUNT" })
        #expect(none["HANGAR_GITHUB_TOKEN"] == nil)
    }

    @Test func runnerReceivesTokenOnlyInTokenVariable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = RecordingProcessRunner()
        try await Checkout(runner: runner, layout: fixture.layout)
            .run(repoURL: "https://github.com/o/r.git", commit: "abc", token: "ghp_secret") { _ in }
        #expect(!runner.commands.isEmpty)
        for command in runner.commands {
            #expect(!command.arguments.joined(separator: " ").contains("ghp_secret"))
            #expect(command.environment["HANGAR_GITHUB_TOKEN"] == "ghp_secret")
            #expect(command.environment.filter { $0.value.contains("ghp_secret") }.count == 1)
        }
    }

    /// The app's repository URL is user input: one shaped like an option must reach git as the repository.
    @Test func aRepositoryURLIsNeverReadAsAnOption() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let marker = fixture.root + "/injected"
        let url = "--upload-pack=touch \(marker)"
        let runner = RecordingProcessRunner()
        try await Checkout(runner: runner, layout: fixture.layout).run(repoURL: url, commit: "abc", token: nil) { _ in }
        let clone = try #require(runner.commands.first { $0.arguments.first == "clone" })
        #expect(clone.arguments == ["clone", "--", url, fixture.layout.repository])

        // With the real git the clone just fails, and nothing ran.
        await #expect(throws: CheckoutError.self) {
            _ = try await Self.checkout(fixture, url: url, commit: String(repeating: "a", count: 40))
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func resetsAndSyncsSubmodules() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // A second bare repo serves as the submodule; file:// submodules need protocol.file.allow in tests.
        let sub = fixture.root + "/sub.git"
        try fixture.git(["init", "--bare", "-b", "main", sub])
        let subWork = fixture.root + "/subwork"
        try fixture.git(["clone", sub, subWork])
        try "s".write(toFile: subWork + "/s.txt", atomically: true, encoding: .utf8)
        try fixture.git(["add", "-A"], in: subWork)
        try fixture.git(["commit", "-m", "sub"], in: subWork)
        try fixture.git(["push", "origin", "HEAD:main"], in: subWork)

        let work = fixture.root + "/work"
        _ = try fixture.commit(["a.txt": "1"], message: "one")
        try fixture.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "file://" + sub, "Sub"], in: work)
        try fixture.git(["commit", "-m", "add sub"], in: work)
        try fixture.git(["push", "origin", "HEAD:main"], in: work)
        let sha = try fixture.git(["rev-parse", "HEAD"], in: work)

        let allow = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always"]
        _ = try await Self.checkout(fixture, commit: sha, extraEnvironment: allow)
        let tracked = fixture.layout.repository + "/Sub/s.txt"
        try "edited".write(toFile: tracked, atomically: true, encoding: .utf8)
        try "junk".write(toFile: fixture.layout.repository + "/Sub/junk", atomically: true, encoding: .utf8)

        _ = try await Self.checkout(fixture, commit: sha, extraEnvironment: allow)
        #expect(try String(contentsOfFile: tracked, encoding: .utf8) == "s")
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.repository + "/Sub/junk"))
    }
}
