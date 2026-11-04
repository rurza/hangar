import Foundation
import HangarCore
import Logging
import Synchronization

/// A job's log on its way to the server. Every line is masked as it arrives, so nothing unmasked is ever queued,
/// logged locally or sent.
///
/// Lines go out in batches of at most 200: as soon as 200 are waiting, every second on the clock, and on `flush()`.
/// Sends run one at a time in order. A batch the server did not take stays queued, ahead of newer lines, and is
/// retried on the next send; `finalFlush()` retries with backoff before the job reports its result.
public final class JobLog: Sendable {
    static let batchSize = 200
    static let interval = Duration.seconds(1)
    static let finalAttempts = 5

    private struct State {
        var pending: [LogEntry] = []
        /// The most recently queued send; each send waits for the one before it.
        var lastSend: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let jobID: UUID
    private let masker: SecretMasker
    private let connection: any ServerConnection
    private let clock: any Clock<Duration>
    private let state = Mutex(State())
    private let logger = Logger(label: "app.hangar.worker.job")

    public init(jobID: UUID, masker: SecretMasker, connection: any ServerConnection, clock: any Clock<Duration>) {
        self.jobID = jobID
        self.masker = masker
        self.connection = connection
        self.clock = clock
        let timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.interval) } catch { return }
                guard let self else { return }
                if state.withLock({ !$0.pending.isEmpty }) { _ = queueSend() }
            }
        }
        state.withLock { $0.timer = timer }
    }

    deinit {
        state.withLock { $0.timer?.cancel() }
    }

    public func line(step: String, _ text: String) {
        let masked = masker.mask(text)
        logger.debug("\(masked)", metadata: ["job": "\(jobID.uuidString)", "step": "\(step)"])
        let full = state.withLock { state in
            state.pending.append(LogEntry(t: Date(), step: step, line: masked))
            return state.pending.count >= Self.batchSize
        }
        if full { _ = queueSend() }
    }

    /// Returns once every line queued before the call was sent, or the server refused it (it then stays queued).
    public func flush() async {
        await queueSend().value
    }

    /// The last flush of a job: retries up to `finalAttempts` times, waiting 1 s, 2 s, 4 s… on the clock in between.
    /// Lines the server still has not taken are reported in a local warning and their count returned.
    @discardableResult
    public func finalFlush() async -> Int {
        var delay = Self.interval
        for attempt in 1...Self.finalAttempts {
            await flush()
            if pendingCount == 0 { return 0 }
            guard attempt < Self.finalAttempts else { break }
            do { try await clock.sleep(for: delay) } catch { break }
            delay *= 2
        }
        let dropped = pendingCount
        logger.warning(
            "dropping \(dropped) log lines the server did not take after \(Self.finalAttempts) attempts",
            metadata: ["job": "\(jobID.uuidString)"])
        return dropped
    }

    var pendingCount: Int { state.withLock { $0.pending.count } }

    private func queueSend() -> Task<Void, Never> {
        state.withLock { state in
            let previous = state.lastSend
            let send = Task {
                await previous?.value
                await self.sendPending()
            }
            state.lastSend = send
            return send
        }
    }

    private func sendPending() async {
        while true {
            let batch = state.withLock { state -> [LogEntry] in
                let batch = Array(state.pending.prefix(Self.batchSize))
                state.pending.removeFirst(batch.count)
                return batch
            }
            guard !batch.isEmpty else { return }
            do {
                try await connection.log(jobID: jobID, LogBatch(entries: batch))
            } catch {
                state.withLock { $0.pending.insert(contentsOf: batch, at: 0) }
                logger.warning(
                    "could not send \(batch.count) log lines; keeping them for the next attempt: \(error)",
                    metadata: ["job": "\(jobID.uuidString)"])
                return
            }
        }
    }
}
