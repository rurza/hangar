import Foundation
import HangarCore

/// Where an app's source lives: resolves refs to commits and reads files at a commit.
public protocol SourceHost: Sendable {
    /// The full commit SHA `ref` (branch, tag or SHA) points at.
    func resolveCommit(repoURL: String, ref: String, token: String?) async throws -> String
    /// The file's text at `commit`, or nil when the commit has no such file.
    func readFile(repoURL: String, commit: String, path: String, token: String?) async throws -> String?
    /// The file's bytes at `commit`, or nil when the commit has no such file. A body over `maxBytes` (by its
    /// Content-Length, else its size) throws `tooLarge`.
    func readData(repoURL: String, commit: String, path: String, token: String?, maxBytes: Int?) async throws -> Data?
    /// Every file and directory path at `commit`.
    func tree(repoURL: String, commit: String, token: String?) async throws -> RepositoryTree
    /// The repository's default branch and its branch names.
    func branches(repoURL: String, token: String?) async throws -> RepositoryBranches
}

public enum SourceHostError: Error, Equatable, Sendable {
    case unsupportedRepository(String)
    case refNotFound(String)
    case invalidPath(String)
    case http(status: Int, body: String)
    /// The host's rate limit is used up until `resetAt`.
    case rateLimited(resetAt: Date?)
    /// The host answered with something that is not what its API documents.
    case invalidResponse(String)
    case tooLarge(path: String, bytes: Int)
}

extension SourceHost {
    /// Hosts that cannot list branches offer none; the Deploy sheet then takes a typed ref only.
    public func branches(repoURL: String, token: String?) async throws -> RepositoryBranches {
        RepositoryBranches(defaultBranch: nil, branches: [])
    }

    public func readData(repoURL: String, commit: String, path: String, token: String?) async throws -> Data? {
        try await readData(repoURL: repoURL, commit: commit, path: path, token: token, maxBytes: nil)
    }
}
