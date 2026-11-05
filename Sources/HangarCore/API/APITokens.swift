import Foundation

/// What an API token may do. Scopes nest: `configure` includes `deploy`, which includes `read`.
public enum APITokenScope: String, Codable, Sendable, CaseIterable, Comparable {
    /// Every `GET` but the local-only setup routes and the token routes.
    case read
    /// Also start and cancel builds.
    case deploy
    /// Also add and delete apps, store or clear workflow files, create TestFlight groups and set the next number.
    case configure

    private var rank: Int {
        switch self {
        case .read: 0
        case .deploy: 1
        case .configure: 2
        }
    }

    public static func < (lhs: APITokenScope, rhs: APITokenScope) -> Bool { lhs.rank < rhs.rank }

    /// True when a token of this scope may call a route that needs `required`.
    public func includes(_ required: APITokenScope) -> Bool { required <= self }
}

/// An API token as the server lists it; the secret itself is never stored or returned after creation.
public struct APIToken: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var scope: APITokenScope
    /// The first characters of the secret (`hgr_AbCd`), to tell tokens apart.
    public var prefix: String
    public var createdAt: Date
    /// When a request last used it (updated at most once a minute); nil when never used.
    public var lastUsedAt: Date?

    public init(id: UUID, name: String, scope: APITokenScope, prefix: String, createdAt: Date, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.scope = scope
        self.prefix = prefix
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Every token starts with this, so a request can tell one from a machine token.
    public static let secretPrefix = "hgr_"

    /// True when `text` looks like an API token secret: the prefix and 43 base64url characters.
    public static func isWellFormedSecret(_ text: String) -> Bool {
        guard text.hasPrefix(secretPrefix) else { return false }
        let body = text.dropFirst(secretPrefix.count)
        return body.count == 43 && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// `POST /api-tokens`.
public struct CreateAPITokenRequest: Codable, Equatable, Sendable {
    public var name: String
    public var scope: APITokenScope

    public init(name: String, scope: APITokenScope) {
        self.name = name
        self.scope = scope
    }
}

/// `POST /api-tokens`: the only response that carries the secret.
public struct CreateAPITokenResponse: Codable, Equatable, Sendable {
    public var token: APIToken
    public var secret: String

    public init(token: APIToken, secret: String) {
        self.token = token
        self.secret = secret
    }
}
