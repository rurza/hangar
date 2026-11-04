import Foundation
import HangarClient
import HangarCore

/// Small pure formatters shared by the commands.
enum Format {
    /// `HH:MM:SS` in `timeZone`.
    static func time(_ date: Date, timeZone: TimeZone) -> String {
        let parts = calendar(timeZone).dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// `YYYY-MM-DD HH:MM:SS` in `timeZone`, for lists that span days.
    static func dateTime(_ date: Date, timeZone: TimeZone) -> String {
        let parts = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            + time(date, timeZone: timeZone)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `1m 05s`, `2h 03m`, `12s`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, total % 3600 / 60) }
        if total >= 60 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return "\(total)s"
    }

    /// `HH:MM:SS [step] line`, with `[prefix] ` in front when given.
    static func logLine(_ entry: LogEntry, prefix: String? = nil, timeZone: TimeZone) -> String {
        (prefix.map { "[\($0)] " } ?? "") + "\(time(entry.t, timeZone: timeZone)) [\(entry.step)] \(entry.line)"
    }

    /// `scheme/platform`, as `.hangar.yml` names an action.
    static func label(_ action: ArchiveAction) -> String { "\(action.scheme)/\(action.platform.rawValue)" }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
    static func shortCommit(_ commit: String) -> String { String(commit.prefix(7)) }

    /// The server's JSON, pretty-printed with sorted keys.
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// One compact JSON line with sorted keys, for streams (`logs --follow --json`).
    static func jsonLine(_ value: some Encodable) throws -> String {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A transport error in words, without Foundation's type names where it has a better description.
    static func describe(_ error: any Error) -> String {
        if let error = error as? URLError { return error.localizedDescription }
        return "\(error)"
    }
}
