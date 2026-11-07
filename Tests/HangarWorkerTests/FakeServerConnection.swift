import Foundation
import HangarCore
import Synchronization

@testable import HangarWorker

/// Records every call a worker makes to the server, in order. `failLogCalls` makes that many `log` calls throw first;
/// uploads named in `failUploads` always throw; one named in `unreachableUploads` cannot reach the server that many
/// times first; `finishErrors` are thrown, in order, by the first `finish` calls.
/// `refuseLog` may answer a log batch with an error (an HTTP 413, say) instead of taking it. `startError` is thrown by
/// `start`.
final class FakeServerConnection: ServerConnection {
    enum Event: Equatable {
        case start
        case step(String, StepStatus)
        case info(JobRunInfo)
        case log(LogBatch)
        case upload(name: String, path: String)
        case finish(JobResult)
    }

    struct Unavailable: Error {}

    private struct State {
        var events: [Event] = []
        var failLogCalls = 0
        var finishErrors: [any Error] = []
        var finishAttempts = 0
        var updates: [StepUpdate] = []
        var unreachableUploads: [String: Int] = [:]
    }

    private let state: Mutex<State>
    private let failUploads: Set<String>
    private let refuseLog: @Sendable (LogBatch) -> (any Error)?
    private let startError: (any Error)?

    init(
        failLogCalls: Int = 0, failUploads: Set<String> = [], unreachableUploads: [String: Int] = [:],
        finishErrors: [any Error] = [],
        refuseLog: @escaping @Sendable (LogBatch) -> (any Error)? = { _ in nil }, startError: (any Error)? = nil
    ) {
        state = Mutex(State(failLogCalls: failLogCalls, finishErrors: finishErrors, unreachableUploads: unreachableUploads))
        self.failUploads = failUploads
        self.refuseLog = refuseLog
        self.startError = startError
    }

    func setFailLogCalls(_ count: Int) { state.withLock { $0.failLogCalls = count } }

    var events: [Event] { state.withLock { $0.events } }
    var finishAttempts: Int { state.withLock { $0.finishAttempts } }

    var steps: [(name: String, status: StepStatus)] {
        events.compactMap { if case .step(let name, let status) = $0 { (name, status) } else { nil } }
    }

    /// Each step's last reported status, in order of first report.
    var finalStatuses: [(name: String, status: StepStatus)] {
        var order: [String] = []
        var last: [String: StepStatus] = [:]
        for step in steps {
            if last[step.name] == nil { order.append(step.name) }
            last[step.name] = step.status
        }
        return order.map { ($0, last[$0]!) }
    }

    func status(of step: String) -> StepStatus? { finalStatuses.first { $0.name == step }?.status }

    var batches: [LogBatch] { events.compactMap { if case .log(let batch) = $0 { batch } else { nil } } }
    var logLines: [String] { batches.flatMap(\.entries).map(\.line) }
    var uploads: [String] { events.compactMap { if case .upload(let name, _) = $0 { name } else { nil } } }
    var result: JobResult? { events.compactMap { if case .finish(let result) = $0 { result } else { nil } }.last }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse { HeartbeatResponse() }

    func nextJob(wait: Int) async throws -> JobAssignment? { nil }

    func start(jobID: UUID) async throws {
        state.withLock { $0.events.append(.start) }
        if let startError { throw startError }
    }

    /// A `running` update that only carries stages (a post-action's progress) is kept in `updates` alone, so
    /// `events` and `steps` list each step's transitions.
    func step(jobID: UUID, _ update: StepUpdate) async throws {
        state.withLock {
            $0.updates.append(update)
            let progress = update.status == .running && update.stages != nil
            if !progress { $0.events.append(.step(update.name, update.status)) }
        }
    }

    /// Every step update, progress included, with its detail and stages.
    var updates: [StepUpdate] { state.withLock { $0.updates } }

    /// The last update of `step` that changed its status.
    func lastUpdate(of step: String) -> StepUpdate? {
        updates.last { $0.name == step && !($0.status == .running && $0.stages != nil) }
    }

    func info(jobID: UUID, _ info: JobRunInfo) async throws {
        state.withLock { $0.events.append(.info(info)) }
    }

    var infos: [JobRunInfo] { events.compactMap { if case .info(let info) = $0 { info } else { nil } } }

    func log(jobID: UUID, _ batch: LogBatch) async throws {
        try state.withLock {
            if $0.failLogCalls > 0 {
                $0.failLogCalls -= 1
                throw Unavailable()
            }
            if let error = refuseLog(batch) { throw error }
            $0.events.append(.log(batch))
        }
    }

    func uploadArtifact(jobID: UUID, name: String, fileURL: URL) async throws {
        if failUploads.contains(name) { throw Unavailable() }
        try state.withLock {
            if let left = $0.unreachableUploads[name], left > 0 {
                $0.unreachableUploads[name] = left - 1
                // As URLSession throws it: with its description.
                throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."])
            }
            $0.events.append(.upload(name: name, path: fileURL.path))
        }
    }

    func finish(jobID: UUID, _ result: JobResult) async throws {
        try state.withLock {
            $0.finishAttempts += 1
            if !$0.finishErrors.isEmpty { throw $0.finishErrors.removeFirst() }
            $0.events.append(.finish(result))
        }
    }
}
