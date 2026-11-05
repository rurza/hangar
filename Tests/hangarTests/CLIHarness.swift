import ArgumentParser
import Foundation
import HangarClient
import HangarCore
import Synchronization

@testable import hangar

/// Runs `hangar` in-process against a `StubTransport`, capturing stdout, stderr and the exit code.
struct CLIHarness {
    struct Result {
        var out: String
        var err: String
        var exitCode: Int32
        var requests: [URLRequest]

        /// Each request's JSON body decoded as `T`.
        func bodies<T: Decodable>(_ type: T.Type) throws -> [T] {
            try requests.compactMap(\.httpBody).map { try JSONCoding.decoder.decode(T.self, from: $0) }
        }
    }

    final class Capture: Sendable {
        private let streams = Mutex<(out: String, err: String)>(("", ""))
        func out(_ text: String) { streams.withLock { $0.out += text } }
        func err(_ text: String) { streams.withLock { $0.err += text } }
        var captured: (out: String, err: String) { streams.withLock { $0 } }
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00:00 UTC
    static let utc = TimeZone(identifier: "UTC")!

    var responses: [StubTransport.Response] = []
    var stdin = ""
    var isTTY = false
    /// The `/events` stream's text; empty means the stream closes at once.
    var events = ""
    var pollInterval: Duration = .seconds(3600)
    var lostContactAfter: Duration = .seconds(120)
    var environment: [String: String] = [:]

    static func json(_ value: some Encodable, status: Int = 200) throws -> StubTransport.Response {
        StubTransport.Response(status: status, body: try JSONCoding.encoder.encode(value))
    }

    static func frame(_ event: ServerEvent) throws -> String {
        "event: \(event.eventName)\ndata: \(String(decoding: try JSONCoding.encoder.encode(event), as: UTF8.self))\n\n"
    }

    func run(_ arguments: [String]) async -> Result {
        let transport = StubTransport(responses: responses)
        let capture = Capture()
        let stdinData = Data(stdin.utf8)
        let eventsText = events
        let context = CLIContext(
            makeAPI: { url in
                HangarAPI(baseURL: url, transport: transport) { _ in
                    AsyncThrowingStream { continuation in
                        for line in eventsText.split(separator: "\n", omittingEmptySubsequences: false) {
                            continuation.yield(String(line))
                        }
                        continuation.finish()
                    }
                }
            },
            console: Console(
                write: { capture.out($0) }, writeError: { capture.err($0) }, readInput: { stdinData }, isTTY: isTTY),
            environment: environment, timeZone: Self.utc, pollInterval: pollInterval, lostContactAfter: lostContactAfter)

        let exitCode: Int32 = await CLIContext.$current.withValue(context) {
            do {
                var command = try Hangar.parseAsRoot(arguments)
                if var command = command as? any AsyncParsableCommand {
                    try await command.run()
                } else {
                    try command.run()
                }
                return 0
            } catch {
                return Hangar.exitCode(for: error).rawValue
            }
        }
        let captured = capture.captured
        return Result(out: captured.out, err: captured.err, exitCode: exitCode, requests: transport.requests)
    }

    // MARK: - Fixtures

    static let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let machineID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let buildID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let jobID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    static let app = App(
        id: appID, slug: "legilo", name: "Legilo", repoURL: "https://github.com/acme/legilo",
        appStoreConnectAppID: "123456", createdAt: t0)

    static func job(status: JobStatus = .queued, steps: [StepRecord] = [], queueNote: String? = nil) -> Job {
        Job(
            id: jobID, buildID: buildID, action: WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect),
            status: status, machineID: status == .queued ? nil : machineID, steps: steps, queueNote: queueNote,
            createdAt: t0)
    }

    static func build(_ job: Job = job()) -> Build {
        Build(
            id: buildID, appID: appID, workflow: "testflight", ref: "main", commit: "abc1234def", buildNumber: 42,
            status: BuildStatus.derived(from: [job.status]), createdAt: t0, jobs: [job])
    }
}
