import Foundation
import Testing

/// What the build page says about a job and its steps (Web/assets/build-model.js), run in JXA.
@Suite(.timeLimit(.minutes(1))) struct BuildModelTests {
    static func run(_ json: String, _ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: json, files: ["build-model.js"], expression)
    }

    @Test func failedStepShowsItsCauseAndCancelledStepIsCancelled() throws {
        let job = #"""
            {"status": "failed", "steps": [
              {"name": "archive", "status": "failed", "detail": "File.swift:1:2: error: x (xcodebuild exited with 65)"},
              {"name": "export", "status": "succeeded", "detail": "ignored"},
              {"name": "test", "status": "cancelled", "detail": "Stopped: hangar-worker on mini was stopped (SIGTERM)"}]}
            """#
        let output = try Self.run(job, """
            input.steps.map((step) => `${stepDisplayStatus(step, input)}|${stepDetail(step, input)}|${stepStatusWords(stepDisplayStatus(step, input))}`).join('\\n')
            """)
        #expect(output == """
            failed|File.swift:1:2: error: x (xcodebuild exited with 65)|failed
            succeeded|null|succeeded
            cancelled|Stopped: hangar-worker on mini was stopped (SIGTERM)|cancelled
            """)
    }

    @Test func stepLeftRunningTakesTheJobsEnd() throws {
        let output = try Self.run(#"[{"status": "cancelled"}, {"status": "failed"}, {"status": "running"}]"#, """
            input.map((job) => stepDisplayStatus({ name: 'archive', status: 'running' }, job)).join(',')
            """)
        #expect(output == "cancelled,failed,running")
    }

    @Test func testFlightStagesAndWarnings() throws {
        let job = #"""
            {"status": "succeeded", "steps": [{"name": "post-action:testflight", "status": "warning",
              "detail": "Groups: could not add the build to QA: refused",
              "stages": [{"name": "Upload", "status": "succeeded"}, {"name": "Processing", "status": "succeeded", "detail": "VALID"},
                         {"name": "Groups", "status": "warning", "detail": "Internal gets every build automatically; could not add the build to QA: refused"}]}]}
            """#
        let output = try Self.run(job, """
            [stepDetail(input.steps[0], input), stepStatusWords('warning'),
             ...stepStages(input.steps[0], input).map((s) => `${s.name}:${s.status}:${s.detail}`)].join('\\n')
            """)
        #expect(output == """
            Groups: could not add the build to QA: refused
            succeeded with warnings
            Upload:succeeded:null
            Processing:succeeded:VALID
            Groups:warning:Internal gets every build automatically; could not add the build to QA: refused
            """)
    }

    @Test func runLineNamesMachineWorkerAndXcode() throws {
        let job = #"""
            {"machineID": "M1", "runInfo": {"machineName": "old-name", "workerVersion": "0.5.0 (a1c9b45d)", "xcodeVersion": "27.2", "xcodeBuild": "27B48"}}
            """#
        let output = try Self.run(job, """
            [jobRunLine(input, { name: 'rurzomac-mini' }), jobRunLine(input, null), jobRunLine({ machineID: 'M1' }, null),
             jobRunLine({}, null)].join('\\n')
            """)
        #expect(output == """
            rurzomac-mini · Worker 0.5.0 (a1c9b45d) · Xcode 27.2 (27B48)
            old-name · Worker 0.5.0 (a1c9b45d) · Xcode 27.2 (27B48)
            Unknown machine
            No machine yet
            """)
    }
}
