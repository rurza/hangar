import Foundation
import Testing

@testable import HangarClient

@Suite struct SSEReaderTests {
    func lines(_ text: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) { continuation.yield(String(line)) }
            continuation.finish()
        }
    }

    func bytes(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in text.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
    }

    func collect<S: AsyncSequence>(_ sequence: S) async throws -> [S.Element] {
        var result: [S.Element] = []
        for try await element in sequence { result.append(element) }
        return result
    }

    @Test func parsesMultiLineDataAndIgnoresComments() async throws {
        let text = """
            : keep-alive

            event: log
            data: first
            data: second

            : another comment
            data:no-space
            data:  two spaces

            event: end
            data: {}

            """
        let events = try await collect(SSEReader(lines: lines(text)))
        #expect(events == [
            SSEEvent(event: "log", data: "first\nsecond"),
            SSEEvent(event: "message", data: "no-space\n two spaces"),
            SSEEvent(event: "end", data: "{}"),
        ])
    }

    @Test func frameWithoutTrailingBlankLineIsNotDispatched() async throws {
        let events = try await collect(SSEReader(lines: lines("event: build\ndata: {}\n\nevent: job\ndata: {")))
        #expect(events == [SSEEvent(event: "build", data: "{}")])
    }

    @Test func byteStreamKeepsBlankLinesAndStripsCarriageReturns() async throws {
        let text = "event: build\r\ndata: {\"a\":1}\r\n\r\n: keep-alive\n\nevent: job\ndata: é\n\n"
        let events = try await collect(SSEReader(bytes: bytes(text)))
        #expect(events == [SSEEvent(event: "build", data: "{\"a\":1}"), SSEEvent(event: "job", data: "é")])
    }
}
