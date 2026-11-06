import Foundation
import Testing
@testable import HangarCore

struct ModelCodingTests {
    static let when = Date(timeIntervalSince1970: 1_800_000_000.125)

    static func job() -> Job {
        Job(
            id: UUID(), buildID: UUID(),
            action: WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect),
            status: .running, machineID: UUID(),
            steps: [StepRecord(name: StepName.archive, status: .running, startedAt: when)],
            outputs: ["ipa": "a.ipa"], createdAt: when, startedAt: when)
    }

    @Test func jobAssignmentRoundTrips() throws {
        let assignment = JobAssignment(
            job: Self.job(),
            app: App(id: UUID(), slug: "legilo", name: "Legilo", repoURL: "u", appStoreConnectAppID: "1", createdAt: Self.when),
            workflow: Workflow(
                xcode: "27.2", actions: [WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect)],
                postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("QA")])])]),
            workflowName: "release", buildNumber: 42, commit: "abc", ref: "main",
            environment: [EnvEntry(name: "A", value: "b", isSecret: true)])
        let data = try JSONCoding.encoder.encode(assignment)
        #expect(try JSONCoding.decoder.decode(JobAssignment.self, from: data) == assignment)
        #expect(String(decoding: data, as: UTF8.self).contains("2027-01-15T08:00:00.125Z"))
        #expect(String(decoding: data, as: UTF8.self).contains(#""workflowName":"release""#))
    }

    @Test func machineReportDecodesWithoutSimulatorRuntimes() throws {
        let report = MachineReport(
            macOSVersion: "27.0", xcodes: [], chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: 100,
            onACPower: true, tools: [:], canSignWithoutPrompt: true, runningJobIDs: [],
            simulatorRuntimes: ["iOS 27.2", "visionOS 27.1"])
        let data = try JSONCoding.encoder.encode(report)
        #expect(try JSONCoding.decoder.decode(MachineReport.self, from: data) == report)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "simulatorRuntimes")
        let old = try JSONCoding.decoder.decode(MachineReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.simulatorRuntimes == [])
        #expect(old.capabilities == [])
        #expect(report.capabilities == [])
    }

    /// The `ArchiveAction`-era shapes, as a worker from before test actions decodes an assignment.
    private struct OldAssignment: Decodable {
        struct Action: Decodable { var scheme: String; var platform: String; var export: String }
        struct OldJob: Decodable { var action: Action }
        struct OldWorkflow: Decodable { var actions: [Action] }
        var job: OldJob
        var workflow: OldWorkflow
    }

    @Test func anArchiveJobOfAMixedWorkflowStaysReadableByOldWorkers() throws {
        let archive = WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect)
        let test = WorkflowAction.test(scheme: "LegiloTests", platform: .iOS)
        let workflow = Workflow(xcode: "27.2", actions: [test, archive], postActions: [PostActionSpec(name: "testflight")])
        var job = Self.job()
        job.action = archive
        let assignment = JobAssignment(
            job: job,
            app: App(id: UUID(), slug: "legilo", name: "Legilo", repoURL: "u", appStoreConnectAppID: "1", createdAt: Self.when),
            workflow: workflow.forJob(running: archive), workflowName: "release", buildNumber: 42, commit: "abc", ref: "main",
            environment: [])
        let old = try JSONCoding.decoder.decode(OldAssignment.self, from: JSONCoding.encoder.encode(assignment))
        #expect(old.job.action.export == "app-store-connect")
        #expect(old.workflow.actions.map(\.scheme) == ["Legilo"])
        // A test job keeps the whole workflow: only a worker with the test-actions capability gets it.
        #expect(workflow.forJob(running: test) == workflow)
        #expect(workflow.needsCapabilities(for: test) == [WorkerCapability.testActions])
        #expect(workflow.needsCapabilities(for: archive) == [])
    }

    @Test func datesKeepMilliseconds() throws {
        let entries = [LogEntry(t: Self.when, step: "archive", line: "a"),
                       LogEntry(t: Self.when.addingTimeInterval(0.002), step: "archive", line: "b")]
        let decoded = try JSONCoding.decoder.decode([LogEntry].self, from: JSONCoding.encoder.encode(entries))
        #expect(abs(decoded[0].t.timeIntervalSince(Self.when)) < 0.001)
        #expect(decoded[0].t < decoded[1].t)
    }

    @Test func decoderAcceptsWholeSecondDates() throws {
        let date = try JSONCoding.decoder.decode(Date.self, from: Data(#""2027-01-15T08:00:00Z""#.utf8))
        #expect(date.timeIntervalSince1970 == 1_800_000_000)
    }

    @Test func variableScopeRoundTrips() throws {
        let id = UUID()
        for scope in [VariableScope.global, .app(id)] {
            let data = try JSONCoding.encoder.encode(scope)
            #expect(try JSONCoding.decoder.decode(VariableScope.self, from: data) == scope)
        }
        #expect(String(decoding: try JSONCoding.encoder.encode(VariableScope.global), as: UTF8.self) == #""global""#)
    }

    @Test func serverEventShapeAndRoundTrip() throws {
        let machine = Machine(id: UUID(), name: "m1", createdAt: Self.when)
        let events: [ServerEvent] = [.job(Self.job()), .machine(machine)]
        for event in events {
            let data = try JSONCoding.encoder.encode(event)
            #expect(try JSONCoding.decoder.decode(ServerEvent.self, from: data) == event)
        }
        let json = String(decoding: try JSONCoding.encoder.encode(ServerEvent.machine(machine)), as: UTF8.self)
        #expect(json.contains(#""type":"machine""#))
        #expect(ServerEvent.machine(machine).eventName == "machine")
    }

    @Test func apiErrorBody() throws {
        let data = try JSONCoding.encoder.encode(APIError(code: "not_found", message: "no"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["code": "not_found", "message": "no"])
    }

    @Test func machinePausedRoundTripsAndAnOlderServersMachineIsNot() throws {
        let paused = Machine(id: UUID(), name: "m", createdAt: Self.when, paused: true)
        let data = try JSONCoding.encoder.encode(paused)
        #expect(String(decoding: data, as: UTF8.self).contains(#""paused":true"#))
        #expect(try JSONCoding.decoder.decode(Machine.self, from: data) == paused)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "paused")
        let old = try JSONCoding.decoder.decode(Machine.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.paused && old.name == "m")

        let machine = DeployCheckMachine(id: "x", name: "m", online: true, problems: [], waits: [])
        var check = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(machine)) as? [String: Any])
        check.removeValue(forKey: "paused")
        #expect(try JSONCoding.decoder.decode(DeployCheckMachine.self, from: JSONSerialization.data(withJSONObject: check)) == machine)
    }

    @Test func machineOnlineWindow() {
        let machine = Machine(id: UUID(), name: "m", lastSeenAt: Self.when, createdAt: Self.when)
        #expect(machine.isOnline(now: Self.when.addingTimeInterval(90)))
        #expect(!machine.isOnline(now: Self.when.addingTimeInterval(91)))
        #expect(!Machine(id: UUID(), name: "n", createdAt: Self.when).isOnline(now: Self.when))
    }

    @Test func machineReportFromAnOlderWorkerHasNoSigningDetails() throws {
        let json = #"""
            {"macOSVersion":"26.1","xcodes":[],"chip":"M4","performanceCores":10,"memoryGB":16,"freeDiskGB":100,
             "onACPower":true,"tools":{},"canSignWithoutPrompt":false,"runningJobIDs":[]}
            """#
        let report = try JSONCoding.decoder.decode(MachineReport.self, from: Data(json.utf8))
        #expect(report.signingIdentities == [])
        #expect(report.xcodeAccountSignedIn == nil)
        #expect(report.runningUser == nil)
        #expect(report.chip == "M4")
    }

    /// A worker from before the dedicated hangar user was removed still sends `headless` and `keychainProblem` until
    /// it updates itself: its report reads as before, without them.
    @Test func machineReportFromAHeadlessWorkerStillDecodes() throws {
        let json = #"""
            {"macOSVersion":"26.1","xcodes":[],"chip":"M4","performanceCores":10,"memoryGB":16,"freeDiskGB":100,
             "onACPower":true,"tools":{},"canSignWithoutPrompt":false,"runningJobIDs":[],"runningUser":"hangar",
             "headless":true,"keychainProblem":"the CI keychain does not unlock with its stored password"}
            """#
        let report = try JSONCoding.decoder.decode(MachineReport.self, from: Data(json.utf8))
        #expect(report.runningUser == "hangar")
        #expect(!report.canSignWithoutPrompt)
        let encoded = String(decoding: try JSONCoding.encoder.encode(report), as: UTF8.self)
        #expect(!encoded.contains("headless") && !encoded.contains("keychainProblem"))
    }

    @Test func machineReportRunningUserRoundTrips() throws {
        let report = MachineReport(
            macOSVersion: "26.1", xcodes: [], chip: "M4", performanceCores: 10, memoryGB: 16, freeDiskGB: 100,
            onACPower: true, tools: [:], canSignWithoutPrompt: true, runningJobIDs: [], runningUser: "adam")
        let data = try JSONCoding.encoder.encode(report)
        #expect(try JSONCoding.decoder.decode(MachineReport.self, from: data) == report)
        #expect(String(decoding: data, as: UTF8.self).contains(#""runningUser":"adam""#))
    }

    @Test func machineReportSigningDetailsRoundTrip() throws {
        let report = MachineReport(
            macOSVersion: "26.1", xcodes: [], chip: "M4", performanceCores: 10, memoryGB: 16, freeDiskGB: 100,
            onACPower: true, tools: [:], canSignWithoutPrompt: true, runningJobIDs: [],
            signingIdentities: ["Apple Development: Adam (TEAM)"], xcodeAccountSignedIn: true)
        let data = try JSONCoding.encoder.encode(report)
        #expect(try JSONCoding.decoder.decode(MachineReport.self, from: data) == report)
        #expect(String(decoding: data, as: UTF8.self).contains(#""xcodeAccountSignedIn":true"#))
    }

    @Test func slugRule() {
        #expect(App.slug(for: "Legilo") == "legilo")
        #expect(App.slug(for: "  My  App!! v2 ") == "my-app-v2")
    }
}
