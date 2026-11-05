import Clocks
import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct JobLogTests {
    private let connection = FakeServerConnection()
    private let clock = TestClock()

    private func makeLog(_ connection: FakeServerConnection? = nil, secrets: [String] = []) -> JobLog {
        JobLog(jobID: UUID(), masker: SecretMasker(secrets: secrets), connection: connection ?? self.connection, clock: clock)
    }

    /// Yields until `condition` holds; the log sends from its own tasks.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
    }

    @Test func batchesHoldAtMost200EntriesInOrder() async {
        let log = makeLog()
        for index in 0..<450 { log.line(step: "archive", "line \(index)") }
        await log.flush()

        #expect(connection.batches.allSatisfy { $0.entries.count <= 200 })
        #expect(connection.logLines == (0..<450).map { "line \($0)" })
        #expect(connection.batches.flatMap(\.entries).allSatisfy { $0.step == "archive" })
    }

    @Test func fullBatchIsSentWithoutWaitingForTheTimer() async {
        let log = makeLog()
        for index in 0..<200 { log.line(step: "archive", "line \(index)") }
        await eventually { connection.batches.count == 1 }
        #expect(connection.batches.map(\.entries.count) == [200])
        withExtendedLifetime(log) {}
    }

    @Test func sendsEverySecondOnTheClock() async {
        let log = makeLog()
        log.line(step: "checkout", "hello")
        await Task.yieldRepeatedly()
        #expect(connection.batches.isEmpty)

        await clock.advance(by: .seconds(1))
        await eventually { !connection.batches.isEmpty }
        #expect(connection.logLines == ["hello"])
        withExtendedLifetime(log) {}
    }

    @Test func failedSendIsRetriedOnTheNextFlush() async {
        let failing = FakeServerConnection(failLogCalls: 1)
        let log = makeLog(failing)
        log.line(step: "archive", "first")
        await log.flush()
        #expect(failing.batches.isEmpty)

        log.line(step: "archive", "second")
        await log.flush()
        #expect(failing.logLines == ["first", "second"])
    }

    /// Moves the test clock forward while `body` runs, for waits on it.
    private func ticking<Value: Sendable>(_ body: @escaping @Sendable () async -> Value) async -> Value {
        let ticker = Task { [clock] in
            while !Task.isCancelled {
                await clock.advance(by: .seconds(1))
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { ticker.cancel() }
        return await body()
    }

    @Test func finalFlushRetriesWhenTheLastSendFails() async {
        let failing = FakeServerConnection(failLogCalls: 1)
        let log = makeLog(failing)
        for index in 0..<3 { log.line(step: "cleanup", "line \(index)") }

        let dropped = await ticking { await log.finalFlush() }

        #expect(dropped == 0)
        #expect(failing.logLines == ["line 0", "line 1", "line 2"])
    }

    @Test func finalFlushGivesUpAfterFiveAttemptsAndCountsTheLines() async {
        let failing = FakeServerConnection(failLogCalls: 100)
        let log = makeLog(failing)
        log.line(step: "cleanup", "a")
        log.line(step: "cleanup", "b")

        let dropped = await ticking { await log.finalFlush() }

        #expect(dropped == 2)
        #expect(failing.batches.isEmpty)
        #expect(log.pendingCount == 2)
    }

    @Test func linesAreMaskedBeforeBatching() async {
        let log = makeLog(secrets: ["hunter2-secret"])
        log.line(step: "archive", "password is hunter2-secret")
        await log.flush()
        #expect(connection.logLines == ["password is [masked]"])
    }
}

extension JobLogTests {
    private static func refused(_ status: Int) -> ServerConnectionError {
        .status(status, method: "POST", path: "/api/v1/worker/jobs/x/log")
    }

    @Test func batchesHoldAtMost512KBOfLineText() async {
        let log = makeLog()
        let text = String(repeating: "x", count: 10 * 1024)
        for index in 0..<100 { log.line(step: "archive", "\(index) \(text)") }
        await log.flush()

        #expect(connection.batches.count >= 2)
        #expect(connection.batches.allSatisfy { $0.entries.reduce(0) { $0 + $1.line.utf8.count } <= JobLog.maxBatchBytes })
        #expect(connection.logLines == (0..<100).map { "\($0) \(text)" })
    }

    @Test func longLinesAreTruncatedAfterMasking() async {
        let secret = "hunter2-secret"
        let log = makeLog(secrets: [secret])
        // The secret straddles the 16 KB cut: masked first, so no part of it survives the cut.
        let line = String(repeating: "x", count: JobLog.maxLineBytes - 5) + secret + String(repeating: "y", count: 100)
        log.line(step: "archive", line)
        log.line(step: "archive", "short")
        // A multi-byte character at the cut is kept whole or not at all.
        log.line(step: "archive", String(repeating: "x", count: JobLog.maxLineBytes - 1) + "é" + "z")
        await log.flush()

        let masked = String(repeating: "x", count: JobLog.maxLineBytes - 5) + "[masked]" + String(repeating: "y", count: 100)
        let cut = masked.utf8.count - JobLog.maxLineBytes
        #expect(connection.logLines.count == 3)
        #expect(connection.logLines[0] == String(masked.prefix(JobLog.maxLineBytes)) + "… [line too long to show: \(cut) bytes more are in the full log]")
        #expect(!connection.logLines[0].contains("hunte"))
        #expect(connection.logLines[1] == "short")
        #expect(connection.logLines[2] == String(repeating: "x", count: JobLog.maxLineBytes - 1) + "… [line too long to show: 3 bytes more are in the full log]")
        #expect(JobLog.sizeDescription(1) == "1 byte" && JobLog.sizeDescription(53_308) == "52 KB")
    }

    @Test func xcodebuildStepsAreCondensedAndTheFullLogKeepsEverything() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("joblog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fullLog = directory.appendingPathComponent("job/full-log.txt").path
        let log = JobLog(
            jobID: UUID(), masker: SecretMasker(secrets: ["hunter2"]), connection: connection, clock: clock,
            fullLogPath: fullLog)
        let compile = "SwiftDriver LegiloKit normal arm64 com.apple.xcode.tools.swift.compiler (in target 'LegiloKit' from project 'Legilo')"
        log.line(step: "post-clone", "    cd somewhere")
        log.line(step: "archive", compile)
        log.line(step: "archive", "    builtin-SwiftDriver -- swiftc -module-name LegiloKit -token hunter2")
        log.line(step: "archive", "")
        log.line(step: "archive", "** ARCHIVE SUCCEEDED **")
        await log.flush()

        #expect(connection.logLines == ["    cd somewhere", "▸ Compile LegiloKit (arm64)", "** ARCHIVE SUCCEEDED **"])
        let written = try String(contentsOfFile: fullLog, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(written.count == 6)
        #expect(written[0].hasSuffix("Z [post-clone]     cd somewhere"))
        #expect(written[1].hasSuffix("[archive] \(compile)"))
        #expect(written[2].hasSuffix("[archive]     builtin-SwiftDriver -- swiftc -module-name LegiloKit -token [masked]"))
        #expect(written[3].hasSuffix("[archive] "))
        #expect(written.last == "")

        let copy = directory.appendingPathComponent("artifacts-full-log.txt").path
        #expect(try log.copyFullLog(to: copy))
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == String(contentsOfFile: fullLog, encoding: .utf8))
    }

    @Test func aFullLogThatAddsNothingIsNotCopied() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("joblog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = JobLog(
            jobID: UUID(), masker: SecretMasker(secrets: []), connection: connection, clock: clock,
            fullLogPath: directory.appendingPathComponent("full-log.txt").path)
        log.line(step: "checkout", "git fetch")
        log.line(step: "archive", "** ARCHIVE SUCCEEDED **")
        let copy = directory.appendingPathComponent("copy.txt").path
        #expect(try !log.copyFullLog(to: copy))
        #expect(!FileManager.default.fileExists(atPath: copy))
        // A cut line is reason enough.
        log.line(step: "checkout", String(repeating: "x", count: JobLog.maxLineBytes + 10))
        #expect(try log.copyFullLog(to: copy))
        await log.flush()
    }

    @Test func aRefusedBatchIsSplitAndAPoisonLineDropped() async {
        let refusing = FakeServerConnection(refuseLog: { batch in
            batch.entries.contains { $0.line == "poison" } ? JobLogTests.refused(413) : nil
        })
        let log = makeLog(refusing)
        for line in ["a", "b", "poison", "c", "d"] { log.line(step: "archive", line) }
        await log.flush()

        #expect(refusing.logLines == ["a", "b", "c", "d"])
        #expect(log.pendingCount == 0)

        // Later lines are not held back.
        log.line(step: "archive", "e")
        await log.flush()
        #expect(refusing.logLines == ["a", "b", "c", "d", "e"])
    }

    @Test func a400IsSplitUntilTheServerTakesThePieces() async {
        let refusing = FakeServerConnection(refuseLog: { batch in batch.entries.count > 2 ? JobLogTests.refused(400) : nil })
        let log = makeLog(refusing)
        for index in 0..<7 { log.line(step: "archive", "line \(index)") }
        await log.flush()

        #expect(refusing.logLines == (0..<7).map { "line \($0)" })
        #expect(refusing.batches.allSatisfy { $0.entries.count <= 2 })
    }

    @Test func pendingLinesAreBoundedDroppingTheOldest() async {
        let failing = FakeServerConnection(failLogCalls: .max)
        let log = makeLog(failing)
        for index in 0..<(JobLog.maxPending + 5) { log.line(step: "archive", "line \(index)") }
        await log.flush()

        #expect(log.pendingCount == JobLog.maxPending)
        #expect(log.overflowCount == 5)
        #expect(log.pendingLines.first == "line 5")

        failing.setFailLogCalls(0)
        await log.flush()
        #expect(failing.logLines == (5..<(JobLog.maxPending + 5)).map { "line \($0)" })
    }
}

extension Task where Success == Never, Failure == Never {
    /// Gives other tasks plenty of chances to run.
    static func yieldRepeatedly() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
