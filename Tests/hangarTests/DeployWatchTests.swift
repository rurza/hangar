import Foundation
import HangarClient
import HangarCore
import Testing

@testable import hangar

@Suite(.timeLimit(.minutes(1))) struct DeployWatchTests {
    typealias H = CLIHarness

    static let t1 = H.t0.addingTimeInterval(10)
    static let t2 = H.t0.addingTimeInterval(20)

    static func step(_ name: String, _ status: StepStatus, started: Date? = t1, finished: Date? = nil) -> StepRecord {
        StepRecord(name: name, status: status, startedAt: started, finishedAt: finished)
    }

    @Test func watchPrintsTransitionsAndSucceeds() async throws {
        let running = H.job(status: .running, steps: [Self.step("checkout", .running)])
        let done = H.job(status: .succeeded, steps: [
            Self.step("checkout", .succeeded, finished: Self.t2),
            Self.step("archive", .succeeded, started: Self.t2, finished: Self.t2),
        ])
        var harness = H(responses: [try H.json(H.build(), status: 202), try H.json(H.build())])
        harness.isTTY = true
        harness.events = try H.frame(.job(running)) + H.frame(.job(done))

        let result = await harness.run(["deploy", "legilo", "testflight"])

        #expect(result.exitCode == 0)
        #expect(result.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "POST /api/v1/builds", "GET /api/v1/builds/\(H.buildID.uuidString)",
        ])
        #expect(result.out.contains("08:00:10 [Legilo/ios] checkout running\n"))
        #expect(result.out.contains("08:00:20 [Legilo/ios] checkout succeeded\n"))
        #expect(result.out.contains("08:00:20 [Legilo/ios] archive succeeded\n"))
        #expect(result.out.hasSuffix("Build 42 succeeded.\n"))
    }

    @Test func failedBuildPrintsTheFailedStepsLastLines() async throws {
        var failedJob = H.job(status: .failed, steps: [
            Self.step("checkout", .succeeded, finished: Self.t1),
            Self.step("archive", .failed, finished: Self.t2),
        ])
        failedJob.failureReason = "xcodebuild archive exited with 65"
        let tail = [LogEntry(t: Self.t2, step: "archive", line: "error: no signing certificate")]
        var harness = H(responses: [try H.json(H.build(), status: 202), try H.json(H.build()), try H.json(tail)])
        harness.events = try H.frame(.build(H.build(failedJob)))

        let result = await harness.run(["deploy", "legilo", "testflight", "--watch"])

        #expect(result.exitCode == 1)
        let logRequest = try #require(result.requests.last?.url)
        #expect(logRequest.path == "/api/v1/jobs/\(H.jobID.uuidString)/log")
        #expect(logRequest.query == "step=archive&tail=40")
        #expect(result.out.contains("08:00:20 [Legilo/ios] archive failed\n"))
        #expect(result.out.contains("xcodebuild archive exited with 65"))
        #expect(result.out.contains("08:00:20 [archive] error: no signing certificate\n"))
        #expect(result.out.contains("Build 42 failed."))
    }

    @Test func cancelledBuildExitsTwo() async throws {
        var harness = H(responses: [try H.json(H.build(), status: 202), try H.json(H.build(H.job(status: .cancelled)))])
        harness.isTTY = true
        let result = await harness.run(["deploy", "legilo", "testflight"])
        #expect(result.exitCode == 2)
        #expect(result.out.hasSuffix("Build 42 cancelled.\n"))
    }

    @Test func jsonAndNoWaitDoNotWatch() async throws {
        var harness = H(responses: [try H.json(H.build(), status: 202)])
        harness.isTTY = true
        let result = await harness.run(["deploy", "legilo", "testflight", "--json"])
        #expect(result.exitCode == 0)
        #expect(result.requests.count == 1)
        #expect(try JSONCoding.decoder.decode(Build.self, from: Data(result.out.utf8)) == H.build())
    }
}
