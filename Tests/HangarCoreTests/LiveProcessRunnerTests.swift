import Foundation
import Synchronization
import Testing
@testable import HangarCore

/// Collects lines delivered from a `@Sendable` callback.
final class LineCollector: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ line: String) { storage.withLock { $0.append(line) } }
    var values: [String] { storage.withLock { $0 } }
}

@Suite struct LiveProcessRunnerTests {
    let runner = LiveProcessRunner()

    @Test func mergesStdoutAndStderrInOrderWithExitCodeAndUnterminatedLine() async throws {
        let received = LineCollector()
        let script = "echo one; echo two >&2; echo three; printf last; exit 7"
        let outcome = try await runner.run(
            ProcessCommand(executable: "/bin/sh", arguments: ["-c", script])
        ) { received.append($0) }
        #expect(outcome.exitCode == 7)
        #expect(received.values == ["one", "two", "three", "last"])
        #expect(outcome.output == "one\ntwo\nthree\nlast")
    }

    @Test func usesOnlyTheGivenEnvironmentAndDirectory() async throws {
        let outcome = try await runner.run(
            ProcessCommand(
                executable: "/bin/sh", arguments: ["-c", "echo $FOO-${HOME:-nohome}; pwd"],
                environment: ["FOO": "bar"], currentDirectory: "/tmp")
        ) { _ in }
        #expect(outcome.output == "bar-nohome\n/private/tmp")
    }

    @Test func resolvesRelativeExecutableViaEnv() async throws {
        let outcome = try await runner.run(
            ProcessCommand(executable: "echo", arguments: ["hi"], environment: ["PATH": "/bin:/usr/bin"])
        ) { _ in }
        #expect(outcome.output == "hi")
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await runner.run(ProcessCommand(executable: "/nonexistent/tool", arguments: [])) { _ in }
        }
    }

    @Test func cancellationKillsTheChild() async throws {
        let started = LineCollector()
        let clock = ContinuousClock()
        let begin = clock.now
        let task = Task {
            try await runner.run(
                ProcessCommand(executable: "/bin/sh", arguments: ["-c", "echo started; exec sleep 30"])
            ) { started.append($0) }
        }
        while started.values.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(begin.duration(to: clock.now) < .seconds(10))
    }

    @Test func slowConsumerStillReceivesEveryLineOfLargeOutput() async throws {
        // 600 lines of 120 bytes exceed the 64 KB pipe buffer, so the child exits while data is still unread.
        // At 10 ms per line, delivering one pipe chunk takes longer than the 1 s idle cap.
        let text = String(repeating: "x", count: 119)
        let received = LineCollector()
        let outcome = try await runner.run(
            ProcessCommand(executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 600 ]; do echo \(text); i=$((i+1)); done"])
        ) { line in
            received.append(line)
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(outcome.exitCode == 0)
        #expect(received.values == Array(repeating: text, count: 600))
        #expect(outcome.output == Array(repeating: text, count: 600).joined(separator: "\n"))
    }
}
