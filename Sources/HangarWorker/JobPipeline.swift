import Foundation
import HangarCore
import Logging

/// When a step runs, given what happened before it.
enum StepPolicy {
    /// Only while nothing has failed and the job was not cancelled.
    case normal
    /// Like `normal`; when it fails, `post-xcodebuild` still runs (`xcodebuild archive` and `-exportArchive`).
    case xcodebuild
    /// Like `normal`, but also after an `xcodebuild` step failed.
    case postXcodebuild
    /// Whatever happened before, without the cancellation watcher (`upload-artifacts`).
    case always
}

/// Thrown by the watcher when the job is cancelled while a step runs.
struct JobCancelled: Error {}

/// A failure before any git command ran; its description is the job's whole failure reason.
enum PreparationError: Error, Equatable, CustomStringConvertible {
    case xcodeNotInstalled(String)
    case appStoreConnectKeyMissing

    var description: String {
        switch self {
        case .xcodeNotInstalled(let version): "Xcode \(version) not installed"
        case .appStoreConnectKeyMissing: "App Store Connect key not configured; run hangar settings asc-key"
        }
    }
}

/// Runs a job's steps one at a time, reports each one's status to the server and remembers how the job went.
///
/// The first failure skips every later `normal` step. Cancellation is checked before each step and, while a step
/// runs, every second on the clock; a cancelled step is stopped by cancelling its task, which ends its process.
struct JobPipeline {
    private static let pollInterval = Duration.seconds(1)

    let jobID: UUID
    let connection: any ServerConnection
    let log: JobLog
    let clock: any Clock<Duration>
    let cancelled: @Sendable () -> Bool
    private let logger = Logger(label: "app.hangar.worker.pipeline")

    private(set) var failureReason: String?
    private(set) var wasCancelled = false
    /// Set when an `xcodebuild` step failed: its exit code, or 1 when it failed without one.
    private(set) var xcodebuildExitCode: Int32?

    init(
        jobID: UUID, connection: any ServerConnection, log: JobLog, clock: any Clock<Duration>,
        cancelled: @escaping @Sendable () -> Bool
    ) {
        self.jobID = jobID
        self.connection = connection
        self.log = log
        self.clock = clock
        self.cancelled = cancelled
    }

    /// Failure wins over a later cancellation: it is what explains the job.
    var status: JobStatus { failureReason != nil ? .failed : wasCancelled ? .cancelled : .succeeded }

    /// Runs `body` as step `name` unless its policy says otherwise, and returns its value when it succeeded.
    /// A value for which `skippedIf` holds (a hook that is absent) is reported as `skipped`.
    @discardableResult
    mutating func step<Value: Sendable>(
        _ name: String, _ policy: StepPolicy = .normal, skippedIf: (Value) -> Bool = { _ in false },
        _ body: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        if policy != .always, !wasCancelled, failureReason == nil, cancelled() {
            wasCancelled = true
            log.line(step: name, "job cancelled")
        }
        guard shouldRun(policy) else {
            await report(name, .skipped)
            return nil
        }
        await report(name, .running)
        do {
            let value = policy == .always ? try await body() : try await watched(body)
            await report(name, skippedIf(value) ? .skipped : .succeeded)
            return value
        } catch is JobCancelled {
            wasCancelled = true
            log.line(step: name, "job cancelled; stopped \(name)")
        } catch {
            let cause = Self.cause(error)
            log.line(step: name, error is PreparationError ? cause : "error: \(cause)")
            if failureReason == nil { failureReason = error is PreparationError ? cause : "\(name): \(cause)" }
            if policy == .xcodebuild, xcodebuildExitCode == nil { xcodebuildExitCode = Self.exitCode(error) ?? 1 }
        }
        await report(name, .failed)
        return nil
    }

    mutating func skip(_ name: String) async {
        await report(name, .skipped)
    }

    /// Best effort: a step update the server did not take is logged here and does not change the job.
    func report(_ name: String, _ status: StepStatus) async {
        do {
            try await connection.step(jobID: jobID, StepUpdate(name: name, status: status, at: Date()))
        } catch {
            logger.warning("could not report step \(name) as \(status.rawValue): \(error)", metadata: ["job": "\(jobID)"])
        }
    }

    private func shouldRun(_ policy: StepPolicy) -> Bool {
        switch policy {
        case .always: true
        case .normal, .xcodebuild: !wasCancelled && failureReason == nil
        case .postXcodebuild: !wasCancelled && (failureReason == nil || xcodebuildExitCode != nil)
        }
    }

    private enum Race<Value: Sendable>: Sendable {
        case finished(Value)
        case cancelled
    }

    /// Runs `body` next to a watcher that polls `cancelled()`; whichever finishes first cancels the other.
    private func watched<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Race<Value>.self) { group in
            group.addTask { .finished(try await body()) }
            group.addTask { [clock, cancelled] in
                while !cancelled() { try await clock.sleep(for: Self.pollInterval) }
                return .cancelled
            }
            defer { group.cancelAll() }
            switch try await group.next() {
            case .finished(let value): return value
            case .cancelled, nil: throw JobCancelled()
            }
        }
    }

    private static func exitCode(_ error: any Error) -> Int32? {
        switch error {
        case ArchiveError.xcodebuildFailed(let code), ArchiveError.packageResolutionFailed(let code),
            ExportError.xcodebuildFailed(let code): code
        default: nil
        }
    }

    private static func cause(_ error: any Error) -> String {
        if case ArchiveError.packageResolutionFailed = error { return String(describing: error) }
        if let code = exitCode(error) { return "xcodebuild exited with \(code)" }
        return String(describing: error)
    }
}

extension JobLog {
    /// A log callback that files every line under `step`.
    func lines(_ step: String) -> @Sendable (String) -> Void {
        { [self] text in line(step: step, text) }
    }
}
