import Foundation
import HangarCore

/// Job logs, one JSON line per entry at `jobs/<jobID>/log.jsonl`. An actor, so concurrent appends for a job
/// never interleave partial lines and a read never sees half an append.
public actor LogStore {
    static let fileName = "log.jsonl"

    let jobsDirectory: URL

    public init(jobsDirectory: URL) { self.jobsDirectory = jobsDirectory }

    public func append(jobID: UUID, _ entries: [LogEntry]) throws {
        guard !entries.isEmpty else { return }
        let encoder = JSONCoding.encoder
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        let file = self.file(jobID)
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// The job's entries, only those of `step` when given, then the last `tail` of them.
    public func read(jobID: UUID, step: String?, tail: Int?) throws -> [LogEntry] {
        var entries = try read(jobID: jobID, after: 0).entries
        if let step { entries = entries.filter { $0.step == step } }
        if let tail { entries = Array(entries.suffix(max(0, tail))) }
        return entries
    }

    /// The entries stored after byte `offset`, and the offset to pass next time. Log following uses this, so it
    /// sends each stored entry exactly once whatever it learns from the event bus.
    public func read(jobID: UUID, after offset: UInt64) throws -> (entries: [LogEntry], offset: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: file(jobID).path) else { return ([], offset) }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        // Only whole lines count; a line without its newline is picked up by the next read.
        guard let end = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let decoder = JSONCoding.decoder
        let entries = data[data.startIndex..<end].split(separator: 0x0A).compactMap {
            try? decoder.decode(LogEntry.self, from: Data($0))
        }
        return (entries, offset + UInt64(end - data.startIndex + 1))
    }

    private func file(_ jobID: UUID) -> URL {
        jobsDirectory.appendingPathComponent(jobID.uuidString).appendingPathComponent(Self.fileName)
    }
}
