import CryptoKit
import Foundation
import HangarCore
import Synchronization

/// The repositories a GitHub token can see, for the "Add app" picker: `GET /user/repos`, every page (at most
/// `maxPages`), cached in memory for `lifetime` per token. The token is only ever sent in the Authorization header;
/// errors never carry it or GitHub's response text.
public final class GitHubRepositories: Sendable {
    static let lifetime: TimeInterval = 300
    static let maxPages = 10
    static let firstPage =
        "\(GitHubSourceHost.apiBase)/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member"

    private struct Entry {
        /// SHA-256 of the token the list was fetched with: a new token never sees the old token's list.
        var tokenHash: Data
        var repos: [GitHubRepo]
        var expiresAt: Date
    }

    private let host: GitHubSourceHost
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let cache = Mutex<Entry?>(nil)

    public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.host = GitHubSourceHost(transport: transport)
        self.now = now
    }

    public func repositories(token: String) async throws -> [GitHubRepo] {
        let hash = Data(SHA256.hash(data: Data(token.utf8)))
        if let entry = cache.withLock({ $0 }), entry.tokenHash == hash, entry.expiresAt > now() { return entry.repos }

        var repos: [GitHubRepo] = []
        var next: String? = Self.firstPage
        var pages = 0
        while let url = next, pages < Self.maxPages {
            pages += 1
            let (data, response) = try await transport.send(try host.request(url, accept: "application/vnd.github+json", token: token))
            switch response.statusCode {
            case 200..<300: break
            case 401: throw Self.unauthorized
            // GitHub's text is left out: it is not ours to show.
            default:
                if case .rateLimited(let reset) = GitHubSourceHost.failure(response, data) { throw SourceHostError.rateLimited(resetAt: reset) }
                throw SourceHostError.http(status: response.statusCode, body: "")
            }
            repos += try GitHubSourceHost.decode([Page.Repo].self, data, decoder: Self.decoder).map(\.repo)
            next = Self.nextLink(response.value(forHTTPHeaderField: "Link"))
        }
        cache.withLock { $0 = Entry(tokenHash: hash, repos: repos, expiresAt: now().addingTimeInterval(Self.lifetime)) }
        return repos
    }

    static let unauthorized = APIError(
        code: "github_unauthorized", message: "GitHub refused the token. Set a new one in Settings.")

    private enum Page {
        struct Repo: Decodable {
            var full_name: String
            var html_url: String
            var `private`: Bool
            var default_branch: String?
            var description: String?
            var pushed_at: Date?
            var archived: Bool?

            var repo: GitHubRepo {
                GitHubRepo(
                    fullName: full_name, htmlURL: html_url, isPrivate: `private`, defaultBranch: default_branch ?? "main",
                    description: description, pushedAt: pushed_at, archived: archived ?? false)
            }
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The `rel="next"` URL of a Link header, only when it stays on the GitHub API over https.
    static func nextLink(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == #"rel="next""# }),
                pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">")
            else { continue }
            let url = String(pieces[0].dropFirst().dropLast())
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host == "api.github.com", parsed.user == nil,
                parsed.port == nil
            else { return nil }
            return url
        }
        return nil
    }
}
