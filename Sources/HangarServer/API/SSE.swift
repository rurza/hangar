import Foundation
import HangarCore
import Hummingbird
import Logging
import ServiceLifecycle

/// Server-sent events: `event: <name>\ndata: <single-line JSON>\n\n`, plus a `: keep-alive` comment every 15 s.
enum SSE {
    static let keepAliveInterval: Duration = .seconds(15)
    static let keepAlive = ": keep-alive\n\n"
    static let logger = Logger(label: "app.hangar.server.sse")

    /// `JSONCoding` never pretty-prints, and escapes newlines inside strings, so the JSON is one line.
    static func frame(event: String, data: some Encodable) throws -> String {
        "event: \(event)\ndata: \(String(decoding: try JSONCoding.encoder.encode(data), as: UTF8.self))\n\n"
    }

    /// Streams what `produce` yields until it returns, the client goes away (which cancels it) or the server shuts
    /// down gracefully. A stream never finishes on its own, and graceful shutdown waits for every response to finish,
    /// so without the last case one open page would keep the server from stopping.
    static func response(
        clock: any Clock<Duration>,
        produce: @escaping @Sendable (AsyncStream<String>.Continuation) async throws -> Void
    ) -> Response {
        let body = ResponseBody { writer in
            let (frames, output) = AsyncStream.makeStream(of: String.self)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    defer { output.finish() }
                    do {
                        try await cancelWhenGracefulShutdown { try await produce(output) }
                    } catch is CancellationError {} catch {
                        logger.error("event stream failed: \(error)")
                    }
                }
                group.addTask {
                    while true {
                        try await clock.sleep(for: keepAliveInterval)
                        output.yield(keepAlive)
                    }
                }
                for await frame in frames { try await writer.write(ByteBuffer(string: frame)) }
                // The keep-alive's cancellation error is discarded: the group is never asked for child results.
                group.cancelAll()
            }
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"], body: body)
    }
}

extension HangarServerApp {
    /// `GET /events`: every server event, named by its type, with the `ServerEvent` JSON as data.
    func eventsResponse() -> Response {
        SSE.response(clock: clock) { [events] output in
            for await event in events.subscribe() {
                guard case .server(let event) = event else { continue }
                output.yield(try SSE.frame(event: event.eventName, data: event))
            }
        }
    }

    /// `GET /jobs/{id}/log?follow=1`: the stored entries, then new ones as they arrive, then `end` with the job.
    ///
    /// No entry is lost or sent twice: the stream subscribes before reading anything, and it always sends entries
    /// from the log file, reading on from the byte offset where it stopped. A `log` event for the job only says
    /// "read again"; the worker routes append to the store before they publish, so the entries are on disk by then.
    func logFollowResponse(jobID: UUID, step: String?) -> Response {
        SSE.response(clock: clock) { [events, builds, logStore] output in
            let subscription = events.subscribe()
            var offset: UInt64 = 0
            func sendNewEntries() async throws {
                let read = try await logStore.read(jobID: jobID, after: offset)
                offset = read.offset
                let entries = step.map { step in read.entries.filter { $0.step == step } } ?? read.entries
                if !entries.isEmpty { output.yield(try SSE.frame(event: "log", data: entries)) }
            }

            try await sendNewEntries()
            guard let job = try builds.job(id: jobID) else { return }
            if job.status.isTerminal {
                // The job may have finished after the read above, with its last lines appended in between.
                try await sendNewEntries()
                output.yield(try SSE.frame(event: "end", data: job))
                return
            }
            for await event in subscription {
                switch event {
                case .log(let id, _) where id == jobID:
                    try await sendNewEntries()
                case .server(.job(let job)) where job.id == jobID && job.status.isTerminal:
                    try await sendNewEntries()
                    output.yield(try SSE.frame(event: "end", data: job))
                    return
                default:
                    continue
                }
            }
        }
    }
}
