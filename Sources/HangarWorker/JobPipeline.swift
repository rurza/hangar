import Foundation
import HangarCore
import Logging

/// When a step runs, given what happened before it.
enum StepPolicy {
    /// Only while nothing has failed and the job was not cancelled.
    case normal
    /// Like `normal`; when it fails, `post-xcodebuild` still runs (`xcodebuild archive`, `test` and `-exportArchive`).
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
    case noSimulator(platform: String, machine: String)
    case simulatorNotFound(name: String, platform: String, machine: String, available: [String])
    case keychainNotReady(reason: String, machine: String)
    case teamKeyRequired(machine: String)

    var description: String {
        switch self {
        case .xcodeNotInstalled(let version): "Xcode \(version) not installed"
        case .appStoreConnectKeyMissing: "App Store Connect key not configured; set it in Settings"
        case .noSimulator(let platform, let machine):
            "No \(platform) simulator available on \(machine); install one in Xcode › Settings › Components"
        case .simulatorNotFound(let name, let platform, let machine, let available):
            "No \(platform) simulator named “\(name)” on \(machine); available: \(available.joined(separator: ", "))"
        case .keychainNotReady(let reason, let machine): "The job's keychain on \(machine) is not ready: \(reason)"
        case .teamKeyRequired(let machine):
            "Signing in a VM on \(machine) needs a team App Store Connect key (with an issuer ID): a VM has no "
                + "Xcode account. Add the issuer ID in Settings."
        }
    }
}

/// Runs a job's steps one at a time, reports each one's status to the server and remembers how the job went.
///
/// The first failure skips every later `normal` step. Cancellation is checked before each step and, while a step
/// runs, every second on the clock; a cancelled step is stopped by cancelling its task, which ends its process.
struct JobPipeline {
    private static let pollInterval = Duration.seconds(1)
    /// Steps that run a repository's own script: their last line explains a failure when nothing else does.
    private static let scriptSteps: Set<String> = [StepName.postClone, StepName.preXcodebuild, StepName.postXcodebuild]

    /// How a step that ran to the end is reported, from its value.
    struct Ending {
        var status: StepStatus = .succeeded
        var detail: String?
        var stages: [StepStage]?
    }

    let jobID: UUID
    let connection: any ServerConnection
    let log: JobLog
    let clock: any Clock<Duration>
    let cancelled: @Sendable () -> Bool
    /// Why the worker itself stopped the job (it is shutting down); nil for a cancel the server asked for.
    let stopReason: @Sendable () -> String?
    /// Applied to every step detail before it leaves the machine: an error's description may quote a secret.
    let masker: SecretMasker
    private let logger = Logger(label: "app.hangar.worker.pipeline")

    private(set) var failureReason: String?
    private(set) var wasCancelled = false
    /// Set when the job was cancelled because the worker is stopping: the reason and the step it stopped.
    private(set) var stopNote: String?
    /// Set when an `xcodebuild` step failed: its exit code, or 1 when it failed without one.
    private(set) var xcodebuildExitCode: Int32?

    init(
        jobID: UUID, connection: any ServerConnection, log: JobLog, clock: any Clock<Duration>,
        cancelled: @escaping @Sendable () -> Bool, stopReason: @escaping @Sendable () -> String? = { nil },
        masker: SecretMasker = SecretMasker(secrets: [])
    ) {
        self.masker = masker
        self.jobID = jobID
        self.connection = connection
        self.log = log
        self.clock = clock
        self.cancelled = cancelled
        self.stopReason = stopReason
    }

    /// Failure wins over a later cancellation: it is what explains the job.
    var status: JobStatus { failureReason != nil ? .failed : wasCancelled ? .cancelled : .succeeded }

    /// What the job reports as its reason: the failure, else why the worker stopped it.
    var reason: String? { failureReason ?? stopNote }

    /// Runs `body` as step `name` unless its policy says otherwise, and returns its value when it succeeded.
    /// A value for which `skippedIf` holds (a hook that is absent) is reported as `skipped`; otherwise `ending` says
    /// how the step is reported (a post-action with warnings ends as `warning`).
    @discardableResult
    mutating func step<Value: Sendable>(
        _ name: String, _ policy: StepPolicy = .normal, skippedIf: (Value) -> Bool = { _ in false },
        ending: (Value) -> Ending = { _ in Ending() },
        _ body: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        if policy != .always, !wasCancelled, failureReason == nil, cancelled() {
            wasCancelled = true
            noteStop(before: name)
            log.line(step: name, "job cancelled")
        }
        guard shouldRun(policy) else {
            await report(name, .skipped)
            return nil
        }
        await report(name, .running)
        do {
            let value = policy == .always ? try await body() : try await watched(body)
            if skippedIf(value) {
                await report(name, .skipped)
            } else {
                let end = ending(value)
                await report(name, end.status, detail: end.detail, stages: end.stages)
            }
            return value
        } catch is JobCancelled {
            wasCancelled = true
            let stop = stopReason()
            if let stop, stopNote == nil { stopNote = "\(stop) during \(name)" }
            log.line(step: name, stop.map { "job stopped: \($0); stopped \(name)" } ?? "job cancelled; stopped \(name)")
            await report(name, .cancelled, detail: stop.map { "Stopped: \($0)" } ?? "Cancelled")
            return nil
        } catch {
            let cause = Self.cause(error)
            // The log's own explanation, when it has one, says more than an exit status.
            // Only an error that is just an exit status needs the log to explain it; failing tests name themselves.
            let explained = Self.isBareExitStatus(error)
                ? log.cause(step: name, fallbackToLastLine: Self.scriptSteps.contains(name)).flatMap { $0 == cause ? nil : $0 }
                : nil
            let detail = error is PreparationError ? cause : explained.map { "\($0) (\(cause))" } ?? cause
            log.line(step: name, error is PreparationError ? cause : "error: \(cause)")
            if failureReason == nil { failureReason = error is PreparationError ? cause : "\(name): \(detail)" }
            if policy == .xcodebuild, xcodebuildExitCode == nil { xcodebuildExitCode = Self.exitCode(error) ?? 1 }
            await report(name, .failed, detail: detail)
            return nil
        }
    }

    mutating func skip(_ name: String) async {
        await report(name, .skipped)
    }

    /// Best effort: a step update the server did not take is logged here and does not change the job. Details,
    /// the stages' too, are masked: an App Store Connect error body or a git URL may carry a secret.
    func report(_ name: String, _ status: StepStatus, detail: String? = nil, stages: [StepStage]? = nil) async {
        let stages = stages?.map { stage in
            StepStage(name: stage.name, status: stage.status, detail: stage.detail.map(masker.mask))
        }
        do {
            try await connection.step(
                jobID: jobID,
                StepUpdate(name: name, status: status, at: Date(), detail: detail.map(masker.mask), stages: stages))
        } catch {
            logger.warning("could not report step \(name) as \(status.rawValue): \(error)", metadata: ["job": "\(jobID)"])
        }
    }

    /// Reports `name`'s stages while it runs (a post-action's progress).
    func stageReporter(_ name: String) -> @Sendable ([StepStage]) async -> Void {
        { [self] stages in await report(name, .running, stages: stages) }
    }

    private mutating func noteStop(before name: String) {
        if let stop = stopReason(), stopNote == nil { stopNote = "\(stop) before \(name)" }
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
            ExportError.xcodebuildFailed(let code), TestError.xcodebuildFailed(let code),
            TestError.testsFailed(_, let code): code
        default: nil
        }
    }

    /// xcodebuild, a hook script or git exited non-zero, and the error says no more than that.
    private static func isBareExitStatus(_ error: any Error) -> Bool {
        if case TestError.testsFailed = error { return false }
        return exitCode(error) != nil || error is HookError || error is CheckoutError
    }

    private static func cause(_ error: any Error) -> String {
        if case ArchiveError.packageResolutionFailed = error { return String(describing: error) }
        if case TestError.testsFailed = error { return String(describing: error) }
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
