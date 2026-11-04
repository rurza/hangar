import Foundation
import Synchronization

/// Jobs a user asked to cancel while they were assigned or running. The server remembers them here and the
/// worker routes hand them out in the heartbeat response until the worker reports the job finished.
public final class CancelRequests: Sendable {
    private let jobIDs = Mutex<Set<UUID>>([])

    public init() {}

    public func request(_ jobIDs: [UUID]) { self.jobIDs.withLock { $0.formUnion(jobIDs) } }

    /// The requested cancellations among `jobIDs`.
    public func pending(for jobIDs: [UUID]) -> [UUID] {
        self.jobIDs.withLock { requested in jobIDs.filter(requested.contains) }
    }

    public func clear(_ jobID: UUID) { _ = jobIDs.withLock { $0.remove(jobID) } }
}
