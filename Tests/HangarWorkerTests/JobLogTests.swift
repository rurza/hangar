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

    @Test func linesAreMaskedBeforeBatching() async {
        let log = makeLog(secrets: ["hunter2-secret"])
        log.line(step: "archive", "password is hunter2-secret")
        await log.flush()
        #expect(connection.logLines == ["password is [masked]"])
    }
}

extension Task where Success == Never, Failure == Never {
    /// Gives other tasks plenty of chances to run.
    static func yieldRepeatedly() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
