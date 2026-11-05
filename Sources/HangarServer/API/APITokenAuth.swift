import Foundation
import HangarCore
import Hummingbird

/// Checks `Authorization: Bearer hgr_…` on the public routes: an unknown or revoked token is 401
/// `invalid_api_token` (never the open API instead), a route outside the token's scope 403 `token_scope`. Requests
/// without an API token pass unchanged, as before tokens existed; the worker routes keep their machine tokens.
struct APITokenAuth: RouterMiddleware {
    typealias Context = HangarRequestContext

    let tokens: APITokenRepository
    let now: @Sendable () -> Date

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard !request.uri.path.hasPrefix(CrossSiteGuard.workerPrefix), let secret = Self.bearerAPIToken(request) else {
            return try await next(request, context)
        }
        guard let token = try tokens.authenticate(secret: secret, now: now()) else { throw Self.invalid }
        let path = String(request.uri.path.dropFirst(Self.apiPrefix.count))
        switch APITokenPolicy.required(method: request.method, path: path) {
        case .some(let required) where token.scope.includes(required):
            break
        case .some(let required):
            throw APIError(
                code: "token_scope",
                message: "The API token '\(token.name)' has scope '\(token.scope.rawValue)'; this needs '\(required.rawValue)'.")
        case nil:
            throw APIError(code: "token_scope", message: "API tokens cannot call \(request.method) /api/v1/\(path).")
        }
        if request.method != .get && request.method != .head {
            context.logger.info("\(request.method) \(request.uri.path) by API token '\(token.name)'")
        }
        var context = context
        context.apiToken = token
        return try await next(request, context)
    }

    static let apiPrefix = "/api/v1/"
    static let invalid = APIError(code: "invalid_api_token", message: "The API token is unknown or was revoked.")

    /// The bearer value when it is an API token (`hgr_…`); other bearer values are ignored, as before tokens.
    static func bearerAPIToken(_ request: Request) -> String? {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else { return nil }
        let value = header.dropFirst("Bearer ".count).trimmingCharacters(in: .whitespaces)
        return value.hasPrefix(APIToken.secretPrefix) ? value : nil
    }
}

/// Which scope each public route needs from an API token; nil means no token may call it.
enum APITokenPolicy {
    /// `path` is relative to `/api/v1/`, without a query.
    static func required(method: HTTPRequest.Method, path: String) -> APITokenScope? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        // Never: secrets, this Mac, machines and the tokens themselves.
        if first == "setup" && parts.count > 1 { return nil }
        if first == "api-tokens" { return method == .get && parts == ["api-tokens", "current"] ? .read : nil }
        if method == .get || method == .head { return .read }
        switch (method, parts.count, first) {
        case (.post, 1, "builds"): return .deploy
        case (.post, 3, "builds") where parts[2] == "cancel": return .deploy
        case (.post, 1, "apps"): return .configure
        case (.delete, 2, "apps"): return .configure
        case (.put, 3, "apps") where parts[2] == "workflow-file": return .configure
        case (.delete, 3, "apps") where parts[2] == "workflow-file": return .configure
        case (.post, 3, "apps") where parts[2] == "beta-groups": return .configure
        case (.put, 4, "apps") where parts[2] == "numbers" && parts[3] == "next": return .configure
        default: return nil
        }
    }
}

