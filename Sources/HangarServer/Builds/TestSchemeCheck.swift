import Foundation
import HangarCore
import Logging
import Synchronization

/// Test actions whose scheme has no tests, judged from the repository at the build's commit (`SchemeTests`): such a
/// job can only fail, so the deploy is refused before a build number is reserved. Answers are kept per commit and
/// scheme (they never change) for ten minutes, since the Deploy sheet asks every 15 s. A lookup that fails blocks
/// nothing: the build then finds out for itself.
public final class TestSchemeCheck: Sendable {
    static let lifetime: TimeInterval = 600
    /// At most this many scheme files are read per scheme.
    static let maxFiles = 4

    private let entries = Mutex<[String: (problem: String?, expiresAt: Date)]>([:])
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "app.hangar.server.test-schemes")

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    func problems(
        app: App, workflow: Workflow, commit: String, token: String?, sourceHost: any SourceHost
    ) async -> [String] {
        let schemes = workflow.actions.filter { $0.kind == .test }.map(\.scheme)
        var seen: Set<String> = []
        var problems: [String] = []
        var tree: RepositoryTree?
        for scheme in schemes where seen.insert(scheme).inserted {
            let key = "\(app.id)|\(commit.lowercased())|\(scheme)"
            let current = now()
            if let entry = entries.withLock({ $0[key] }), entry.expiresAt > current {
                if let problem = entry.problem { problems.append(problem) }
                continue
            }
            do {
                if tree == nil { tree = try await sourceHost.tree(repoURL: app.repoURL, commit: commit, token: token) }
                var files: [String: String] = [:]
                for path in SchemeTests.sharedSchemeFiles(named: scheme, in: tree?.paths ?? []).prefix(Self.maxFiles) {
                    files[path] = try await sourceHost.readFile(repoURL: app.repoURL, commit: commit, path: path, token: token)
                }
                let problem = SchemeTests.problem(scheme: scheme, files: files)
                entries.withLock { entries in
                    entries = entries.filter { $0.value.expiresAt > current }
                    entries[key] = (problem, current.addingTimeInterval(Self.lifetime))
                }
                if let problem { problems.append(problem) }
            } catch {
                logger.info("could not read scheme \(scheme) of \(app.slug) at \(commit): \(error)")
            }
        }
        return problems
    }
}
