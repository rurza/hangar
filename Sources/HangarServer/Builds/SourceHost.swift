import Foundation

/// Where an app's source lives: resolves refs to commits and reads files at a commit.
public protocol SourceHost: Sendable {
    /// The full commit SHA `ref` (branch, tag or SHA) points at.
    func resolveCommit(repoURL: String, ref: String, token: String?) async throws -> String
    /// The file's text at `commit`, or nil when the commit has no such file.
    func readFile(repoURL: String, commit: String, path: String, token: String?) async throws -> String?
}

public enum SourceHostError: Error, Equatable, Sendable {
    case unsupportedRepository(String)
    case refNotFound(String)
    case invalidPath(String)
    case http(status: Int, body: String)
}
