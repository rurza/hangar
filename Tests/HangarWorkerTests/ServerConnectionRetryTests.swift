import Foundation
import Synchronization
import Testing

@testable import HangarWorker

@Suite struct ServerConnectionRetryTests {
    @Test func aRequestOnAnAlreadyClosedConnectionIsSentOnceMore() async throws {
        let attempts = Mutex(0)
        let value = try await HTTPServerConnection.retryingLostConnection { () async throws -> Int in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return 42
        }
        #expect(value == 42)
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func otherFailuresAndASecondLossAreNotRetried() async {
        let attempts = Mutex(0)
        await #expect(throws: URLError.self) {
            try await HTTPServerConnection.retryingLostConnection { () async throws -> Int in
                attempts.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
        }
        #expect(attempts.withLock { $0 } == 1)
        attempts.withLock { $0 = 0 }
        await #expect(throws: URLError.self) {
            try await HTTPServerConnection.retryingLostConnection { () async throws -> Int in
                attempts.withLock { $0 += 1 }
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(attempts.withLock { $0 } == 2)
    }
}
