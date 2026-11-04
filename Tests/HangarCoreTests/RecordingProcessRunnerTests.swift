import Foundation
import Testing
@testable import HangarCore

@Suite struct RecordingProcessRunnerTests {
    @Test func scriptedOutcomeAndRecording() async throws {
        let runner = RecordingProcessRunner()
        runner.script({ $0.executable == "git" }, lines: ["a", "b"], exitCode: 3)
        let received = LineCollector()
        let git = ProcessCommand(executable: "git", arguments: ["status"], currentDirectory: "/repo")
        let outcome = try await runner.run(git) { received.append($0) }
        #expect(outcome == ProcessOutcome(exitCode: 3, output: "a\nb"))
        #expect(received.values == ["a", "b"])

        let other = try await runner.run(ProcessCommand(executable: "ls", arguments: [])) { _ in }
        #expect(other == ProcessOutcome(exitCode: 0, output: ""))
        #expect(runner.commands.map(\.executable) == ["git", "ls"])
        #expect(runner.commands[0].currentDirectory == "/repo")
        #expect(runner.commands[0].environment.isEmpty)
    }

    @Test func firstMatchingScriptWins() async throws {
        let runner = RecordingProcessRunner()
        runner.script({ _ in true }, lines: ["first"], exitCode: 1)
        runner.script({ _ in true }, lines: ["second"], exitCode: 2)
        let outcome = try await runner.run(ProcessCommand(executable: "x", arguments: [])) { _ in }
        #expect(outcome.exitCode == 1)
    }

    @Test func hangingCommandThrowsWhenCancelled() async throws {
        let runner = RecordingProcessRunner()
        runner.scriptHang { $0.executable == "codesign" }
        let task = Task { try await runner.run(ProcessCommand(executable: "codesign", arguments: [])) { _ in } }
        while runner.commands.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
