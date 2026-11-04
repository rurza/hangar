import Foundation
import Hummingbird

/// Parsing and comparing the host part of `Host` headers and origins.
enum HostName {
    /// Splits `host[:port]` or `[v6][:port]` into a normalized host and the port; nil when it is malformed.
    static func split(_ authority: String) -> (host: String, port: Int?)? {
        let text = authority.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (normalize(host), nil) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (normalize(host), port)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (normalize(text), nil)
        case 2:
            guard let port = Int(parts[1]) else { return nil }
            return (normalize(String(parts[0])), port)
        default: return (normalize(text), nil)  // A bare IPv6 address.
        }
    }

    /// Lower-cased, without IPv6 brackets or a trailing dot.
    static func normalize(_ host: String) -> String {
        var host = host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }
}

extension Request {
    /// The Host header (HTTP/1, which swift-http-types moves into `authority`) or `:authority` (HTTP/2).
    var authority: String? { head.authority }
}
