import Foundation
import Synchronization

/// Whether each app's repository has a `.hangar.yml` at its default branch, remembered for `lifetime` so app pages
/// do not ask GitHub on every view. Storing or deleting the app's workflow in Hangar forgets the answer.
public final class RepositoryWorkflowFileCache: Sendable {
    static let lifetime: TimeInterval = 600

    private let entries = Mutex<[UUID: (present: Bool, expiresAt: Date)]>([:])
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    func get(_ appID: UUID) -> Bool? {
        entries.withLock { $0[appID] }.flatMap { $0.expiresAt > now() ? $0.present : nil }
    }

    func set(_ appID: UUID, present: Bool) {
        let now = now()
        entries.withLock { entries in
            entries = entries.filter { $0.value.expiresAt > now }
            entries[appID] = (present, now.addingTimeInterval(Self.lifetime))
        }
    }

    func forget(_ appID: UUID) {
        _ = entries.withLock { $0.removeValue(forKey: appID) }
    }
}
