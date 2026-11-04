import Foundation
import HangarCore
import Hummingbird

/// Which `Host` values the server answers. A DNS-rebinding page reaches the server under the attacker's own name,
/// so a request whose Host is not one of this Mac's names is refused.
///
/// Allowed: the bound host; `localhost`, `127.0.0.1` and `::1` when bound to loopback or to every interface; any
/// `*.ts.net` name (MagicDNS); and the extra names (this Mac's host names, its MagicDNS name, `--allowed-host`).
/// The port is not compared. Names compare case-insensitively, without a trailing dot or IPv6 brackets.
public struct HostPolicy: Sendable, Equatable {
    public static let loopbackNames = ["localhost", "127.0.0.1", "::1"]
    static let wildcardHosts: Set<String> = ["0.0.0.0", "::"]

    /// The exact names allowed, normalized and sorted; `*.ts.net` is allowed on top of these.
    public let names: [String]

    public init(boundHost: String, extraNames: [String] = []) {
        let bound = HostName.normalize(boundHost)
        var names: Set<String> = [bound]
        if Self.isLoopback(bound) || Self.wildcardHosts.contains(bound) { names.formUnion(Self.loopbackNames) }
        for name in extraNames.map(HostName.normalize) where !name.isEmpty { names.insert(name) }
        self.names = names.sorted()
    }

    /// True when the `Host` (or HTTP/2 `:authority`) value names this server. A missing Host is refused.
    public func allows(authority: String?) -> Bool {
        guard let authority, let host = HostName.split(authority)?.host, !host.isEmpty else { return false }
        return names.contains(host) || host.hasSuffix(".ts.net")
    }

    /// The names for the start-up log: the exact names, then the `*.ts.net` rule.
    public var description: String { (names + ["*.ts.net"]).joined(separator: ", ") }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    // MARK: - This Mac's names

    /// This Mac's short host name, its Bonjour local host name and its MagicDNS name, each best effort: what cannot
    /// be found is left out.
    public static func detectLocalNames(
        runner: any ProcessRunner, hostName: String = Self.systemHostName(),
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) async -> [String] {
        var names: [String] = []
        if let short = shortName(hostName) { names.append(short) }
        let scutil = ProcessCommand(executable: "/usr/sbin/scutil", arguments: ["--get", "LocalHostName"])
        if let outcome = try? await runner.run(scutil, onLine: { _ in }), outcome.exitCode == 0,
            let local = shortName(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            names.append(local)
        }
        if let magicDNS = await magicDNSName(runner: runner, fileExists: fileExists) { names.append(magicDNS) }
        var seen = Set<String>()
        return names.map(HostName.normalize).filter { seen.insert($0).inserted }
    }

    /// The first label of a host name, nil when empty.
    static func shortName(_ hostName: String) -> String? {
        let label = hostName.split(separator: ".").first.map(String.init) ?? ""
        return label.isEmpty ? nil : label
    }

    /// `gethostname(3)`: cheap, unlike `ProcessInfo.hostName`, which may wait on reverse DNS.
    public static func systemHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// `Self.DNSName` from `tailscale status --json`, trying the CLIs `TailscaleAddress` tries; nil when none answers.
    static func magicDNSName(runner: any ProcessRunner, fileExists: @Sendable (String) -> Bool) async -> String? {
        struct Status: Decodable {
            struct Node: Decodable { var DNSName: String? }
            var `Self`: Node?
        }
        for executable in TailscaleAddress.candidates {
            if executable.hasPrefix("/") && !fileExists(executable) { continue }
            let command = ProcessCommand(executable: executable, arguments: ["status", "--json"])
            guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0,
                let status = try? JSONDecoder().decode(Status.self, from: Data(outcome.output.utf8))
            else { continue }
            let name = HostName.normalize(status.Self?.DNSName ?? "")
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

/// Refuses every request whose Host is not allowed with 421 `host_not_allowed`: UI, API and worker routes alike.
struct HostCheck: RouterMiddleware {
    typealias Context = HangarRequestContext

    let policy: HostPolicy

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard policy.allows(authority: request.authority) else {
            throw APIError(
                code: "host_not_allowed",
                message: "This server does not answer to that host name. Add it with --allowed-host if it is yours.")
        }
        return try await next(request, context)
    }
}
