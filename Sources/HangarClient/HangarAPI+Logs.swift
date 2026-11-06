import Foundation
import HangarCore

/// Which log `HangarAPI.readableLog` read.
public enum LogSource: String, Sendable, Equatable {
    /// The server's log with xcodebuild's steps condensed (as current workers send it, or condensed here for jobs
    /// logged before).
    case condensed
    /// The job's `full-log.txt` artifact: every line as xcodebuild printed it.
    case full
    /// The server's log as stored, when raw was asked for and the job has no full log (it was never condensed, or
    /// is still running).
    case stored
}

extension HangarAPI {
    /// A job's log for people and agents: condensed by default (`XcodebuildLogCondenser`), or with `raw` as xcodebuild
    /// printed it. `step` and `tail` apply after condensing, so a tail never starts inside a task's invocation.
    public func readableLog(jobID: UUID, step: String? = nil, tail: Int? = nil, raw: Bool = false) async throws
        -> (entries: [LogEntry], source: LogSource)
    {
        func tailed(_ entries: [LogEntry]) -> [LogEntry] {
            guard let tail else { return entries }
            return Array(entries.suffix(max(0, tail)))
        }
        guard raw else {
            return (tailed(XcodebuildLogCondenser.condense(try await log(jobID: jobID, step: step))), .condensed)
        }
        if try await artifacts(jobID: jobID).contains(where: { $0.name == APIPath.fullLogArtifact }) {
            let text = String(decoding: try await artifact(jobID: jobID, name: APIPath.fullLogArtifact), as: UTF8.self)
            var entries = Self.fullLogEntries(text)
            if let step { entries = entries.filter { $0.step == step } }
            return (tailed(entries), .full)
        }
        return (try await log(jobID: jobID, step: step, tail: tail), .stored)
    }

    /// The entries of a full log, one `2026-11-05T13:32:03.736Z [archive] line` per line (the line may be empty).
    static func fullLogEntries(_ text: String) -> [LogEntry] {
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var entries: [LogEntry] = []
        for row in text.split(separator: "\n", omittingEmptySubsequences: false) where !row.isEmpty {
            guard let space = row.firstIndex(of: " "), let date = try? time.parse(String(row[..<space])) else { continue }
            let rest = row[row.index(after: space)...]
            guard rest.hasPrefix("["), let close = rest.range(of: "] ") ?? (rest.hasSuffix("]") ? rest.range(of: "]") : nil)
            else { continue }
            let step = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
            entries.append(LogEntry(t: date, step: step, line: String(rest[close.upperBound...])))
        }
        return entries
    }
}
