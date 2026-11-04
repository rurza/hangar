import Foundation

/// Shared coders for server, worker and client: camelCase keys, ISO 8601 dates with
/// fractional seconds (so log entries keep millisecond ordering). Computed, not stored,
/// because `JSONEncoder`/`JSONDecoder` are not `Sendable`.
public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // Round to the nearest millisecond; plain formatting truncates (…00.123 would print …00.122).
            let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
            try container.encode(rounded.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(text)"))
        }
        return decoder
    }
}
