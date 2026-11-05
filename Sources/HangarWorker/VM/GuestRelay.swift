import Foundation
import HangarCore
import Network
import Synchronization

/// The guest's only way to the Hangar server (VM builds design, *The relay*). The worker listens on a loopback port
/// of the host; the job's SSH session forwards the guest's `127.0.0.1:8787` to it (`ssh -R`), so the guest's server
/// URL is `http://127.0.0.1:8787` and it never learns the server's address.
///
/// Each connection carries one request. Its head is checked before a byte goes on: a `POST` to one of the job's own
/// worker routes, with the job's token, and a `Content-Length` body (no chunked uploads, so the request ends where
/// the relay says). The head is rewritten for the server (its `Host`, its path prefix, `Connection: close`), exactly
/// `Content-Length` bytes of body follow, and the answer streams back until the server closes. Anything else gets a
/// 403 and never reaches the server. The server scopes the token as well; this is the second lock.
public final class GuestRelay: Sendable {
    public struct Rule: Sendable, Equatable {
        public var jobID: UUID
        public var token: String

        public init(jobID: UUID, token: String) {
            self.jobID = jobID
            self.token = token
        }
    }

    private let rule: Rule
    private let server: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.hangar.vm.relay")
    private let ready = Mutex<CheckedContinuation<UInt16, any Error>?>(nil)

    /// Listens on 127.0.0.1 at a free port; `start()` returns it.
    public init(rule: Rule, server: URL) throws {
        self.rule = rule
        self.server = server
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; returns the port.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.resumeReady(.success(self.listener.port?.rawValue ?? 0))
                case .failed(let error): self.resumeReady(.failure(error))
                case .cancelled: self.resumeReady(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    private func resumeReady(_ result: Result<UInt16, any Error>) {
        ready.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    // MARK: One connection

    static let maximumHead = 16 * 1024

    private func handle(_ guest: NWConnection) {
        guest.start(queue: queue)
        readHead(guest, buffer: Data())
    }

    private func readHead(_ guest: NWConnection, buffer: Data) {
        guest.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = buffer[end.upperBound...]
                switch Self.check(head: head, rule: rule, server: server) {
                case .forward(let rewritten, let length): forward(guest, head: rewritten, body: Data(rest), length: length)
                case .refuse(let status, let message): refuse(guest, status: status, message: message)
                }
            } else if buffer.count > Self.maximumHead {
                refuse(guest, status: 431, message: "request head too large")
            } else if complete || error != nil {
                guest.cancel()
            } else {
                readHead(guest, buffer: buffer)
            }
        }
    }

    private func refuse(_ guest: NWConnection, status: Int, message: String) {
        let body = #"{"error":{"code":"relay_refused","message":"\#(message)"}}"#
        let reason = status == 403 ? "Forbidden" : status == 411 ? "Length Required" : "Bad Request"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        guest.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            guest.cancel()
        })
    }

    private func forward(_ guest: NWConnection, head: String, body: Data, length: Int) {
        let host = NWEndpoint.Host(server.host ?? "127.0.0.1")
        let secure = server.scheme == "https"
        let port = NWEndpoint.Port(rawValue: UInt16(server.port ?? (secure ? 443 : 80))) ?? .http
        let upstream = NWConnection(host: host, port: port, using: secure ? .tls : .tcp)
        upstream.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: guest.cancel()
            default: break
            }
        }
        upstream.start(queue: queue)
        let first = body.prefix(length)
        upstream.send(content: Data(head.utf8) + first, completion: .contentProcessed { _ in })
        pumpBody(from: guest, to: upstream, remaining: length - first.count)
        pumpAnswer(from: upstream, to: guest)
    }

    /// Exactly `remaining` more bytes from the guest; anything after them is never read.
    private func pumpBody(from guest: NWConnection, to upstream: NWConnection, remaining: Int) {
        guard remaining > 0 else { return }
        guest.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1 << 20)) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                let chunk = data.prefix(remaining)
                upstream.send(content: chunk, completion: .contentProcessed { [self] _ in
                    pumpBody(from: guest, to: upstream, remaining: remaining - chunk.count)
                })
            } else if complete || error != nil {
                upstream.cancel()
            } else {
                pumpBody(from: guest, to: upstream, remaining: remaining)
            }
        }
    }

    private func pumpAnswer(from upstream: NWConnection, to guest: NWConnection) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                guest.send(content: data, completion: .contentProcessed { [self] _ in
                    if complete || error != nil {
                        finish(guest, upstream)
                    } else {
                        pumpAnswer(from: upstream, to: guest)
                    }
                })
            } else if complete || error != nil {
                finish(guest, upstream)
            } else {
                pumpAnswer(from: upstream, to: guest)
            }
        }
    }

    private func finish(_ guest: NWConnection, _ upstream: NWConnection) {
        upstream.cancel()
        guest.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            guest.cancel()
        })
    }

    // MARK: The check

    public enum Decision: Equatable, Sendable {
        /// The head to send upstream, and the body's length.
        case forward(head: String, bodyLength: Int)
        case refuse(status: Int, message: String)
    }

    /// The job routes a VM may call, after `/api/v1/worker/jobs/<id>/`.
    static let allowedRoutes: Set<String> = ["start", "info", "steps", "log", "finish"]

    /// Decides one request head (without the final blank line).
    public static func check(head: String, rule: Rule, server: URL) -> Decision {
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .refuse(status: 400, message: "not an HTTP/1.1 request")
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                return .refuse(status: 400, message: "malformed header")
            }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        func values(_ name: String) -> [String] { headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value) }

        guard method == "POST", isAllowed(path: target, jobID: rule.jobID) else {
            return .refuse(status: 403, message: "only this job's worker routes are reachable from its VM")
        }
        let authorization = values("Authorization")
        guard authorization.count == 1, constantTimeEquals(authorization[0], "Bearer " + rule.token) else {
            return .refuse(status: 403, message: "the request does not carry this job's token")
        }
        guard values("Transfer-Encoding").isEmpty else {
            return .refuse(status: 411, message: "chunked bodies are not relayed; send a Content-Length")
        }
        let lengths = values("Content-Length")
        guard lengths.count <= 1, let length = lengths.isEmpty ? 0 : Int(lengths[0]), length >= 0 else {
            return .refuse(status: 400, message: "invalid Content-Length")
        }

        var root = server.path
        while root.hasSuffix("/") { root.removeLast() }
        let authority = server.port.map { "\(server.host ?? ""):\($0)" } ?? (server.host ?? "")
        let dropped: Set<String> = ["host", "connection", "keep-alive", "proxy-connection", "proxy-authorization", "upgrade"]
        var rewritten = ["\(method) \(root)\(target) HTTP/1.1", "Host: \(authority)"]
        rewritten += headers.filter { !dropped.contains($0.name.lowercased()) }.map { "\($0.name): \($0.value)" }
        rewritten.append("Connection: close")
        return .forward(head: rewritten.joined(separator: "\r\n") + "\r\n\r\n", bodyLength: length)
    }

    /// `/api/v1/worker/jobs/<id>/<route>` or `…/artifacts/<one segment>`; no query, no dot segments.
    static func isAllowed(path: String, jobID: UUID) -> Bool {
        let prefix = "/api/v1/worker/jobs/"
        guard path.hasPrefix(prefix), !path.contains("?"), !path.contains("#") else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let id = parts.first.flatMap(UUID.init(uuidString:)), id == jobID else { return false }
        switch parts.count {
        case 2: return allowedRoutes.contains(parts[1])
        case 3: return parts[1] == "artifacts" && !parts[2].isEmpty && parts[2] != "." && parts[2] != ".."
        default: return false
        }
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
