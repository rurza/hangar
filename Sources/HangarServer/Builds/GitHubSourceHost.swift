import Foundation
import HangarCore

/// `SourceHost` over the GitHub REST API (github.com only).
public struct GitHubSourceHost: SourceHost {
    static let apiBase = "https://api.github.com"
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func resolveCommit(repoURL: String, ref: String, token: String?) async throws -> String {
        let (owner, repo) = try Self.parse(repoURL)
        guard let escapedRef = Self.escapePath(ref) else { throw SourceHostError.refNotFound(ref) }
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/commits/\(escapedRef)"
        let (data, response) = try await transport.send(try request(url, accept: "application/vnd.github+json", token: token))
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
        guard let escapedPath = Self.escapePath(path) else { throw SourceHostError.invalidPath(path) }
        let escapedCommit = Self.escapeQuery(commit)
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/contents/\(escapedPath)?ref=\(escapedCommit)"
        let (data, response) = try await transport.send(try request(url, accept: "application/vnd.github.raw", token: token))
        switch response.statusCode {
        case 200..<300: return String(decoding: data, as: UTF8.self)
        case 404: return nil
        default: throw Self.failure(response, data)
        }
    }

    private func request(_ url: String, accept: String, token: String?) throws -> URLRequest {
        guard let url = URL(string: url) else { throw SourceHostError.unsupportedRepository(url) }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Hangar", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func failure(_ response: HTTPURLResponse, _ data: Data) -> SourceHostError {
        .http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    /// Escapes each segment and keeps the slashes: `feature/x` stays a path. Nil when a segment is empty, `.` or
    /// `..`, which would change the API path.
    static func escapePath(_ path: String) -> String? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        // `/` is not in the set below, so a segment can never smuggle one in; `?`, `#` and `%` are escaped.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }.joined(separator: "/")
    }

    private static func escapeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private static func isValidName(_ name: String) -> Bool {
        name != "." && name != ".." && !name.isEmpty
            && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7a) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
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
        guard parts.count == 2, parts.allSatisfy(isValidName) else { throw SourceHostError.unsupportedRepository(repoURL) }
        return (parts[0], parts[1])
    }
}
