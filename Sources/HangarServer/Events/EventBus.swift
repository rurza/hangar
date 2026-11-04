import Foundation
import HangarCore
import Synchronization

/// Fan-out of server events to every subscriber (the SSE endpoints).
public final class EventBus: Sendable {
    public enum Event: Sendable {
        case server(ServerEvent)
        case log(jobID: UUID, [LogEntry])
    }

    private let subscribers = Mutex<[UUID: AsyncStream<Event>.Continuation]>([:])

    public init() {}

    public func publish(_ event: Event) {
        for continuation in subscribers.withLock({ Array($0.values) }) { continuation.yield(event) }
    }

    /// How many streams are subscribed; tests wait on it before publishing.
    var subscriberCount: Int { subscribers.withLock(\.count) }

    /// Keeps the newest 1000 events, so a slow subscriber drops old ones rather than holding up publishers.
    public func subscribe() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(1000))
        continuation.onTermination = { [weak self] _ in
            _ = self?.subscribers.withLock { $0.removeValue(forKey: id) }
        }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }
}
