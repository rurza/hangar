import Foundation
import Synchronization

/// Which cached workspaces a job of this worker is using, and when each was last built: the disk sweep removes an
/// idle workspace only while no job holds it, and a job starting meanwhile waits the second the removal takes.
///
/// When a workspace was last built is the modification date of its `.hangar-last-build`, touched as each job
/// starts, so it survives a restart.
public final class WorkspaceUse: Sendable {
    /// The one per worker process: every `JobRunner` and the sweep share it.
    public static let shared = WorkspaceUse()

    static let markerName = ".hangar-last-build"

    private let held = Mutex<[String: Int]>([:])

    public init() {}

    /// A job starts in `workspace`: it is held until `end` and marked as built now.
    public func begin(_ workspace: String) -> Lease {
        held.withLock { held in
            held[workspace, default: 0] += 1
            try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
            let marker = workspace + "/" + Self.markerName
            if !FileManager.default.createFile(atPath: marker, contents: nil) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker)
            }
        }
        return Lease(use: self, workspace: workspace)
    }

    fileprivate func end(_ workspace: String) {
        held.withLock { held in
            held[workspace, default: 1] -= 1
            if held[workspace] == 0 { held[workspace] = nil }
        }
    }

    /// Runs `remove` unless a job holds `workspace`, with no job able to begin there until it returns. False when
    /// the workspace was in use.
    public func whileIdle(_ workspace: String, _ remove: () throws -> Void) rethrows -> Bool {
        try held.withLock { held in
            guard held[workspace] == nil else { return false }
            try remove()
            return true
        }
    }

    public var inUse: Set<String> { held.withLock { Set($0.keys) } }

    /// Ends the hold once; a second `end` does nothing.
    public final class Lease: Sendable {
        private let use: WorkspaceUse
        private let workspace: String
        private let ended = Mutex(false)

        fileprivate init(use: WorkspaceUse, workspace: String) {
            self.use = use
            self.workspace = workspace
        }

        public func end() {
            let first = ended.withLock { ended in
                defer { ended = true }
                return !ended
            }
            if first { use.end(workspace) }
        }
    }
}
