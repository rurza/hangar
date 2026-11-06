import Foundation
import HangarCore
import Synchronization

/// Whether a request's socket peer is the owner's device. `OwnerAccess` in production; tests stand in for it, since
/// the router test client has no peer address.
public protocol OwnerIdentifying: Sendable {
    /// The owner's login when `address` (no port) is one of the owner's devices, else nil.
    func owner(peer address: String?) async -> String?
}

/// Decides whether a request comes from the owner: a tailnet device whose Tailscale login is one of the allowed
/// logins. By default that is the login that owns this server's own node; `ServerSettingsRepository` key
/// `owner_logins` (a JSON array, set with `PUT /access` or `hangar-server access allow`) replaces the default.
///
/// Only the socket's peer address counts, never a header. Loopback, LAN and unknown addresses are never the owner:
/// host-executor builds and local agents connect from there. A tagged device is never the owner, whatever login
/// Tailscale reports for it. `whois` answers are cached briefly, so most requests spawn nothing.
public final class OwnerAccess: OwnerIdentifying {
    public static let settingKey = "owner_logins"
    /// How long a `whois` answer is reused: a known device, then an unknown address.
    static let knownTTL: TimeInterval = 60
    static let unknownTTL: TimeInterval = 10
    /// How long before a failed look at this server's own node is retried (Tailscale was not up yet).
    static let selfRetry: TimeInterval = 30
    static let maxCachedPeers = 256

    let tailnet: any TailnetIdentifying
    let settings: ServerSettingsRepository
    let now: @Sendable () -> Date
    private let peers = Mutex<[String: CachedPeer]>([:])
    private let node = Mutex<CachedPeer?>(nil)

    private struct CachedPeer: Sendable {
        var peer: TailnetPeer?
        var at: Date
    }

    public init(tailnet: any TailnetIdentifying, settings: ServerSettingsRepository, now: @escaping @Sendable () -> Date = Date.init) {
        self.tailnet = tailnet
        self.settings = settings
        self.now = now
    }

    /// The owner's login when `address` (the socket peer, no port) is one of the owner's tailnet devices, else nil.
    public func owner(peer address: String?) async -> String? {
        guard let address = address.map(LocalPeer.normalize), Self.isTailnetAddress(address),
            let peer = await peer(address), !peer.tagged
        else { return nil }
        let allowed = await allowedLogins().map { $0.lowercased() }
        return allowed.contains(peer.loginName.lowercased()) ? peer.loginName : nil
    }

    /// The logins treated as the owner: the configured ones, else the server node's own login (none when the node is
    /// tagged or Tailscale is not running).
    public func allowedLogins() async -> [String] {
        if let configured = configuredLogins() { return configured }
        return await defaultLogins()
    }

    /// The server node's login, the default owner; empty when the node is tagged or unknown.
    public func defaultLogins() async -> [String] {
        guard let node = await serverNode(), !node.tagged else { return [] }
        return [node.loginName]
    }

    /// The configured logins; nil when none are set (the default applies). An unreadable setting counts as none
    /// configured rather than locking the owner out.
    public func configuredLogins() -> [String]? {
        guard let text = try? settings.value(Self.settingKey),
            let logins = try? JSONDecoder().decode([String].self, from: Data(text.utf8)), !logins.isEmpty
        else { return nil }
        return logins
    }

    /// Replaces the allowed logins; nil or empty goes back to the default (the server node's login).
    public func setConfiguredLogins(_ logins: [String]?) throws {
        let cleaned = try Self.validate(logins ?? [])
        if cleaned.isEmpty {
            try settings.set(Self.settingKey, nil)
        } else {
            try settings.set(Self.settingKey, String(decoding: try JSONEncoder().encode(cleaned), as: UTF8.self))
        }
    }

    /// Trimmed, de-duplicated (case-insensitively) logins; 400 for an empty or malformed one.
    public static func validate(_ logins: [String]) throws -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in logins {
            let login = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !login.isEmpty, login.count <= 256, !login.contains(where: { $0.isWhitespace || $0 == "," }) else {
                throw APIError(code: "invalid_login", message: "'\(raw)' is not a Tailscale login such as alice@github.")
            }
            if seen.insert(login.lowercased()).inserted { cleaned.append(login) }
        }
        return cleaned
    }

    /// This server's own node, cached for the process's life once known.
    public func serverNode() async -> TailnetPeer? {
        let now = now()
        if let cached = node.withLock({ $0 }), cached.peer != nil || now.timeIntervalSince(cached.at) < Self.selfRetry {
            return cached.peer
        }
        let peer = await tailnet.selfNode()
        node.withLock { $0 = CachedPeer(peer: peer, at: now) }
        return peer
    }

    private func peer(_ address: String) async -> TailnetPeer? {
        let now = now()
        if let cached = peers.withLock({ $0[address] }) {
            let ttl = cached.peer == nil ? Self.unknownTTL : Self.knownTTL
            if now.timeIntervalSince(cached.at) < ttl { return cached.peer }
        }
        let peer = await tailnet.whois(address)
        peers.withLock { cache in
            if cache.count >= Self.maxCachedPeers { cache.removeAll() }
            cache[address] = CachedPeer(peer: peer, at: now)
        }
        return peer
    }

    /// Tailscale's address ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48. Nothing else is looked up.
    static func isTailnetAddress(_ address: String) -> Bool {
        if address.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let octets = Optional(parts.compactMap { UInt8($0) }), octets.count == 4 else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}
