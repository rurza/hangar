import Foundation
import HangarCore
import Testing

@testable import HangarServer

@Suite struct LogStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-logs-\(UUID().uuidString)")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ step: String, _ line: String) -> LogEntry { LogEntry(t: t0, step: step, line: line) }

    @Test func tailAndStepFilter() async throws {
        let store = LogStore(jobsDirectory: directory)
        let job = UUID()
        let entries = [
            entry("checkout", "a"), entry("archive", "b"), entry("archive", "c"), entry("export", "d"),
            entry("archive", "e"),
        ]
        try await store.append(jobID: job, Array(entries[..<2]))
        try await store.append(jobID: job, Array(entries[2...]))

        #expect(try await store.read(jobID: job, step: nil, tail: nil) == entries)
        #expect(try await store.read(jobID: job, step: "archive", tail: nil).map(\.line) == ["b", "c", "e"])
        #expect(try await store.read(jobID: job, step: "archive", tail: 2).map(\.line) == ["c", "e"])
        #expect(try await store.read(jobID: job, step: nil, tail: 1).map(\.line) == ["e"])
        #expect(try await store.read(jobID: job, step: nil, tail: 0).isEmpty)
        #expect(try await store.read(jobID: UUID(), step: nil, tail: nil).isEmpty)
        let file = directory.appendingPathComponent("\(job.uuidString)/log.jsonl")
        #expect(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count == 5)
    }

    @Test func concurrentAppendsKeepWholeLines() async throws {
        let store = LogStore(jobsDirectory: directory)
        let job = UUID()
        let long = String(repeating: "x", count: 10_000)
        await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { try await store.append(jobID: job, [entry("archive", "\(index) \(long)")]) }
            }
        }
        let lines = try await store.read(jobID: job, step: nil, tail: nil)
        #expect(lines.count == 50)
        #expect(Set(lines.map { $0.line.prefix { $0 != " " } }).count == 50)
    }

    @Test func readFromOffsetReturnsOnlyNewEntries() async throws {
        let store = LogStore(jobsDirectory: directory)
        let job = UUID()
        try await store.append(jobID: job, [entry("checkout", "a")])
        let first = try await store.read(jobID: job, after: 0)
        #expect(first.entries.map(\.line) == ["a"])
        try await store.append(jobID: job, [entry("archive", "b"), entry("archive", "c")])
        let second = try await store.read(jobID: job, after: first.offset)
        #expect(second.entries.map(\.line) == ["b", "c"])
        #expect(try await store.read(jobID: job, after: second.offset).entries.isEmpty)
    }
}
