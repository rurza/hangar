import Foundation
import HangarCore

/// An event stream that ended without its closing event, such as a dropped connection.
public struct StreamClosed: Error, CustomStringConvertible {
    public var description: String { "the server closed the event stream" }
}

extension HangarAPI {
    /// The job's log, stored entries first, then live ones; finishes on the server's `end` event.
    public func followLog(jobID: UUID, step: String? = nil) -> AsyncThrowingStream<LogEntry, any Error> {
        let follow = request("GET", "jobs/\(jobID.uuidString)/log", query: ["follow": "1", "step": step])
        return stream(follow) { event, continuation in
            switch event.event {
            case "log":
                for entry in try JSONCoding.decoder.decode([LogEntry].self, from: Data(event.data.utf8)) {
                    continuation.yield(entry)
                }
                return true
            case "end":
                return false
            default:
                return true
            }
        }
    }

    /// Every build, job and machine change. The server never ends this stream, so its end is an error.
    public func events() -> AsyncThrowingStream<ServerEvent, any Error> {
        stream(request("GET", "events")) { event, continuation in
            guard ["build", "job", "machine"].contains(event.event) else { return true }
            continuation.yield(try JSONCoding.decoder.decode(ServerEvent.self, from: Data(event.data.utf8)))
            return true
        }
    }

    /// Feeds each SSE event to `handle` until it returns false; a stream that ends before that throws `StreamClosed`.
    private func stream<Element: Sendable>(
        _ request: URLRequest,
        handle: @escaping @Sendable (SSEEvent, AsyncThrowingStream<Element, any Error>.Continuation) throws -> Bool
    ) -> AsyncThrowingStream<Element, any Error> {
        let lines = openLines(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in SSEReader(lines: lines) {
                        guard try handle(event, continuation) else {
                            continuation.finish()
                            return
                        }
                    }
                    throw HangarAPIError.transport(StreamClosed())
                } catch let error as HangarAPIError {
                    continuation.finish(throwing: error)
                } catch let error as DecodingError {
                    continuation.finish(throwing: HangarAPIError.invalidResponse(error))
                } catch {
                    continuation.finish(throwing: HangarAPIError.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// No overall deadline, so a long build streams to its end. The 60 s request timeout is URLSession's idle
    /// timeout: the server sends a keep-alive every 15 s, so 60 s of silence means the connection is gone.
    private static let streamingSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        return URLSession(configuration: configuration)
    }()

    static let liveLines: LineStreamOpener = { request in
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await streamingSession.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 65_536 { break }
                        }
                        try check(status: status, body: body)
                    }
                    for try await line in SSELines(bytes: bytes) { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
