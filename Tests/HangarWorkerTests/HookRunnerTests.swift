import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct HookRunnerTests {
    /// A temp `ci_scripts` directory, removed by `cleanUp()`.
    struct Fixture {
        let root: String
        let scripts: String

        init() throws {
            root = NSTemporaryDirectory() + "hangar-hooks-\(UUID().uuidString)"
            scripts = root + "/ci_scripts"
            try FileManager.default.createDirectory(atPath: scripts, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(atPath: root) }

        func write(_ hook: Hook, _ body: String, permissions: Int) throws {
            let path = scripts + "/" + hook.rawValue
            try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }

    private static let environment = ["PATH": "/usr/bin:/bin", "CI_BUILD_NUMBER": "42"]

    private func run(
        _ hook: Hook = .postClone, _ fixture: Fixture, lines: LineSink
    ) async throws -> HookOutcome {
        try await HookRunner(runner: LiveProcessRunner()).run(
            hook, scriptsDirectory: fixture.scripts, environment: Self.environment
        ) { line in lines.append(line) }
    }

    @Test func absentHookIsSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // A directory with the hook's name counts as absent too.
        try FileManager.default.createDirectory(
            atPath: fixture.scripts + "/" + Hook.preXcodebuild.rawValue, withIntermediateDirectories: false)
        let lines = LineSink()
        #expect(try await run(.postClone, fixture, lines: lines) == .absent)
        #expect(try await run(.preXcodebuild, fixture, lines: lines) == .absent)
        #expect(lines.all.isEmpty)
    }

    @Test func runsWithCwdInCiScriptsAndEnv() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write(.postClone, "pwd -P > \"$1\" 2>/dev/null; echo \"$PWD|$CI_BUILD_NUMBER\" > ../out.txt", permissions: 0o755)
        #expect(try await run(.postClone, fixture, lines: LineSink()) == .ran)
        let output = try String(contentsOfFile: fixture.root + "/out.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = URL(fileURLWithPath: fixture.scripts).resolvingSymlinksInPath().path
        let parts = output.split(separator: "|").map(String.init)
        #expect(URL(fileURLWithPath: parts[0]).resolvingSymlinksInPath().path == expected)
        #expect(parts[1] == "42")
    }

    @Test func nonExecutableScriptRunsViaShWithWarning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write(.postClone, "echo ran-anyway", permissions: 0o644)
        let lines = LineSink()
        #expect(try await run(.postClone, fixture, lines: lines) == .ran)
        let logged = lines.all
        #expect(
            logged.first
                == "warning: ci_scripts/ci_post_clone.sh is not executable; running it with /bin/sh (Xcode Cloud requires chmod +x)"
        )
        #expect(logged.contains("ran-anyway"))
    }

    @Test func nonZeroExitFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write(.postClone, "exit 3", permissions: 0o755)
        let lines = LineSink()
        await #expect(throws: HookError.failed(hook: .postClone, exitCode: 3)) {
            try await run(.postClone, fixture, lines: lines)
        }
    }

    @Test func outputLinesAreForwardedInOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write(.postXcodebuild, "echo one; echo two; echo three", permissions: 0o755)
        let lines = LineSink()
        #expect(try await run(.postXcodebuild, fixture, lines: lines) == .ran)
        #expect(lines.all == ["one", "two", "three"])
    }
}
