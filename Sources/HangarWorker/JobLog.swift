import Foundation
import HangarCore
import Logging
import Synchronization

/// A job's log on its way to the server. Every line is masked as it arrives, so nothing unmasked is ever queued,
/// logged locally or sent.
///
/// Lines go out in batches of at most 200 entries and 512 KB of line text: as soon as 200 are waiting, every second
/// on the clock, and on `flush()`. Sends run one at a time in order. A batch the server did not take stays queued,
/// ahead of newer lines, and is retried on the next send; `finalFlush()` retries with backoff before the job reports
/// its result. A batch the server refuses as too large or malformed (HTTP 413 or 400) is not retried as is: it is
/// split in halves, and a single line still refused is dropped with a local warning.
///
/// xcodebuild's steps are condensed (`XcodebuildLogCondenser`): the server gets each build task as one readable line
/// with what the tools printed, not the invocations. Every line, condensed or not, also goes masked into the full
/// log at `fullLogPath`, which the job uploads as an artifact when it holds more than the server's log.
///
/// A line longer than 16 KB is truncated (after masking, so no cut can leave part of a secret unmasked), with a note
/// that the full log has the rest. At most 20 000 lines wait; beyond that the oldest are dropped, so a server that is
/// down for long cannot exhaust memory.
public final class JobLog: Sendable {
    static let batchSize = 200
    static let maxBatchBytes = 512 * 1024
    static let maxLineBytes = 16 * 1024
    static let maxPending = 20_000
    static let interval = Duration.seconds(1)
    static let finalAttempts = 5

    private struct State {
        var pending: [LogEntry] = []
        /// Lines dropped because `pending` was full.
        var overflowed = 0
        /// The most recently queued send; each send waits for the one before it.
        var lastSend: Task<Void, Never>?
        var timer: Task<Void, Never>?
        /// Per step, the line that best explains a failure; see `FailureCause`.
        var causes: [String: FailureCause] = [:]
        /// Per xcodebuild step, its condenser.
        var condensers: [String: XcodebuildLogCondenser] = [:]
        /// Lines the server got condensed, cut or not at all: the full log is then worth keeping.
        var abridged = 0
        var fullLog: FileHandle?
        /// Set once the full log could not be opened or written: it is then incomplete and not uploaded.
        var fullLogFailed = false
    }

    private let jobID: UUID
    private let masker: SecretMasker
    private let connection: any ServerConnection
    private let clock: any Clock<Duration>
    private let fullLogPath: String?
    private let state = Mutex(State())
    private let logger = Logger(label: "app.hangar.worker.job")

    public init(
        jobID: UUID, masker: SecretMasker, connection: any ServerConnection, clock: any Clock<Duration>,
        fullLogPath: String? = nil
    ) {
        self.jobID = jobID
        self.fullLogPath = fullLogPath
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
        state.withLock { state in
            state.timer?.cancel()
            try? state.fullLog?.close()
        }
    }

    public func line(step: String, _ text: String) {
        let masked = masker.mask(text)
        logger.debug("\(masked)", metadata: ["job": "\(jobID.uuidString)", "step": "\(step)"])
        let now = Date()
        let (full, firstOverflow) = state.withLock { state in
            writeFullLog(&state, step: step, line: masked, at: now)
            var kept = [masked]
            if XcodebuildLogCondenser.condenses(step: step) {
                kept = state.condensers[step, default: XcodebuildLogCondenser()].consume(masked)
                if kept != [masked] { state.abridged += 1 }
            }
            for line in kept {
                let shown = Self.truncated(line)
                if shown.utf8.count != line.utf8.count { state.abridged += 1 }
                state.pending.append(LogEntry(t: now, step: step, line: shown))
                state.causes[step, default: FailureCause()].consume(shown)
            }
            let before = state.overflowed
            Self.dropOverflow(&state)
            return (state.pending.count >= Self.batchSize, before == 0 && state.overflowed > 0)
        }
        if firstOverflow {
            logger.warning(
                "more than \(Self.maxPending) log lines are waiting for the server; dropping the oldest",
                metadata: ["job": "\(jobID.uuidString)"])
        }
        if full { _ = queueSend() }
    }

    /// The line of `step`'s log that best explains its failure (masked like every line); nil when none stands out.
    /// `fallbackToLastLine` settles for the step's last line, for scripts whose errors follow no convention.
    public func cause(step: String, fallbackToLastLine: Bool = false) -> String? {
        state.withLock { $0.causes[step]?.line(fallbackToLastLine: fallbackToLastLine) }
    }

    /// `line` cut to `maxLineBytes` of UTF-8 (on a scalar boundary) with a note of how much was cut.
    static func truncated(_ line: String) -> String {
        let size = line.utf8.count
        guard size > maxLineBytes else { return line }
        var end = line.utf8.index(line.utf8.startIndex, offsetBy: maxLineBytes)
        while end.samePosition(in: line.unicodeScalars) == nil { line.utf8.formIndex(before: &end) }
        let kept = String(line.unicodeScalars[..<end])
        return kept + "… [line too long to show: \(sizeDescription(size - kept.utf8.count)) more are in the full log]"
    }

    /// "3 bytes", "52 KB".
    static func sizeDescription(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) byte\(bytes == 1 ? "" : "s")" : "\(bytes / 1024) KB"
    }

    // MARK: Full log

    /// The file name the full log is uploaded under.
    public static let fullLogArtifactName = "full-log.txt"

    private static let fullLogTime = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Appends `2026-11-05T13:32:03.736Z [archive] line` to the full log, opening it on the first line.
    private func writeFullLog(_ state: inout State, step: String, line: String, at time: Date) {
        guard let fullLogPath, !state.fullLogFailed else { return }
        do {
            if state.fullLog == nil {
                let url = URL(fileURLWithPath: fullLogPath)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                guard FileManager.default.createFile(atPath: fullLogPath, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fullLogPath]) }
                state.fullLog = try FileHandle(forWritingTo: url)
            }
            let text = "\(time.formatted(Self.fullLogTime)) [\(step)] \(line)\n"
            try state.fullLog?.write(contentsOf: Data(text.utf8))
        } catch {
            state.fullLogFailed = true
            try? state.fullLog?.close()
            state.fullLog = nil
            logger.warning("could not write the full log: \(error)", metadata: ["job": "\(jobID.uuidString)"])
        }
    }

    /// Copies the full log to `destination` and returns true when the server's log left something out (a condensed
    /// xcodebuild step, a cut line) and the copy is complete; false, copying nothing, otherwise.
    public func copyFullLog(to destination: String) throws -> Bool {
        let (worthIt, path) = state.withLock { state in
            (state.abridged > 0 && !state.fullLogFailed && state.fullLog != nil, fullLogPath)
        }
        guard worthIt, let path else { return false }
        try? FileManager.default.removeItem(atPath: destination)
        try FileManager.default.copyItem(atPath: path, toPath: destination)
        return true
    }

    private static func dropOverflow(_ state: inout State) {
        let excess = state.pending.count - maxPending
        guard excess > 0 else { return }
        state.pending.removeFirst(excess)
        state.overflowed += excess
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
            if pendingCount == 0 {
                closeFullLog()
                return 0
            }
            guard attempt < Self.finalAttempts else { break }
            do { try await clock.sleep(for: delay) } catch { break }
            delay *= 2
        }
        let dropped = pendingCount
        closeFullLog()
        logger.warning(
            "dropping \(dropped) log lines the server did not take after \(Self.finalAttempts) attempts",
            metadata: ["job": "\(jobID.uuidString)"])
        return dropped
    }

    private func closeFullLog() {
        state.withLock { state in
            try? state.fullLog?.close()
            state.fullLog = nil
            // Lines after the last flush go to the server only.
            state.fullLogFailed = true
        }
    }

    var pendingCount: Int { state.withLock { $0.pending.count } }
    var pendingLines: [String] { state.withLock { $0.pending.map(\.line) } }
    /// Lines dropped because too many were waiting.
    var overflowCount: Int { state.withLock { $0.overflowed } }

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
                var count = 0
                var bytes = 0
                for entry in state.pending.prefix(Self.batchSize) {
                    let size = entry.line.utf8.count
                    // Always at least one entry; truncation keeps any one line far below the cap.
                    if count > 0 && bytes + size > Self.maxBatchBytes { break }
                    count += 1
                    bytes += size
                }
                let batch = Array(state.pending.prefix(count))
                state.pending.removeFirst(count)
                return batch
            }
            guard !batch.isEmpty else { return }
            let unsent = await deliver(batch)
            if !unsent.isEmpty {
                state.withLock { state in
                    state.pending.insert(contentsOf: unsent, at: 0)
                    Self.dropOverflow(&state)
                }
                return
            }
        }
    }

    /// Sends `batch`; returns the entries to keep for a later attempt (empty once all were sent or dropped).
    private func deliver(_ batch: [LogEntry]) async -> [LogEntry] {
        do {
            try await connection.log(jobID: jobID, LogBatch(entries: batch))
            return []
        } catch ServerConnectionError.status(let status, _, _) where status == 413 || status == 400 {
            // Sending the same batch again would be refused again and hold back every later line.
            guard batch.count > 1 else {
                logger.warning(
                    "dropping a log line the server refused with HTTP \(status)",
                    metadata: ["job": "\(jobID.uuidString)", "step": "\(batch[0].step)"])
                return []
            }
            let middle = batch.count / 2
            let firstUnsent = await deliver(Array(batch[..<middle]))
            guard firstUnsent.isEmpty else { return firstUnsent + batch[middle...] }
            return await deliver(Array(batch[middle...]))
        } catch {
            logger.warning(
                "could not send \(batch.count) log lines; keeping them for the next attempt: \(error)",
                metadata: ["job": "\(jobID.uuidString)"])
            return batch
        }
    }
}
