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
            return try Self.decode(Commit.self, data).sha
        case 404, 422: throw SourceHostError.refNotFound(ref)
        default: throw Self.failure(response, data)
        }
    }

    public func readFile(repoURL: String, commit: String, path: String, token: String?) async throws -> String? {
        try await readData(repoURL: repoURL, commit: commit, path: path, token: token).map { String(decoding: $0, as: UTF8.self) }
    }

    public func readData(repoURL: String, commit: String, path: String, token: String?, maxBytes: Int?) async throws -> Data? {
        let (owner, repo) = try Self.parse(repoURL)
        guard let escapedPath = Self.escapePath(path) else { throw SourceHostError.invalidPath(path) }
        let escapedCommit = Self.escapeQuery(commit)
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/contents/\(escapedPath)?ref=\(escapedCommit)"
        let (data, response) = try await transport.send(try request(url, accept: "application/vnd.github.raw", token: token))
        switch response.statusCode {
        case 200..<300:
            if let maxBytes {
                let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? 0
                guard declared <= maxBytes, data.count <= maxBytes else {
                    throw SourceHostError.tooLarge(path: path, bytes: max(declared, data.count))
                }
            }
            return data
        case 404: return nil
        default: throw Self.failure(response, data)
        }
    }

    public func tree(repoURL: String, commit: String, token: String?) async throws -> RepositoryTree {
        let (owner, repo) = try Self.parse(repoURL)
        guard let escapedCommit = Self.escapePath(commit), !commit.contains("/") else { throw SourceHostError.refNotFound(commit) }
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/git/trees/\(escapedCommit)?recursive=1"
        let (data, response) = try await transport.send(try request(url, accept: "application/vnd.github+json", token: token))
        switch response.statusCode {
        case 200..<300:
            struct Tree: Decodable {
                struct Entry: Decodable {
                    var path: String
                    var type: String?
                    var size: Int?
                    var mode: String?
                }
                var tree: [Entry]
                var truncated: Bool?
            }
            let tree = try Self.decode(Tree.self, data)
            let sizes = Dictionary(
                tree.tree.compactMap { entry in entry.type == "blob" ? entry.size.map { (entry.path, $0) } : nil },
                uniquingKeysWith: { first, _ in first })
            let executables = Set(tree.tree.filter { $0.type == "blob" && $0.mode == "100755" }.map(\.path))
            return RepositoryTree(
                paths: tree.tree.map(\.path), truncated: tree.truncated ?? false, sizes: sizes, executables: executables)
        case 404, 422: throw SourceHostError.refNotFound(commit)
        default: throw Self.failure(response, data)
        }
    }

    public func branches(repoURL: String, token: String?) async throws -> RepositoryBranches {
        let (owner, repo) = try Self.parse(repoURL)
        let base = "\(Self.apiBase)/repos/\(owner)/\(repo)"
        struct Repository: Decodable {
            var defaultBranch: String?
            enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
        }
        struct Branch: Decodable { var name: String }
        let repository = try await get(Repository.self, base, token: token)
        let branches = try await get([Branch].self, "\(base)/branches?per_page=100", token: token)
        return RepositoryBranches(defaultBranch: repository.defaultBranch, branches: branches.map(\.name)).defaultFirst
    }

    private func get<T: Decodable>(_ type: T.Type, _ url: String, token: String?) async throws -> T {
        let (data, response) = try await transport.send(try request(url, accept: "application/vnd.github+json", token: token))
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(response, data) }
        return try Self.decode(type, data)
    }

    func request(_ url: String, accept: String, token: String?) throws -> URLRequest {
        guard let url = URL(string: url) else { throw SourceHostError.unsupportedRepository(url) }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Hangar", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func failure(_ response: HTTPURLResponse, _ data: Data) -> SourceHostError {
        if [403, 429].contains(response.statusCode), response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
            let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
            return .rateLimited(resetAt: reset.map(Date.init(timeIntervalSince1970:)))
        }
        return .http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    /// A GitHub response decoded; one that does not decode is the host's fault, not the request's.
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        do { return try decoder.decode(type, from: data) } catch {
            throw SourceHostError.invalidResponse("GitHub sent a response Hangar cannot read.")
        }
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
