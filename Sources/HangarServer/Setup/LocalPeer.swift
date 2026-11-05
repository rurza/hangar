import Darwin
import Foundation
import Hummingbird

/// Whether a request comes from the Mac the server runs on, judged by the socket's peer address only (never a
/// header): loopback, the bound address or one of this Mac's interface addresses. A browser on this Mac that
/// opens the server's tailnet name connects from this Mac's tailnet address, which is an interface address.
enum LocalPeer {
    static func isLocal(_ peer: String?, boundHost: String, interfaces: Set<String>) -> Bool {
        guard let peer = peer.map(normalize), !peer.isEmpty, peer != "unknown" else { return false }
        if peer == "::1" || peer.hasPrefix("127.") { return true }
        return peer == normalize(boundHost) || interfaces.map(normalize).contains(peer)
    }

    /// Lowercased, without an IPv6 zone (`%en0`), brackets or the IPv4-mapped prefix (`::ffff:`).
    static func normalize(_ address: String) -> String {
        var text = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:"), text.dropFirst(7).contains(".") { text = String(text.dropFirst(7)) }
        return text
    }

    /// Every IPv4 and IPv6 address of this Mac's interfaces (`getifaddrs`).
    static func interfaceAddresses() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            addresses.insert(normalize(text))
        }
        return addresses
    }
}

/// Marks a request that a reverse proxy relayed (`tailscale serve`, nginx, Caddy...). Such a proxy on this Mac
/// connects from loopback for every tailnet peer, so the peer address would make them all look local. A header can
/// only take the local privilege away, never grant it, so a client adding one gains nothing.
struct ProxyMark: RouterMiddleware {
    typealias Context = HangarRequestContext

    static let forwardingHeaders = [
        "Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Real-IP", "Tailscale-User-Login",
    ].map { HTTPFields.Element.Name($0)! }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard Self.forwardingHeaders.contains(where: { request.headers[$0] != nil }) else {
            return try await next(request, context)
        }
        var context = context
        context.relayedByProxy = true
        return try await next(request, context)
    }
}
