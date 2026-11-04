import Foundation
import HangarCore

/// `SourceHost` over the GitHub REST API (github.com only).
public struct GitHubSourceHost: SourceHost {
    static let apiBase = "https://api.github.com"
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func resolveCommit(repoURL: String, ref: String, token: String?) async throws -> String {
        let (owner, repo) = try Self.parse(repoURL)
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/commits/\(Self.escapePath(ref))"
        let (data, response) = try await transport.send(request(url, accept: "application/vnd.github+json", token: token))
        switch response.statusCode {
        case 200..<300:
            struct Commit: Decodable { var sha: String }
            return try JSONDecoder().decode(Commit.self, from: data).sha
        case 404, 422: throw SourceHostError.refNotFound(ref)
        default: throw Self.failure(response, data)
        }
    }

    public func readFile(repoURL: String, commit: String, path: String, token: String?) async throws -> String? {
        let (owner, repo) = try Self.parse(repoURL)
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/contents/\(Self.escapePath(path))?ref=\(commit)"
        let (data, response) = try await transport.send(request(url, accept: "application/vnd.github.raw", token: token))
        switch response.statusCode {
        case 200..<300: return String(decoding: data, as: UTF8.self)
        case 404: return nil
        default: throw Self.failure(response, data)
        }
    }

    private func request(_ url: String, accept: String, token: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)  // built from escaped parts
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Hangar", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func failure(_ response: HTTPURLResponse, _ data: Data) -> SourceHostError {
        .http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    /// Escapes each segment and keeps the slashes: `feature/x` stays a path.
    static func escapePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    /// `owner/repo` from `https://github.com/owner/repo(.git)` or `git@github.com:owner/repo(.git)`.
    static func parse(_ repoURL: String) throws -> (owner: String, repo: String) {
        var rest = repoURL.trimmingCharacters(in: .whitespaces)
        if let prefix = ["https://github.com/", "git@github.com:"].first(where: rest.hasPrefix) {
            rest.removeFirst(prefix.count)
        } else {
            throw SourceHostError.unsupportedRepository(repoURL)
        }
        while rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { throw SourceHostError.unsupportedRepository(repoURL) }
        return (parts[0], parts[1])
    }
}
