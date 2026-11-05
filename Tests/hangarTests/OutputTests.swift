import Foundation
import HangarClient
import HangarCore
import Testing

@testable import hangar

@Suite struct OutputTests {
    typealias H = CLIHarness

    @Test func tableAlignsColumns() {
        let table = Table(headers: ["NAME", "STATUS"], rows: [["legilo", "ok"], ["a", "running"]])
        #expect(table.render() == "NAME    STATUS\nlegilo  ok\na       running")
    }

    @Test func statusDetailShowsTheKindAndTestSummary() {
        var job = H.job(status: .failed)
        job.action = .test(scheme: "LegiloTests", platform: .iOS)
        job.failureReason = "test: 2 tests failed"
        job.outputs = [
            "test.passed": "40", "test.failed": "2", "test.skipped": "1", "test.total": "43",
            "test.failures": #"[{"message":"XCTAssertEqual failed","name":"A/testOne()"},{"message":"line 1\nline 2","name":"A/testTwo()"}]"#,
        ]
        let text = Status.renderDetail(H.build(job), apps: [H.app], machines: [], now: H.t0, timeZone: H.utc)
        #expect(text.contains("[LegiloTests/ios (test)] Test – iOS failed on 22222222: test: 2 tests failed"))
        #expect(text.contains("Tests: 40 passed · 2 failed · 1 skipped\n  ✗ A/testOne(): XCTAssertEqual failed\n  ✗ A/testTwo(): line 1"))
        #expect(!text.contains("line 2"))

        let archive = Status.renderDetail(H.build(H.job(status: .running)), apps: [H.app], machines: [], now: H.t0, timeZone: H.utc)
        #expect(archive.contains("[Legilo/ios] Archive – iOS running"))
        #expect(!archive.contains("Tests:"))
    }

    @Test func statusTableShowsQueueNote() {
        let machine = Machine(id: H.machineID, name: "mini", createdAt: H.t0)
        let queued = H.build(H.job(queueNote: "waiting for a machine with Xcode 26.1"))
        let runningJob = Job(
            id: UUID(), buildID: UUID(), action: WorkflowAction(scheme: "LegiloMac", platform: .macOS, export: .developerID),
            status: .running, machineID: H.machineID,
            steps: [
                StepRecord(name: "checkout", status: .succeeded, startedAt: H.t0, finishedAt: H.t0),
                StepRecord(name: "archive", status: .running, startedAt: H.t0),
            ],
            createdAt: H.t0)
        var running = H.build(runningJob)
        running.id = runningJob.buildID
        running.buildNumber = 43

        let text = Status.renderActive([queued, running], apps: [H.app], machines: [machine])
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("BUILD"))
        #expect(lines[0].contains("NOTE"))
        #expect(lines[1].contains("legilo"))
        #expect(lines[1].contains("Legilo/ios"))
        #expect(lines[1].contains("queued"))
        #expect(lines[1].hasSuffix("waiting for a machine with Xcode 26.1"))
        #expect(lines[2].contains("LegiloMac/macos"))
        #expect(lines[2].contains("mini"))
        #expect(lines[2].contains("archive"))
    }

    @Test func statusWithoutActiveBuildsSaysSo() {
        #expect(Status.renderActive([], apps: [], machines: []) == "No queued or running builds.")
    }

    @Test func logsRenderTimeAndStep() {
        let entry = LogEntry(t: H.t0.addingTimeInterval(3723.4), step: "archive", line: "** ARCHIVE SUCCEEDED **")
        #expect(Format.logLine(entry, timeZone: H.utc) == "09:02:03 [archive] ** ARCHIVE SUCCEEDED **")
        #expect(Format.logLine(entry, prefix: "Legilo", timeZone: H.utc) == "[Legilo] 09:02:03 [archive] ** ARCHIVE SUCCEEDED **")
        let warsaw = TimeZone(identifier: "Europe/Warsaw")!
        #expect(Format.time(H.t0, timeZone: warsaw) == "09:00:00")
    }

    @Test func jsonFlagEmitsRawDTO() async throws {
        let result = await H(responses: [try H.json([H.app])]).run(["apps", "list", "--json"])

        #expect(result.exitCode == 0)
        #expect(result.err.isEmpty)
        let decoded = try JSONCoding.decoder.decode([App].self, from: Data(result.out.utf8))
        #expect(decoded == [H.app])
        #expect(result.out.contains("\n    \"appStoreConnectAppID\" : \"123456\",\n    \"createdAt\""))
    }

    @Test func buildProgressReportsEachStepTransitionOnce() {
        var progress = BuildProgress(build: H.build())
        let checkoutRunning = H.job(status: .running, steps: [StepRecord(name: "checkout", status: .running, startedAt: H.t0)])
        let checkoutDone = H.job(status: .running, steps: [
            StepRecord(name: "checkout", status: .succeeded, startedAt: H.t0, finishedAt: H.t0.addingTimeInterval(5)),
            StepRecord(name: "archive", status: .pending),
        ])

        #expect(progress.apply(checkoutRunning, timeZone: H.utc) == ["08:00:00 [Legilo/ios] checkout running"])
        #expect(progress.apply(checkoutRunning, timeZone: H.utc) == [])
        #expect(progress.apply(checkoutDone, timeZone: H.utc) == ["08:00:05 [Legilo/ios] checkout succeeded"])
        // A stale event arriving after a newer snapshot does not move a step back.
        #expect(progress.apply(checkoutRunning, timeZone: H.utc) == [])
        #expect(progress.build.status == .running)
    }
}
