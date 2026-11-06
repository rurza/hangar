import Foundation
import HangarCore
import Hummingbird

/// Authenticates every public route under `/api/v1`. A request is one of:
/// - **an API token** (`Authorization: Bearer hgr_…`): an unknown or revoked one is 401 `invalid_api_token`, a route
///   outside its scope 403 `token_scope`. An `owner` token may call every route;
/// - **the owner**: no token, from a tailnet device whose Tailscale login is allowed (`OwnerAccess`);
/// - anything else is 401 `authentication_required`: loopback, the LAN, other tailnet users, tagged devices, and
///   every caller while Tailscale is not running.
///
/// Open without either: `GET /health`, and `POST /enroll`, which a pairing code authenticates. The worker routes keep
/// their machine and job tokens (`MachineAuth`).
struct Authentication: RouterMiddleware {
    typealias Context = HangarRequestContext

    let tokens: APITokenRepository
    let owners: any OwnerIdentifying
    let now: @Sendable () -> Date

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        guard path.hasPrefix(Self.apiPrefix), !path.hasPrefix(CrossSiteGuard.workerPrefix) else {
            return try await next(request, context)
        }
        let relative = String(path.dropFirst(Self.apiPrefix.count))
        if Self.isOpen(method: request.method, path: relative) { return try await next(request, context) }
        var context = context
        if let secret = Self.bearerAPIToken(request) {
            context.apiToken = try authorize(secret: secret, method: request.method, path: relative)
            if request.method != .get && request.method != .head {
                context.logger.info("\(request.method) \(path) by API token '\(context.apiToken!.name)'")
            }
            return try await next(request, context)
        }
        // A proxy on this Mac connects from loopback for every peer, so a relayed request is never the owner's.
        guard !context.relayedByProxy, let login = await owners.owner(peer: context.remoteAddress?.ipAddress) else {
            throw Self.required
        }
        context.ownerLogin = login
        return try await next(request, context)
    }

    private func authorize(secret: String, method: HTTPRequest.Method, path: String) throws -> APIToken {
        guard let token = try tokens.authenticate(secret: secret, now: now()) else { throw Self.invalid }
        if token.scope == .owner { return token }
        switch APITokenPolicy.required(method: method, path: path) {
        case .some(let required) where token.scope.includes(required):
            return token
        case .some(let required):
            throw APIError(
                code: "token_scope",
                message: "The API token '\(token.name)' has scope '\(token.scope.rawValue)'; this needs '\(required.rawValue)'.")
        case nil:
            throw APIError(code: "token_scope", message: "API tokens cannot call \(method) /api/v1/\(path).")
        }
    }

    static let apiPrefix = "/api/v1/"
    static let invalid = APIError(code: "invalid_api_token", message: "The API token is unknown or was revoked.")
    static let required = APIError(
        code: "authentication_required",
        message: """
            Hangar answers only its owner's tailnet devices and API tokens. Open it from one of your devices signed in \
            to Tailscale, or send an API token (HANGAR_API_TOKEN); on the server Mac, hangar-server token create makes one.
            """)

    /// Routes anyone may call: the version, and enrolling a Mac with a pairing code.
    static func isOpen(method: HTTPRequest.Method, path: String) -> Bool {
        switch (method, path) {
        case (.get, "health"), (.head, "health"), (.post, "enroll"): true
        default: false
        }
    }

    /// The bearer value when it is an API token (`hgr_…`); other bearer values are ignored.
    static func bearerAPIToken(_ request: Request) -> String? {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else { return nil }
        let value = header.dropFirst("Bearer ".count).trimmingCharacters(in: .whitespaces)
        return value.hasPrefix(APIToken.secretPrefix) ? value : nil
    }
}

extension HangarRequestContext {
    /// The owner: through Tailscale, or with an `owner` API token.
    var isOwner: Bool { ownerLogin != nil || apiToken?.scope == .owner }

    /// 403 `owner_only` unless the owner makes the request; for what a scoped token may never do, within a route
    /// tokens may otherwise call.
    func requireOwner(_ what: String) throws {
        guard isOwner else { throw APIError(code: "owner_only", message: "Only the owner can \(what).") }
    }
}

/// Which scope each public route needs from an API token; nil means no scoped token may call it (an `owner` token
/// may). `APITokenPolicyTests` pins a decision for every route the router has.
enum APITokenPolicy {
    /// `path` is relative to `/api/v1/`, without a query.
    static func required(method: HTTPRequest.Method, path: String) -> APITokenScope? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        // Never: secrets, this Mac, machines, access and the tokens themselves.
        if first == "setup" && parts.count > 1 { return nil }
        if first == "access" { return nil }
        if first == "api-tokens" { return method == .get && parts == ["api-tokens", "current"] ? .read : nil }
        if method == .get || method == .head { return .read }
        switch (method, parts.count, first) {
        case (.post, 1, "builds"): return .deploy
        case (.post, 3, "builds") where parts[2] == "cancel": return .deploy
        // Adding an app picks the repository whose scripts get the secrets: the owner's call (security review M3).
        case (.delete, 2, "apps"): return .configure
        case (.put, 3, "apps") where parts[2] == "workflow-file": return .configure
        case (.delete, 3, "apps") where parts[2] == "workflow-file": return .configure
        case (.post, 3, "apps") where parts[2] == "beta-groups": return .configure
        case (.put, 4, "apps") where parts[2] == "numbers" && parts[3] == "next": return .configure
        default: return nil
        }
    }
}
