import Foundation
import Synchronization

/// Seam over HTTP so clients can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public struct NonHTTPResponse: Error {}

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NonHTTPResponse() }
        return (data, http)
    }
}

/// Test double for `HTTPTransport`: answers with the queued responses in order and records every request.
/// Lives here (not in a test target) so every test target can use it.
public final class StubTransport: HTTPTransport {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var headers: [String: String]

        public init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        public init(status: Int = 200, body: String, headers: [String: String] = [:]) {
            self.init(status: status, body: Data(body.utf8), headers: headers)
        }
    }

    public struct OutOfResponses: Error, CustomStringConvertible {
        public let request: String
        public var description: String { "StubTransport has no queued response left for \(request)" }
    }

    private struct State {
        var responses: [Response]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    public init(responses: [Response] = []) {
        state = Mutex(State(responses: responses))
    }

    public func enqueue(_ response: Response) {
        state.withLock { $0.responses.append(response) }
    }

    public var requests: [URLRequest] { state.withLock { $0.requests } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try state.withLock { state -> Response in
            state.requests.append(request)
            guard !state.responses.isEmpty else {
                throw OutOfResponses(request: "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "?")")
            }
            return state.responses.removeFirst()
        }
        let url = request.url ?? URL(string: "about:blank")!
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }
}
