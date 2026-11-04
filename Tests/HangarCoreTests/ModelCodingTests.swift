import Foundation
import Testing
@testable import HangarCore

struct ModelCodingTests {
    static let when = Date(timeIntervalSince1970: 1_800_000_000.125)

    static func job() -> Job {
        Job(
            id: UUID(), buildID: UUID(),
            action: ArchiveAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect),
            status: .running, machineID: UUID(),
            steps: [StepRecord(name: StepName.archive, status: .running, startedAt: when)],
            outputs: ["ipa": "a.ipa"], createdAt: when, startedAt: when)
    }

    @Test func jobAssignmentRoundTrips() throws {
        let assignment = JobAssignment(
            job: Self.job(),
            app: App(id: UUID(), slug: "legilo", name: "Legilo", repoURL: "u", appStoreConnectAppID: "1", createdAt: Self.when),
            workflow: Workflow(
                xcode: "27.2", actions: [ArchiveAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect)],
                postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("QA")])])]),
            buildNumber: 42, commit: "abc", ref: "main",
            environment: [EnvEntry(name: "A", value: "b", isSecret: true)])
        let data = try JSONCoding.encoder.encode(assignment)
        #expect(try JSONCoding.decoder.decode(JobAssignment.self, from: data) == assignment)
        #expect(String(decoding: data, as: UTF8.self).contains("2027-01-15T08:00:00.125Z"))
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

    @Test func machineOnlineWindow() {
        let machine = Machine(id: UUID(), name: "m", lastSeenAt: Self.when, createdAt: Self.when)
        #expect(machine.isOnline(now: Self.when.addingTimeInterval(90)))
        #expect(!machine.isOnline(now: Self.when.addingTimeInterval(91)))
        #expect(!Machine(id: UUID(), name: "n", createdAt: Self.when).isOnline(now: Self.when))
    }

    @Test func slugRule() {
        #expect(App.slug(for: "Legilo") == "legilo")
        #expect(App.slug(for: "  My  App!! v2 ") == "my-app-v2")
    }
}
