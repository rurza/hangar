import Clocks
import Foundation
import HangarAppStoreConnect
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

/// Scripted App Store Connect: each `builds` call returns the next scripted list (the last one repeats) and every call
/// is recorded.
private final class FakeAppStoreConnect: AppStoreConnectClient {
    enum Call: Equatable {
        case builds(appID: String, version: String?)
        case betaGroups
        case addBuild(buildID: String, groupID: String)
        case setWhatToTest(buildID: String, locale: String, text: String)
        case submitForBetaReview(buildID: String)
    }

    private struct State {
        var polls: [[ASCBuild]]
        var calls: [Call] = []
    }

    private let state: Mutex<State>
    private let groups: [ASCBetaGroup]
    private let addBuildError: ASCError?
    private let reviewError: ASCError?

    init(polls: [[ASCBuild]], groups: [ASCBetaGroup] = [], addBuildError: ASCError? = nil, reviewError: ASCError? = nil) {
        state = Mutex(State(polls: polls))
        self.groups = groups
        self.addBuildError = addBuildError
        self.reviewError = reviewError
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var pollCount: Int { calls.filter { if case .builds = $0 { true } else { false } }.count }

    func builds(appID: String, version: String?) async throws -> [ASCBuild] {
        state.withLock {
            $0.calls.append(.builds(appID: appID, version: version))
            return $0.polls.count > 1 ? $0.polls.removeFirst() : ($0.polls.first ?? [])
        }
    }

    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }

    func apps() async throws -> [ASCApp] { [] }
    func appIconURL(appID: String) async throws -> String? { nil }

    func betaGroups(appID: String) async throws -> [ASCBetaGroup] {
        state.withLock { $0.calls.append(.betaGroups) }
        return groups
    }

    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {
        state.withLock { $0.calls.append(.addBuild(buildID: buildID, groupID: groupID)) }
        if let addBuildError { throw addBuildError }
    }

    func setWhatToTest(buildID: String, locale: String, text: String) async throws {
        state.withLock { $0.calls.append(.setWhatToTest(buildID: buildID, locale: locale, text: text)) }
    }

    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "new", name: name, isInternal: isInternal)
    }

    func submitForBetaReview(buildID: String) async throws {
        state.withLock { $0.calls.append(.submitForBetaReview(buildID: buildID)) }
        if let reviewError { throw reviewError }
    }
}

/// Every stage list a run reported, in order.
private final class StageLog: Sendable {
    private let lists = Mutex<[[StepStage]]>([])
    var all: [[StepStage]] { lists.withLock { $0 } }
    @Sendable func append(_ stages: [StepStage]) async { lists.withLock { $0.append(stages) } }
}

@Suite(.timeLimit(.minutes(1))) struct TestFlightActionTests {
    private static let key = ASCKeyArguments(keyPath: "/k.p8", keyID: "K", issuerID: "I")

    private struct Fixture {
        let directory: String
        let layout: WorkspaceLayout
        let runner = RecordingProcessRunner()
        let clock = TestClock()
        let start: TestClock<Duration>.Instant
        let log = LineSink()

        init() throws {
            start = clock.now
            directory = NSTemporaryDirectory() + "hangar-tf-" + UUID().uuidString
            layout = WorkspaceLayout(dataDirectory: directory, appSlug: "demo", jobID: UUID())
            try FileManager.default.createDirectory(atPath: layout.jobDirectory, withIntermediateDirectories: true)
        }

        func context(
            client: (any AppStoreConnectClient)?, key: ASCKeyArguments? = TestFlightActionTests.key,
            platform: Platform = .iOS, projectDirectory: String = ".", teamID: String? = nil,
            reportStages: @escaping @Sendable ([StepStage]) async -> Void = { _ in }
        ) -> PostActionContext {
            PostActionContext(
                app: App(
                    id: UUID(), slug: "demo", name: "Demo", repoURL: "https://example.com/demo.git",
                    appStoreConnectAppID: "1234", createdAt: Date(timeIntervalSince1970: 0)),
                action: WorkflowAction(scheme: "Demo", platform: platform, export: .appStoreConnect),
                buildNumber: 311, archivePath: layout.archive(scheme: "Demo"), exportedArtifactPath: nil,
                repository: directory + "/repo", projectDirectory: projectDirectory, environment: [:],
                layout: layout, developerDir: "/Xcode", teamID: teamID, key: key, appStoreConnect: client, runner: runner,
                clock: clock, log: log.append, reportStages: reportStages)
        }

        /// Runs the action while a ticker moves the test clock forward until it finishes.
        func run(_ settings: TestFlightSettings, _ context: PostActionContext) async -> Result<PostActionOutput, any Error> {
            let task = Task { try await TestFlightAction(settings: settings).run(context) }
            let ticker = Task {
                while !Task.isCancelled {
                    await clock.advance(by: .seconds(1))
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            let result = await task.result
            ticker.cancel()
            return result
        }

        func writeWhatToTest(_ name: String, _ text: String, in project: String = "repo") throws {
            let folder = directory + "/" + project + "/TestFlight"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try text.write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
        }
    }

    private func build(
        _ id: String, _ state: String, platform: String? = "IOS", version: String = "311"
    ) -> ASCBuild {
        ASCBuild(id: id, version: version, processingState: state, platform: platform, uploadedDate: nil)
    }

    @Test func uploadsThenWaitsUntilValid() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(
            polls: [[build("b1", "PROCESSING")], [build("b1", "PROCESSING")], [build("b1", "VALID")]],
            groups: [ASCBetaGroup(id: "g1", name: "Internal", isInternal: true)])
        var settings = TestFlightSettings()
        settings.groups = ["Internal"]
        let output = try await fixture.run(settings, fixture.context(client: client)).get()

        #expect(client.pollCount == 3)
        #expect(client.calls.first == .builds(appID: "1234", version: "311"))
        // Two 30 s sleeps (the ticker may overshoot by a second or so while the action re-arms its sleep).
        #expect(fixture.start.duration(to: fixture.clock.now) >= .seconds(60))
        #expect(output.summary == "Build 311 (iOS) is VALID in TestFlight; groups: Internal")
        #expect(output.outputs == ["testflight.buildID": "b1", "testflight.processingState": "VALID"])
        #expect(client.calls.contains(.addBuild(buildID: "b1", groupID: "g1")))

        let command = try #require(fixture.runner.commands.first)
        #expect(command.arguments.contains("-exportOptionsPlist"))
        #expect(command.arguments.contains("-exportArchive"))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: fixture.layout.upload + "/ExportOptions.plist")), format: nil)
        #expect((plist as? [String: Any])?["destination"] as? String == "upload")
    }

    @Test func failedProcessingThrows() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [[build("b1", "PROCESSING")], [build("b1", "INVALID")]])
        let result = await fixture.run(TestFlightSettings(), fixture.context(client: client))
        #expect(throws: TestFlightError.processingFailed(state: "INVALID")) { try result.get() }
    }

    @Test func timesOutAfterConfiguredMinutes() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [[build("b1", "PROCESSING")]])
        var settings = TestFlightSettings()
        settings.processingTimeoutMinutes = 1
        let result = await fixture.run(settings, fixture.context(client: client))
        #expect(throws: TestFlightError.processingTimedOut(minutes: 1)) { try result.get() }
        #expect(client.pollCount == 3)
    }

    @Test func notYetListedCountsAsProcessing() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [[], [build("b1", "VALID")]])
        let output = try await fixture.run(TestFlightSettings(), fixture.context(client: client)).get()
        #expect(client.pollCount == 2)
        #expect(output.summary == "Build 311 (iOS) is VALID in TestFlight; groups: none")
        #expect(fixture.log.all.contains("TestFlight processing: not listed yet"))
    }

    @Test func filtersByPlatformAndVersion() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [
            [
                build("mac", "VALID", platform: "MAC_OS"), build("old", "VALID", version: "310"),
                build("ios", "VALID", platform: "IOS"),
            ]
        ])
        let output = try await fixture.run(TestFlightSettings(), fixture.context(client: client)).get()
        #expect(output.outputs["testflight.buildID"] == "ios")
    }

    @Test func unknownGroupIsAWarningAndTheOthersAreStillAdded() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(
            polls: [[build("b1", "VALID")]],
            groups: [
                ASCBetaGroup(id: "g2", name: "Testers", isInternal: false),
                ASCBetaGroup(id: "g1", name: "Internal", isInternal: true),
            ])
        var settings = TestFlightSettings()
        settings.groups = ["Internal", "internal"]
        let output = try await fixture.run(settings, fixture.context(client: client)).get()
        #expect(output.warnings == [
            "Groups: " + TestFlightError.unknownGroup(name: "internal", available: ["Internal", "Testers"]).description
        ])
        #expect(client.calls.contains(.addBuild(buildID: "b1", groupID: "g1")))
        #expect(output.stages?.first { $0.name == "Groups" }?.status == .warning)
    }

    @Test func groupThatGetsEveryBuildIsNotAssigned() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(
            polls: [[build("b1", "VALID")]],
            groups: [
                ASCBetaGroup(id: "g1", name: "Internal", isInternal: true, receivesEveryBuild: true),
                ASCBetaGroup(id: "g2", name: "QA", isInternal: true),
            ])
        var settings = TestFlightSettings()
        settings.groups = ["Internal", "QA"]
        let output = try await fixture.run(settings, fixture.context(client: client)).get()
        #expect(!client.calls.contains(.addBuild(buildID: "b1", groupID: "g1")))
        #expect(client.calls.contains(.addBuild(buildID: "b1", groupID: "g2")))
        #expect(output.warnings.isEmpty)
        #expect(fixture.log.all.contains("TestFlight group Internal receives every build automatically; not adding it"))
        let groups = try #require(output.stages?.first { $0.name == "Groups" })
        #expect(groups == StepStage(name: "Groups", status: .succeeded, detail: "Added to QA; Internal gets every build automatically"))
    }

    @Test func refusalsAfterTheUploadAreWarningsNotFailures() async throws {
        let fixture = try Fixture()
        let refusal = ASCError.http(status: 422, body: #"{"errors":[{"title":"x","detail":"Cannot add internal group to a build."}]}"#)
        let review = ASCError.http(
            status: 422, body: #"{"errors":[{"detail":"Beta App Description is required to submit a build for external testing."}]}"#)
        let client = FakeAppStoreConnect(
            polls: [[build("b1", "VALID")]],
            groups: [ASCBetaGroup(id: "g1", name: "Internal", isInternal: true)],
            addBuildError: refusal, reviewError: review)
        try fixture.writeWhatToTest("WhatToTest.en-US.txt", "Changes")
        var settings = TestFlightSettings()
        settings.groups = ["Internal"]
        settings.submitForExternalReview = true
        let reported = StageLog()
        let output = try await fixture.run(settings, fixture.context(client: client, reportStages: reported.append)).get()
        #expect(output.warnings == [
            "Groups: could not add the build to Internal: Cannot add internal group to a build.",
            "Beta review: Beta App Description is required to submit a build for external testing.",
        ])
        #expect(output.stages?.map(\.name) == ["Upload", "Processing", "Groups", "What to Test", "Beta review"])
        #expect(output.stages?.map(\.status) == [.succeeded, .succeeded, .warning, .succeeded, .warning])
        #expect(output.outputs["testflight.buildID"] == "b1")
        // Progress went out as it happened: the upload was reported running before anything else finished.
        #expect(reported.all.first?.first == StepStage(name: "Upload", status: .running))
        #expect(reported.all.last == output.stages)
    }

    @Test func aFailedUploadMarksItsStageAndFails() async throws {
        let fixture = try Fixture()
        fixture.runner.script({ $0.arguments.contains("-exportArchive") }, lines: [], exitCode: 70)
        let reported = StageLog()
        let result = await fixture.run(TestFlightSettings(), fixture.context(client: FakeAppStoreConnect(polls: []), reportStages: reported.append))
        #expect(throws: (any Error).self) { try result.get() }
        #expect(reported.all.last?.first?.status == .failed)
    }

    @Test func readsWhatToTestPerLocale() async throws {
        let fixture = try Fixture()
        try fixture.writeWhatToTest("WhatToTest.pl.txt", "Zmiany\n")
        try fixture.writeWhatToTest("WhatToTest.en-US.txt", "Changes\n\n")
        try fixture.writeWhatToTest("notes.txt", "ignored")
        let client = FakeAppStoreConnect(polls: [[build("b1", "VALID")]])
        _ = try await fixture.run(TestFlightSettings(), fixture.context(client: client)).get()
        let texts = client.calls.filter { if case .setWhatToTest = $0 { true } else { false } }
        #expect(texts == [
            .setWhatToTest(buildID: "b1", locale: "en-US", text: "Changes"),
            .setWhatToTest(buildID: "b1", locale: "pl", text: "Zmiany"),
        ])
    }

    @Test func readsWhatToTestFromProjectDirectory() async throws {
        let fixture = try Fixture()
        try fixture.writeWhatToTest("WhatToTest.en-US.txt", "Nested", in: "repo/App")
        let client = FakeAppStoreConnect(polls: [[build("b1", "VALID")]])
        _ = try await fixture.run(TestFlightSettings(), fixture.context(client: client, projectDirectory: "App")).get()
        #expect(client.calls.contains(.setWhatToTest(buildID: "b1", locale: "en-US", text: "Nested")))
    }

    @Test func missingWhatToTestFilesAreSkippedAndDisabledSkipsReading() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [[build("b1", "VALID")]])
        _ = try await fixture.run(TestFlightSettings(), fixture.context(client: client)).get()
        #expect(fixture.log.all.contains("no TestFlight/WhatToTest.*.txt; skipping"))

        try fixture.writeWhatToTest("WhatToTest.pl.txt", "Zmiany")
        var settings = TestFlightSettings()
        settings.whatToTest = false
        _ = try await fixture.run(settings, fixture.context(client: client)).get()
        #expect(!client.calls.contains { if case .setWhatToTest = $0 { true } else { false } })
    }

    @Test func submitsForBetaReviewWhenAsked() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [[build("b1", "VALID")]])
        var settings = TestFlightSettings()
        settings.submitForExternalReview = true
        _ = try await fixture.run(settings, fixture.context(client: client)).get()
        #expect(client.calls.last == .submitForBetaReview(buildID: "b1"))
    }

    @Test func noWaitFinishesAfterUpload() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [[build("b1", "VALID")]])
        var settings = TestFlightSettings()
        settings.waitForProcessing = false
        settings.groups = ["Internal"]
        // No client needed: nothing after the upload runs.
        let output = try await fixture.run(settings, fixture.context(client: nil)).get()
        #expect(client.calls.isEmpty)
        #expect(fixture.runner.commands.count == 1)
        #expect(output.summary == "Build 311 (iOS) was accepted by App Store Connect; not waiting for processing")
        #expect(output.outputs.isEmpty)
        #expect(fixture.log.all.contains("not waiting for processing; skipping groups, What to Test and beta review"))
    }

    @Test func uploadsWithoutKeyArgumentsForIndividualKey() async throws {
        let fixture = try Fixture()
        let client = FakeAppStoreConnect(polls: [[build("b1", "VALID")]])
        let output = try await fixture.run(TestFlightSettings(), fixture.context(client: client, key: nil)).get()
        #expect(output.outputs["testflight.processingState"] == "VALID")
        let upload = try #require(fixture.runner.commands.first)
        #expect(upload.arguments.contains("-exportArchive"))
        #expect(upload.arguments.last == "-allowProvisioningUpdates")
        #expect(!upload.arguments.contains { $0.hasPrefix("-authenticationKey") })
    }

    @Test func missingKeyAndClientThrowsNotConfigured() async throws {
        let fixture = try Fixture()
        var settings = TestFlightSettings()
        settings.waitForProcessing = false
        let neither = await fixture.run(settings, fixture.context(client: nil, key: nil))
        #expect(throws: TestFlightError.appStoreConnectNotConfigured) { try neither.get() }
        #expect(fixture.runner.commands.isEmpty)
    }

    @Test func missingClientThrowsNotConfigured() async throws {
        let fixture = try Fixture()
        let noClient = await fixture.run(TestFlightSettings(), fixture.context(client: nil))
        #expect(throws: TestFlightError.appStoreConnectNotConfigured) { try noClient.get() }
        // Fails before the irreversible upload.
        #expect(fixture.runner.commands.isEmpty)
    }

    @Test func uploadPlistCarriesTheTeamOnlyWhenSet() async throws {
        func team(_ teamID: String?) async throws -> String? {
            let fixture = try Fixture()
            var settings = TestFlightSettings()
            settings.waitForProcessing = false
            _ = try await fixture.run(settings, fixture.context(client: nil, teamID: teamID)).get()
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: URL(fileURLWithPath: fixture.layout.upload + "/ExportOptions.plist")), format: nil)
            return (plist as? [String: Any])?["teamID"] as? String
        }
        #expect(try await team("ABCDE12345") == "ABCDE12345")
        #expect(try await team(nil) == nil)
    }

    @Test func registryBuildsTestFlightFromSpec() async throws {
        let action = try PostActionRegistry.make(
            PostActionSpec(name: "testflight", settings: ["wait-for-processing": .bool(false)]))
        #expect(action.name == "testflight")
        let fixture = try Fixture()
        let output = try await action.run(fixture.context(client: nil))
        #expect(output.summary.contains("not waiting for processing"))

        #expect(throws: PostActionError.unknownAction(name: "nope")) {
            try PostActionRegistry.make(PostActionSpec(name: "nope"))
        }
        #expect(throws: WorkflowFileError.self) {
            try PostActionRegistry.make(PostActionSpec(name: "testflight", settings: ["bogus": .bool(true)]))
        }
    }
}
