import Foundation
import HangarCore

/// The worker's side of the server's `/api/v1/worker` routes.
public protocol ServerConnection: Sendable {
    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse
    /// Long-polls for up to `wait` seconds; nil when nothing was assigned in that time.
    func nextJob(wait: Int) async throws -> JobAssignment?
    func start(jobID: UUID) async throws
    func step(jobID: UUID, _ update: StepUpdate) async throws
    /// The worker build and the Xcode the job runs with (`POST jobs/{id}/info`).
    func info(jobID: UUID, _ info: JobRunInfo) async throws
    func log(jobID: UUID, _ batch: LogBatch) async throws
    func uploadArtifact(jobID: UUID, name: String, fileURL: URL) async throws
    func finish(jobID: UUID, _ result: JobResult) async throws
}

/// One-job tokens (`POST`/`DELETE jobs/{id}/token`), which a job's VM uses instead of the machine token. Only the
/// machine token may issue or revoke them.
public protocol JobTokenIssuing: Sendable {
    func issueJobToken(jobID: UUID) async throws -> String
    func revokeJobToken(jobID: UUID) async throws
    /// What a VM archive's guest signs with: development profiles, or the optional development key when one is
    /// missing (`POST jobs/{id}/provisioning`, machine token only).
    func provisioning(jobID: UUID, _ request: JobProvisioningRequest) async throws -> JobProvisioning
}

public enum ServerConnectionError: Error, Equatable, CustomStringConvertible {
    /// The response body is never kept: the server's errors may echo what the worker sent.
    case status(Int, method: String, path: String)
    case notHTTP(path: String)

    public var description: String {
        switch self {
        case .status(let status, let method, let path): "\(method) \(path) answered HTTP \(status)"
        case .notHTTP(let path): "\(path) did not answer with an HTTP response"
        }
    }
}

/// `ServerConnection` over HTTP with the machine's bearer token on every request.
public struct HTTPServerConnection: ServerConnection, JobTokenIssuing {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    /// `baseURL` is the server's root, such as `http://mac-mini:8787`.
    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        let (data, _) = try await send("POST", "heartbeat", body: request)
        return try JSONCoding.decoder.decode(HeartbeatResponse.self, from: data)
    }

    public func nextJob(wait: Int) async throws -> JobAssignment? {
        // The server holds the request for up to `wait` seconds; the timeout must outlast that.
        let (data, status) = try await send(
            "GET", "jobs/next", query: [URLQueryItem(name: "wait", value: String(wait))],
            timeout: TimeInterval(wait + 30))
        guard status != 204 else { return nil }
        return try JSONCoding.decoder.decode(JobAssignment.self, from: data)
    }

    public func start(jobID: UUID) async throws {
        _ = try await send("POST", "jobs/\(jobID.uuidString)/start")
    }

    public func step(jobID: UUID, _ update: StepUpdate) async throws {
        _ = try await send("POST", "jobs/\(jobID.uuidString)/steps", body: update)
    }

    public func info(jobID: UUID, _ info: JobRunInfo) async throws {
        _ = try await send("POST", "jobs/\(jobID.uuidString)/info", body: info)
    }

    public func log(jobID: UUID, _ batch: LogBatch) async throws {
        _ = try await send("POST", "jobs/\(jobID.uuidString)/log", body: batch)
    }

    /// Streams the file from disk, so large archives are never held in memory.
    public func uploadArtifact(jobID: UUID, name: String, fileURL: URL) async throws {
        let path = "jobs/\(jobID.uuidString)/artifacts/\(Self.segment(name))"
        var request = request("POST", path)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        _ = try Self.check(response, method: "POST", path: path)
    }

    public func finish(jobID: UUID, _ result: JobResult) async throws {
        _ = try await send("POST", "jobs/\(jobID.uuidString)/finish", body: result)
    }

    public func issueJobToken(jobID: UUID) async throws -> String {
        let (data, _) = try await send("POST", "jobs/\(jobID.uuidString)/token")
        return try JSONCoding.decoder.decode(JobTokenResponse.self, from: data).token
    }

    public func revokeJobToken(jobID: UUID) async throws {
        _ = try await send("DELETE", "jobs/\(jobID.uuidString)/token")
    }

    public func provisioning(jobID: UUID, _ request: JobProvisioningRequest) async throws -> JobProvisioning {
        let (data, _) = try await send("POST", "jobs/\(jobID.uuidString)/provisioning", body: request)
        return try JSONCoding.decoder.decode(JobProvisioning.self, from: data)
    }

    // MARK: - Plumbing

    private struct Empty: Encodable {}

    private func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval? = nil
    ) async throws -> (Data, Int) {
        try await send(method, path, body: Empty?.none, query: query, timeout: timeout)
    }

    private func send<Body: Encodable>(
        _ method: String, _ path: String, body: Body?, query: [URLQueryItem] = [], timeout: TimeInterval? = nil
    ) async throws -> (Data, Int) {
        var request = request(method, path, query: query)
        if let timeout { request.timeoutInterval = timeout }
        if let body {
            request.httpBody = try JSONCoding.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return (data, try Self.check(response, method: method, path: path))
    }

    /// `path` is already percent-encoded (fixed words, UUIDs and `segment(_:)` output).
    private func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var root = components.percentEncodedPath
        while root.hasSuffix("/") { root.removeLast() }
        components.percentEncodedPath = root + "/api/v1/worker/" + path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url ?? baseURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse, method: String, path: String) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw ServerConnectionError.notHTTP(path: path) }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerConnectionError.status(http.statusCode, method: method, path: path)
        }
        return http.statusCode
    }

    /// One path segment: anything but unreserved characters is percent-encoded, so a name cannot add segments.
    private static func segment(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }
}
