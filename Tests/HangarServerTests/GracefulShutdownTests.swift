import Foundation
import HangarCore
import Hummingbird
import Logging
import ServiceLifecycle
import Testing

@testable import HangarServer

/// A server with an open event stream still stops promptly: the stream ends on graceful shutdown instead of
/// keeping the server waiting for a response that never finishes.
@Suite(.timeLimit(.minutes(1))) struct GracefulShutdownTests {
    @Test func gracefulShutdownEndsOpenEventStreams() async throws {
        let fixture = try APIFixture(port: 0)
        let (ports, portContinuation) = AsyncStream.makeStream(of: Int.self)
        let application = fixture.server.build { port in portContinuation.yield(port) }
        let group = fixture.server.serviceGroup(
            running: application, gracefulShutdownSignals: [], logger: Logger(label: "test"))
        let run = Task { try await group.run() }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())

        let stream = Task {
            let url = URL(string: "http://127.0.0.1:\(port)/api/v1/events")!
            let (bytes, _) = try await URLSession.shared.bytes(from: url)
            for try await _ in bytes {}
        }
        try await fixture.waitForSubscriber()

        let start = ContinuousClock.now
        await group.triggerGracefulShutdown()
        try await run.value
        let elapsed = ContinuousClock.now - start
        // Well under the 5 s backstop: the stream ended by itself.
        #expect(elapsed < .seconds(2), "shutdown took \(elapsed)")
        // The client saw the stream end rather than hang.
        _ = try? await stream.value
    }

    @Test func theBackstopIsFiveSeconds() {
        #expect(HangarServerApp.maximumGracefulShutdownDuration == .seconds(5))
    }
}
