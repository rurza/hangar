import Foundation
import HangarCore

/// A tailnet device as Tailscale's `whois` describes it.
public struct TailnetPeer: Sendable, Equatable {
    /// The Tailscale login that owns the device, e.g. `alice@github`. A tagged device has none of its own.
    public var loginName: String
    /// The device's MagicDNS name, without the trailing dot.
    public var nodeName: String
    /// The device carries ACL tags: it belongs to the tailnet, not to a person, so it is never the owner.
    public var tagged: Bool

    public init(loginName: String, nodeName: String, tagged: Bool) {
        self.loginName = loginName
        self.nodeName = nodeName
        self.tagged = tagged
    }
}

/// Who a tailnet address belongs to, and who this server's own node belongs to.
public protocol TailnetIdentifying: Sendable {
    /// The device behind `address` (an IP, no port); nil when Tailscale does not know it or is not running.
    func whois(_ address: String) async -> TailnetPeer?
    /// This Mac's own node; nil when Tailscale is not running.
    func selfNode() async -> TailnetPeer?
}

/// `TailnetIdentifying` through the Tailscale CLI, which asks the local daemon (its LocalAPI): `tailscale whois
/// --json` and `tailscale status --json`. Tries the CLIs `TailscaleAddress` tries, in the same order.
public struct TailscaleCLI: TailnetIdentifying {
    let runner: any ProcessRunner
    let fileExists: @Sendable (String) -> Bool

    public init(
        runner: any ProcessRunner = LiveProcessRunner(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.runner = runner
        self.fileExists = fileExists
    }

    public func whois(_ address: String) async -> TailnetPeer? {
        guard let output = await run(["whois", "--json", address]) else { return nil }
        return Self.parseWhois(output)
    }

    public func selfNode() async -> TailnetPeer? {
        guard let output = await run(["status", "--json"]) else { return nil }
        return Self.parseStatus(output)
    }

    /// The first CLI that exits 0; its stdout only.
    private func run(_ arguments: [String]) async -> String? {
        for executable in TailscaleAddress.candidates {
            if executable.hasPrefix("/") && !fileExists(executable) { continue }
            let command = ProcessCommand(executable: executable, arguments: arguments, discardsStandardError: true)
            guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0 else { continue }
            return outcome.output
        }
        return nil
    }

    static func parseWhois(_ json: String) -> TailnetPeer? {
        struct WhoIs: Decodable {
            struct Node: Decodable {
                var Name: String?
                var Tags: [String]?
            }
            struct Profile: Decodable { var LoginName: String? }
            var Node: Node?
            var UserProfile: Profile?
        }
        guard let whois = try? JSONDecoder().decode(WhoIs.self, from: Data(json.utf8)),
            let login = whois.UserProfile?.LoginName, !login.isEmpty
        else { return nil }
        return TailnetPeer(
            loginName: login, nodeName: HostName.normalize(whois.Node?.Name ?? ""),
            tagged: !(whois.Node?.Tags ?? []).isEmpty)
    }

    static func parseStatus(_ json: String) -> TailnetPeer? {
        struct Status: Decodable {
            struct Node: Decodable {
                var DNSName: String?
                var UserID: Int64?
                var Tags: [String]?
            }
            struct Profile: Decodable { var LoginName: String? }
            var `Self`: Node?
            var User: [String: Profile]?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: Data(json.utf8)), let node = status.Self,
            let userID = node.UserID, let login = status.User?[String(userID)]?.LoginName, !login.isEmpty
        else { return nil }
        return TailnetPeer(
            loginName: login, nodeName: HostName.normalize(node.DNSName ?? ""), tagged: !(node.Tags ?? []).isEmpty)
    }
}
