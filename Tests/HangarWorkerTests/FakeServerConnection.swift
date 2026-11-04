import Foundation
import HangarCore
import Synchronization

@testable import HangarWorker

/// Records every call a worker makes to the server, in order. `failLogCalls` makes that many `log` calls throw first.
final class FakeServerConnection: ServerConnection {
    enum Event: Equatable {
        case start
        case step(String, StepStatus)
        case log(LogBatch)
        case upload(name: String, path: String)
        case finish(JobResult)
    }

    struct Unavailable: Error {}

    private struct State {
        var events: [Event] = []
        var failLogCalls = 0
    }

    private let state: Mutex<State>

    init(failLogCalls: Int = 0) {
        state = Mutex(State(failLogCalls: failLogCalls))
    }

    var events: [Event] { state.withLock { $0.events } }

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
    }

    func step(jobID: UUID, _ update: StepUpdate) async throws {
        state.withLock { $0.events.append(.step(update.name, update.status)) }
    }

    func log(jobID: UUID, _ batch: LogBatch) async throws {
        try state.withLock {
            if $0.failLogCalls > 0 {
                $0.failLogCalls -= 1
                throw Unavailable()
            }
            $0.events.append(.log(batch))
        }
    }

    func uploadArtifact(jobID: UUID, name: String, fileURL: URL) async throws {
        state.withLock { $0.events.append(.upload(name: name, path: fileURL.path)) }
    }

    func finish(jobID: UUID, _ result: JobResult) async throws {
        state.withLock { $0.events.append(.finish(result)) }
    }
}
