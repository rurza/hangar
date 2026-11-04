import Foundation

/// One server-sent event: its `event:` name (`message` when the frame names none) and its `data:` lines joined by `\n`.
public struct SSEEvent: Equatable, Sendable {
    public var event: String
    public var data: String

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// Parses `text/event-stream` lines into events: `event:` and `data:` fields, a blank line dispatches,
/// lines starting with `:` are comments. A frame cut off before its blank line is dropped.
public struct SSEReader<Lines: AsyncSequence>: AsyncSequence where Lines.Element == String {
    public typealias Element = SSEEvent

    private let lines: Lines

    public init(lines: Lines) {
        self.lines = lines
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(lines: lines.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        var lines: Lines.AsyncIterator

        public mutating func next() async throws -> SSEEvent? {
            var event: String?
            var data: [String] = []
            while let line = try await lines.next() {
                if line.isEmpty {
                    guard !data.isEmpty else { event = nil; continue }
                    return SSEEvent(event: event ?? "message", data: data.joined(separator: "\n"))
                }
                if line.hasPrefix(":") { continue }
                let (field, value) = Self.split(line)
                switch field {
                case "event": event = value
                case "data": data.append(value)
                default: continue  // `id:`, `retry:` and unknown fields are not used.
                }
            }
            return nil
        }

        /// `field: value` with one optional space after the colon; a line without a colon is a field with no value.
        static func split(_ line: String) -> (String, String) {
            guard let colon = line.firstIndex(of: ":") else { return (line, "") }
            var value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
            return (String(line[..<colon]), String(value))
        }
    }
}

extension SSEReader {
    /// Reads events straight from a byte stream such as `URLSession.AsyncBytes`.
    public init<Bytes>(bytes: Bytes) where Lines == SSELines<Bytes> {
        self.init(lines: SSELines(bytes: bytes))
    }
}

/// Splits UTF-8 bytes into lines at `\n`, dropping a trailing `\r`. Unlike `AsyncBytes.lines` it keeps
/// empty lines, which are what end an SSE frame.
public struct SSELines<Bytes: AsyncSequence>: AsyncSequence where Bytes.Element == UInt8 {
    public typealias Element = String

    private let bytes: Bytes

    public init(bytes: Bytes) {
        self.bytes = bytes
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(bytes: bytes.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        var bytes: Bytes.AsyncIterator
        var finished = false

        public mutating func next() async throws -> String? {
            guard !finished else { return nil }
            var buffer: [UInt8] = []
            while let byte = try await bytes.next() {
                if byte == UInt8(ascii: "\n") { return Self.line(buffer) }
                buffer.append(byte)
            }
            finished = true
            return buffer.isEmpty ? nil : Self.line(buffer)
        }

        static func line(_ bytes: [UInt8]) -> String {
            String(decoding: bytes.last == UInt8(ascii: "\r") ? bytes.dropLast() : bytes[...], as: UTF8.self)
        }
    }
}
