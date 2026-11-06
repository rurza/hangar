import Foundation

/// `GET /access`: who is asking, and which Tailscale logins count as the owner.
public struct AccessStatus: Codable, Equatable, Sendable {
    /// The owner's login when the request came from their tailnet device; nil for a request made with a token.
    public var viewerLogin: String?
    /// The token's name when the request carried an `owner` API token.
    public var viewerToken: String?
    /// The logins treated as the owner right now.
    public var allowedLogins: [String]
    /// True when `allowedLogins` was set (`PUT /access`); false when it is the server node's own login.
    public var configured: Bool
    /// The login that owns this server's tailnet node: the default owner. Nil when Tailscale is not running.
    public var serverNodeLogin: String?
    /// The server's tailnet node is tagged: it has no owner of its own, so the logins must be set.
    public var serverNodeTagged: Bool

    public init(
        viewerLogin: String?, viewerToken: String?, allowedLogins: [String], configured: Bool, serverNodeLogin: String?,
        serverNodeTagged: Bool
    ) {
        self.viewerLogin = viewerLogin
        self.viewerToken = viewerToken
        self.allowedLogins = allowedLogins
        self.configured = configured
        self.serverNodeLogin = serverNodeLogin
        self.serverNodeTagged = serverNodeTagged
    }
}

/// `PUT /access`: the Tailscale logins treated as the owner; empty goes back to the server node's own login.
public struct AccessUpdate: Codable, Equatable, Sendable {
    public var allowedLogins: [String]

    public init(allowedLogins: [String]) { self.allowedLogins = allowedLogins }
}
