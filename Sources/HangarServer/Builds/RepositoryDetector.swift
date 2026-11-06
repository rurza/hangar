import CryptoKit
import Foundation
import HangarCore
import Synchronization

/// Reads a repository for `WorkflowDetector`: resolves the ref, lists the tree and fetches the few files the
/// detector asks for, within `timeout` in all. Also serves the icon images it finds, cached in memory.
public final class RepositoryDetector: Sendable {
    static let timeout: Duration = .seconds(15)
    static let imageLifetime: TimeInterval = 3600
    static let missLifetime: TimeInterval = 600
    static let maxImageBytes = WorkflowDetector.maxImageBytes

    struct Image: Sendable {
        var data: Data
        var contentType: String
    }

    private struct Entry {
        var image: Image?
        var expiresAt: Date
    }

    let sourceHost: any SourceHost
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let images = Mutex<[String: Entry]>([:])
    /// Trees and files read at a commit, so the workflow suggestion right after an inspection reads nothing again.
    private let snapshots = Mutex<[String: (snapshot: Snapshot, asked: Set<String>, expiresAt: Date)]>([:])
    static let snapshotLifetime: TimeInterval = 600
    static let maxSnapshots = 32
    static let maxImages = 256

    public init(sourceHost: any SourceHost, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = Date.init) {
        self.sourceHost = sourceHost
        self.clock = clock
        self.now = now
    }

    struct Snapshot: Sendable {
        var commit: String
        var tree: RepositoryTree
        var files: [String: String]
    }

    /// The commit `ref` (nil or empty: the default branch) resolves to, its tree and the files the detector wants.
    func read(repoURL: String, ref: String?, token: String?) async throws -> Snapshot {
        try await bounded {
            let defaultBranch = ref?.isEmpty ?? true
            let commit: String
            do {
                commit = try await self.sourceHost.resolveCommit(repoURL: repoURL, ref: defaultBranch ? "HEAD" : ref!, token: token)
            } catch SourceHostError.refNotFound where defaultBranch {
                // Not even the default branch: the repository itself is missing, or the token cannot read it.
                throw APIError(
                    code: "repository_not_found",
                    message: "GitHub has no repository at \(repoURL), or the GitHub token cannot read it.")
            }
            let key = Self.snapshotKey(repoURL: repoURL, commit: commit, token: token)
            let cached = self.snapshots.withLock { $0[key] }.flatMap { $0.expiresAt > self.now() ? $0 : nil }
            let tree: RepositoryTree
            if let cached { tree = cached.snapshot.tree } else {
                tree = try await self.sourceHost.tree(repoURL: repoURL, commit: commit, token: token)
            }
            var files = cached?.snapshot.files ?? [:]
            var asked = cached?.asked ?? []
            for _ in 0..<WorkflowDetector.maxFetchRounds {
                let budget = WorkflowDetector.maxFileFetches - asked.count
                let wanted = Array(WorkflowDetector.filesToFetch(tree: tree, files: files).filter { !asked.contains($0) }.prefix(budget))
                if wanted.isEmpty { break }
                asked.formUnion(wanted)
                let fetched = try await withThrowingTaskGroup(of: (String, String?).self) { group in
                    for path in wanted {
                        group.addTask { (path, try await self.sourceHost.readFile(repoURL: repoURL, commit: commit, path: path, token: token)) }
                    }
                    var result: [String: String] = [:]
                    for try await (path, text) in group { if let text { result[path] = text } }
                    return result
                }
                files.merge(fetched) { $1 }
            }
            let snapshot = Snapshot(commit: commit, tree: tree, files: files)
            let now = self.now()
            self.snapshots.withLock { cache in
                cache[key] = (snapshot, asked, now.addingTimeInterval(Self.snapshotLifetime))
                Self.prune(&cache, now: now, limit: Self.maxSnapshots, expiry: \.expiresAt)
            }
            return snapshot
        }
    }

    /// `bundleIDs` (the app's) picks its schemes when the repository builds several apps.
    func suggestion(
        repoURL: String, ref: String?, token: String?, machines: [Machine], bundleIDs: [String]? = nil
    ) async throws -> WorkflowSuggestion {
        let snapshot = try await read(repoURL: repoURL, ref: ref, token: token)
        return try WorkflowDetector.suggest(
            tree: snapshot.tree, files: snapshot.files, machines: machines, now: now(), commit: snapshot.commit,
            bundleIDs: bundleIDs)
    }

    func inspection(repoURL: String, ref: String?, token: String?) async throws -> RepositoryInspection {
        let snapshot = try await read(repoURL: repoURL, ref: ref, token: token)
        return try WorkflowDetector.inspect(tree: snapshot.tree, files: snapshot.files, commit: snapshot.commit)
    }

    /// An image file at a commit: PNG or JPEG bytes only, at most `maxImageBytes`. Cached by repository, commit and
    /// path (a commit never changes).
    func image(repoURL: String, commit: String, path: String, token: String?) async throws -> Image {
        try await cached("\(repoURL)|\(commit)|\(path)") {
            do {
                guard let data = try await self.bounded({
                    try await self.sourceHost.readData(
                        repoURL: repoURL, commit: commit, path: path, token: token, maxBytes: Self.maxImageBytes)
                }) else { return nil }
                return Self.image(data)
            } catch SourceHostError.tooLarge {
                return nil
            }
        }
    }

    static let iconNotFound = APIError(code: "icon_not_found", message: "The repository has no app icon image Hangar can show.")

    /// Hits for an hour, misses for ten minutes; errors are not remembered.
    private func cached(_ key: String, _ load: @Sendable () async throws -> Image?) async throws -> Image {
        if let entry = images.withLock({ $0[key] }), entry.expiresAt > now() {
            guard let image = entry.image else { throw Self.iconNotFound }
            return image
        }
        let image: Image?
        do {
            image = try await load()
        } catch let error as APIError where error.code == Self.iconNotFound.code {
            image = nil
        }
        let lifetime = image == nil ? Self.missLifetime : Self.imageLifetime
        let now = now()
        images.withLock { cache in
            cache[key] = Entry(image: image, expiresAt: now.addingTimeInterval(lifetime))
            Self.prune(&cache, now: now, limit: Self.maxImages, expiry: \.expiresAt)
        }
        guard let image else { throw Self.iconNotFound }
        return image
    }

    /// Drops expired entries, then the ones closest to expiring until at most `limit` are left.
    static func prune<Value>(_ cache: inout [String: Value], now: Date, limit: Int, expiry: KeyPath<Value, Date>) {
        cache = cache.filter { $0.value[keyPath: expiry] > now }
        guard cache.count > limit else { return }
        for (key, _) in cache.sorted(by: { $0.value[keyPath: expiry] < $1.value[keyPath: expiry] }).prefix(cache.count - limit) {
            cache.removeValue(forKey: key)
        }
    }

    /// Reads with different tokens may see different things, so the token is part of the key (as a hash).
    static func snapshotKey(repoURL: String, commit: String, token: String?) -> String {
        let hash = SHA256.hash(data: Data((token ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(repoURL)|\(commit)|\(hash)"
    }

    static func image(_ data: Data) -> Image? {
        guard data.count <= maxImageBytes else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return Image(data: data, contentType: "image/png") }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return Image(data: data, contentType: "image/jpeg") }
        return nil
    }

    static let timedOut = APIError(
        code: "detection_timeout", message: "GitHub did not answer within 15 seconds. Try again in a moment.")

    /// Runs `work`, given up after `timeout`.
    private func bounded<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask { [clock] in
                try await clock.sleep(for: Self.timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw Self.timedOut }
            return value
        }
    }
}
