import Foundation
import HangarCore
import Synchronization

/// Each app's branches, remembered for `lifetime` so opening the Deploy sheet again does not ask GitHub again.
/// Only answers are remembered; a failure is asked again next time. Keyed by app only, so a replaced token may see
/// the old token's list for up to a minute; two sheets opened at once ask GitHub twice. Both are harmless here.
public final class RepositoryBranchesCache: Sendable {
    static let lifetime: TimeInterval = 60

    private let entries = Mutex<[UUID: (branches: RepositoryBranches, expiresAt: Date)]>([:])
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// The cached branches of `appID`, else `load()`'s, which are then cached.
    func branches(_ appID: UUID, load: () async throws -> RepositoryBranches) async throws -> RepositoryBranches {
        let current = now()
        if let entry = entries.withLock({ $0[appID] }), entry.expiresAt > current { return entry.branches }
        let branches = try await load()
        entries.withLock { entries in
            entries = entries.filter { $0.value.expiresAt > current }
            entries[appID] = (branches, current.addingTimeInterval(Self.lifetime))
        }
        return branches
    }
}
