import CryptoKit
import Foundation
import HangarCore
import Synchronization

/// Whose a GitHub token is (`GET /user`), cached per token for `lifetime`. The token goes only into the
/// Authorization header; errors carry neither it nor GitHub's text.
public final class GitHubAccounts: Sendable {
    static let lifetime: TimeInterval = 300
    static let rejected = APIError(
        code: "github_token_rejected",
        message: "GitHub did not accept this token: it may be mistyped, expired or revoked. Create a new one and try again.")

    private let host: GitHubSourceHost
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let cache = Mutex<[Data: (login: String, expiresAt: Date)]>([:])

    init(transport: any HTTPTransport, now: @escaping @Sendable () -> Date) {
        self.transport = transport
        self.host = GitHubSourceHost(transport: transport)
        self.now = now
    }

    /// The token's login. Throws `github_token_rejected` on 401, the mapped `SourceHostError` otherwise.
    func login(token: String) async throws -> String {
        let hash = Self.hash(token)
        if let entry = cache.withLock({ $0[hash] }), entry.expiresAt > now() { return entry.login }
        var request = try host.request("\(GitHubSourceHost.apiBase)/user", accept: "application/vnd.github+json", token: token)
        request.timeoutInterval = 15
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401: throw Self.rejected
        default:
            if case .rateLimited(let reset) = GitHubSourceHost.failure(response, data) { throw SourceHostError.rateLimited(resetAt: reset) }
            throw SourceHostError.http(status: response.statusCode, body: "")
        }
        struct User: Decodable { var login: String }
        let login = try GitHubSourceHost.decode(User.self, data).login
        cache.withLock { $0[hash] = (login, now().addingTimeInterval(Self.lifetime)) }
        return login
    }

    /// SHA-256 of the token, hex: what is kept to recognise a token without keeping it.
    static func hash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    static func hexHash(_ token: String) -> String { hash(token).map { String(format: "%02x", $0) }.joined() }
}

/// The GitHub CLI on the server's Mac: its signed-in account and its token.
struct GitHubCLI {
    let environment: SetupEnvironment

    static let notSignedIn = APIError(
        code: "gh_not_signed_in",
        message: "The GitHub CLI on this Mac has no login for github.com. Run gh auth login in Terminal, or paste a token instead.")

    /// The login of `gh`'s active github.com account; nil without gh, a login or a network.
    func login() async -> String? {
        guard let login = await environment.output("gh", ["api", "user", "--jq", ".login"]),
            login.wholeMatch(of: /[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/) != nil
        else { return nil }
        return login
    }

    /// `gh auth token` for github.com: the token from gh's output, never from or into an argument.
    func token() async throws -> String {
        guard let token = await environment.output("gh", ["auth", "token", "--hostname", "github.com"]), !token.isEmpty,
            !token.contains(where: { $0.isWhitespace })
        else { throw Self.notSignedIn }
        return token
    }
}
