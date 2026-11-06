import Foundation
import HangarCore

/// Where the CLI and `hangar mcp` find the API token they send, first match wins:
/// 1. `HANGAR_API_TOKEN`;
/// 2. the file named by `HANGAR_API_TOKEN_FILE`;
/// 3. `$XDG_CONFIG_HOME/hangar/token`, else `~/.config/hangar/token` (the CLI only: `hangar mcp` never reads the
///    owner's own file, so an agent cannot pick up an owner token by accident).
///
/// No command takes the token as an argument, so it never lands in shell history or `ps`. Without one, requests go
/// out bare: the server then lets in only the owner's tailnet devices.
public enum APITokenSource {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        /// The value found is not an `hgr_…` token; `source` says where it came from.
        case malformed(source: String)
        /// `HANGAR_API_TOKEN_FILE` names a file that cannot be read.
        case unreadable(path: String)

        public var description: String {
            switch self {
            case .malformed(let source): "\(source) does not hold a Hangar API token (they start with hgr_)."
            case .unreadable(let path): "cannot read the API token file \(path) (HANGAR_API_TOKEN_FILE)."
            }
        }
    }

    /// The default token file for `environment` (`HOME`, `XDG_CONFIG_HOME`).
    public static func defaultFile(environment: [String: String]) -> String {
        if let config = environment["XDG_CONFIG_HOME"], !config.isEmpty { return config + "/hangar/token" }
        return (environment["HOME"] ?? NSHomeDirectory()) + "/.config/hangar/token"
    }

    /// The token, nil when none is configured. `readFile` returns a file's text, nil when it does not exist or
    /// cannot be read.
    public static func resolve(
        environment: [String: String], includeDefaultFile: Bool = true,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) throws(Problem) -> String? {
        if let value = environment["HANGAR_API_TOKEN"].map(trim), !value.isEmpty {
            guard APIToken.isWellFormedSecret(value) else { throw .malformed(source: "HANGAR_API_TOKEN") }
            return value
        }
        if let path = environment["HANGAR_API_TOKEN_FILE"].map(trim), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard let text = readFile(expanded) else { throw .unreadable(path: expanded) }
            let value = trim(text)
            guard APIToken.isWellFormedSecret(value) else { throw .malformed(source: expanded) }
            return value
        }
        guard includeDefaultFile else { return nil }
        let file = defaultFile(environment: environment)
        guard let text = readFile(file) else { return nil }
        let value = trim(text)
        if value.isEmpty { return nil }
        guard APIToken.isWellFormedSecret(value) else { throw .malformed(source: file) }
        return value
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
