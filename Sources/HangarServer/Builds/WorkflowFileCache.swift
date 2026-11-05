import Foundation
import HangarCore
import Synchronization

/// A repository's parsed `.hangar.yml` per app and commit, kept for `lifetime`. A commit never changes, so the
/// only reason to forget is memory; the deploy dry run, asked every few seconds, then reads GitHub once per commit.
public final class WorkflowFileCache: Sendable {
    static let lifetime: TimeInterval = 600

    private let entries = Mutex<[String: (file: WorkflowFile, expiresAt: Date)]>([:])
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    func file(appID: UUID, commit: String, load: () async throws -> WorkflowFile) async throws -> WorkflowFile {
        let key = "\(appID)|\(commit.lowercased())"
        let current = now()
        if let entry = entries.withLock({ $0[key] }), entry.expiresAt > current { return entry.file }
        let file = try await load()
        entries.withLock { entries in
            entries = entries.filter { $0.value.expiresAt > current }
            entries[key] = (file, current.addingTimeInterval(Self.lifetime))
        }
        return file
    }
}
