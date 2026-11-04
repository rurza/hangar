import Clocks
import Foundation
import HangarCore
import Hummingbird
import Synchronization
import HummingbirdTesting
import Testing

@testable import HangarServer

/// Job logs, artifacts and the SSE streams.
@Suite(.timeLimit(.minutes(1))) struct StreamingAPITests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ step: String, _ line: String, _ offset: Int) -> LogEntry {
        LogEntry(t: Self.t0.addingTimeInterval(TimeInterval(offset)), step: step, line: line)
    }

    func deploy(_ fixture: APIFixture) async throws -> Build {
        try fixture.createApp()
        return try await fixture.server.buildService.deploy(DeployRequest(app: "legilo", workflow: "testflight", ref: "main"))
    }

    @Test func logReadFiltersAndTails() async throws {
        let fixture = try APIFixture()
        let job = try await deploy(fixture).jobs[0]
        let entries = [entry("checkout", "a", 0), entry("archive", "b", 1), entry("archive", "c", 2)]
        try await fixture.server.logStore.append(jobID: job.id, entries)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/log?step=archive&tail=1", method: .get) { response throws in
                #expect(try decode([LogEntry].self, response) == [entries[2]])
            }
            try await client.execute(uri: "/api/v1/jobs/\(UUID().uuidString)/log", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "job_not_found")
            }
        }
    }

    @Test func logFollowStreamsAndEnds() async throws {
        let fixture = try APIFixture()
        let job = try await deploy(fixture).jobs[0]
        let stored = [entry("checkout", "cloning", 0), entry("checkout", "done", 1)]
        let live = [entry("archive", "building", 2)]
        try await fixture.server.logStore.append(jobID: job.id, stored)
        try await fixture.test { client in
            async let followed = client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/log?follow=1", method: .get) { $0 }
            try await fixture.waitForSubscriber()
            // What the worker routes do: append, then publish.
            try await fixture.server.logStore.append(jobID: job.id, live)
            fixture.server.events.publish(.log(jobID: job.id, live))
            try fixture.server.builds.setJobStatus(id: job.id, status: .succeeded, at: Self.t0)
            fixture.server.events.publish(.server(.job(try #require(try fixture.server.builds.job(id: job.id)))))

            let response = try await followed
            #expect(response.headers[.contentType] == "text/event-stream")
            #expect(response.headers[.cacheControl] == "no-cache")
            let frames = frames(response)
            #expect(frames.dropLast().allSatisfy { $0.event == "log" })
            let logged = try frames.dropLast().flatMap {
                try JSONCoding.decoder.decode([LogEntry].self, from: Data($0.data.utf8))
            }
            #expect(logged == stored + live)
            let end = try #require(frames.last)
            #expect(end.event == "end")
            #expect(try JSONCoding.decoder.decode(Job.self, from: Data(end.data.utf8)).status == .succeeded)
        }
    }

    @Test func logFollowOfFinishedJobReplaysAndEnds() async throws {
        let fixture = try APIFixture()
        let job = try await deploy(fixture).jobs[0]
        let stored = [entry("checkout", "cloning", 0)]
        try await fixture.server.logStore.append(jobID: job.id, stored)
        try fixture.server.builds.setJobStatus(id: job.id, status: .failed, at: Self.t0, failureReason: "boom")
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/log?follow=1", method: .get) { response throws in
                #expect(frames(response).map(\.event) == ["log", "end"])
                #expect(try JSONCoding.decoder.decode([LogEntry].self, from: Data(frames(response)[0].data.utf8)) == stored)
            }
        }
    }

    @Test func logFollowSendsEveryEntryOfAJobFinishedBeforeConnect() async throws {
        let fixture = try APIFixture()
        let job = try await deploy(fixture).jobs[0]
        let first = [entry("checkout", "cloning", 0)]
        let last = [entry("archive", "building", 1), entry("export", "exported", 2)]
        try await fixture.server.logStore.append(jobID: job.id, first)
        try await fixture.server.logStore.append(jobID: job.id, last)
        fixture.server.events.publish(.log(jobID: job.id, last))
        try fixture.server.builds.setJobStatus(id: job.id, status: .succeeded, at: Self.t0)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/log?follow=1", method: .get) { response throws in
                let frames = frames(response)
                let logged = try frames.dropLast().flatMap {
                    try JSONCoding.decoder.decode([LogEntry].self, from: Data($0.data.utf8))
                }
                #expect(logged == first + last)
                #expect(frames.last?.event == "end")
            }
        }
    }

    @Test func eventsForwardsServerEventsWithKeepAlive() async throws {
        let clock = TestClock()
        let fixture = try APIFixture(clock: clock)
        let (machine, _) = try fixture.server.machines.create(name: "studio")
        let response = fixture.server.eventsResponse()
        #expect(response.headers[.contentType] == "text/event-stream")
        #expect(response.headers[.cacheControl] == "no-cache")
        let writer = RecordingBodyWriter()
        let streaming = Task { try await response.body.write(writer) }
        defer { streaming.cancel() }
        try await fixture.waitForSubscriber()
        fixture.server.events.publish(.log(jobID: UUID(), []))
        fixture.server.events.publish(.server(.machine(machine)))
        try await writer.waitUntil { $0.contains("event: machine\n") }
        // The keep-alive task may start sleeping after any one advance; keep advancing until it fires.
        while !writer.text.contains(": keep-alive\n\n") {
            await clock.advance(by: .seconds(15))
            try await Task.sleep(for: .milliseconds(5))
        }

        let text = writer.text
        #expect(!text.contains("event: log"))
        let data = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("data: ") }).dropFirst(6)
        // Compared by ID: a date's ISO 8601 round trip need not give back the identical Double.
        guard case .machine(let sent) = try JSONCoding.decoder.decode(ServerEvent.self, from: Data(data.utf8)) else {
            Issue.record("expected a machine event")
            return
        }
        #expect(sent.id == machine.id)
        streaming.cancel()
        try await streaming.value
        #expect(fixture.server.events.subscriberCount == 0)
    }

    @Test func artifactsListAndDownload() async throws {
        let fixture = try APIFixture()
        let job = try await deploy(fixture).jobs[0]
        let chunks = [ByteBuffer(string: "PK\u{3}\u{4}"), ByteBuffer(string: "rest")]
        try await fixture.server.artifactStore.write(jobID: job.id, name: "Legilo.ipa", stream: chunks.async)
        try await fixture.server.artifactStore.write(jobID: job.id, name: "Legilo.dSYM.zip", stream: [ByteBuffer(string: "x")].async)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/artifacts", method: .get) { response throws in
                #expect(try decode([ArtifactInfo].self, response) == [
                    ArtifactInfo(name: "Legilo.dSYM.zip", sizeBytes: 1), ArtifactInfo(name: "Legilo.ipa", sizeBytes: 8),
                ])
            }
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/artifacts/Legilo.ipa", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/octet-stream")
                #expect(response.headers[.contentDisposition] == #"attachment; filename="Legilo.ipa""#)
                #expect(String(buffer: response.body) == "PK\u{3}\u{4}rest")
            }
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/artifacts/missing.ipa", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "artifact_not_found")
            }
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/artifacts/..", method: .get) { response throws in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func artifactNamesCannotEscapeTheJobDirectory() async throws {
        let fixture = try APIFixture()
        for name in ["../x", "a/b", "a\\b", "..", ".hidden", ""] {
            await #expect(throws: APIError.self) {
                try await fixture.server.artifactStore.write(jobID: UUID(), name: name, stream: [ByteBuffer]().async)
            }
        }
    }
}

/// Collects what an SSE body writes, so a test can read a stream that never ends by itself.
final class RecordingBodyWriter: ResponseBodyWriter, Sendable {
    private let buffer = Mutex(ByteBuffer())

    var text: String { buffer.withLock { String(buffer: $0) } }

    func write(_ buffer: ByteBuffer) async throws {
        self.buffer.withLock { _ = $0.writeImmutableBuffer(buffer) }
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {}

    func waitUntil(_ condition: (String) -> Bool) async throws {
        while !condition(text) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

extension Array where Element: Sendable {
    /// The elements as an `AsyncSequence`.
    var async: AsyncStream<Element> {
        AsyncStream { continuation in
            for element in self { continuation.yield(element) }
            continuation.finish()
        }
    }
}
