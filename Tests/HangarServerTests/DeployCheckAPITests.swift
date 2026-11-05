import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

private let testWorkflow = """
    version: 1
    workflows:
      ci:
        project: Legilo.xcodeproj
        xcode: "27.2"
        actions:
          - test: { scheme: LegiloMobile, platform: ios }
          - { scheme: Legilo, platform: macos, export: app-store-connect }
    """

private func report(
    xcode: String = "27.2", tools: [String: String] = ["brew": "/opt/homebrew/bin/brew"], running: [UUID] = [],
    freeDisk: Double = 200, runtimes: [String] = ["iOS 27.2"], capabilities: [String] = WorkerCapability.all
) -> MachineReport {
    MachineReport(
        macOSVersion: "26.1", xcodes: [InstalledXcode(version: xcode, build: "27B48", path: "/Applications/Xcode.app")],
        chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: freeDisk, onACPower: true, tools: tools,
        canSignWithoutPrompt: true, runningJobIDs: running, simulatorRuntimes: runtimes, capabilities: capabilities)
}

private let clock = Date(timeIntervalSince1970: 1_800_000_000)

/// App Store Connect that only knows the app's Beta App Descriptions.
private struct DescriptionASC: AppStoreConnectClient {
    let localizations: [ASCBetaAppLocalization]
    func betaAppLocalizations(appID: String) async throws -> [ASCBetaAppLocalization] { localizations }
    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { [] }
    func appIconURL(appID: String) async throws -> String? { nil }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "x", name: name, isInternal: isInternal)
    }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func submitForBetaReview(buildID: String) async throws {}
}

@Suite(.timeLimit(.minutes(1))) struct DeployCheckAPITests {
    func fixture() throws -> APIFixture {
        let fixture = try APIFixture(now: { clock })
        try fixture.createApp()
        return fixture
    }

    func addMachine(_ fixture: APIFixture, _ name: String, report: MachineReport?, seen: Date = clock) throws -> Machine {
        let (machine, _) = try fixture.server.machines.create(name: name)
        if let report { try fixture.server.machines.updateReport(id: machine.id, report: report, seenAt: seen) }
        return machine
    }

    func check(_ fixture: APIFixture, _ query: String = "workflow=testflight&ref=main") async throws -> DeployCheck {
        let result = Mutex<DeployCheck?>(nil)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/deploy-check?\(query)", method: .get) { response throws in
                #expect(response.status == .ok)
                let decoded = try decode(DeployCheck.self, response)
                result.withLock { $0 = decoded }
            }
        }
        return try #require(result.withLock { $0 })
    }

    @Test func noMachinesBlocksEveryAction() async throws {
        let fixture = try fixture()
        let check = try await check(fixture)
        #expect(!check.canDeploy)
        #expect(check.blocking.map(\.action) == ["Archive – macOS · Legilo", "Archive – iOS · LegiloMobile"])
        #expect(check.machines.isEmpty)
    }

    @Test func anOfflineMachineBlocksByTheServersClock() async throws {
        let fixture = try fixture()
        _ = try addMachine(fixture, "mini", report: report(), seen: clock.addingTimeInterval(-120))
        let check = try await check(fixture)
        #expect(!check.canDeploy)
        #expect(check.blocking.first?.reasons == ["mini": ["offline"]])
        #expect(check.machines.map(\.online) == [false])
    }

    @Test func aMissingXcodeBlocks() async throws {
        let fixture = try fixture()
        _ = try addMachine(fixture, "mini", report: report(xcode: "26.1"))
        let check = try await check(fixture)
        #expect(!check.canDeploy)
        #expect(check.blocking.first?.reasons["mini"] == ["Xcode 27.2 not installed"])
        #expect(check.machines.first?.problems == ["Xcode 27.2 not installed"])
    }

    @Test func aTestJobOnAnOutdatedWorkerBlocksOnlyTheTest() async throws {
        let fixture = try fixture()
        fixture.host.state.withLock { $0.files[WorkflowFile.path] = testWorkflow }
        _ = try addMachine(fixture, "mini", report: report(capabilities: []))
        let check = try await check(fixture, "workflow=ci&ref=main")
        #expect(!check.canDeploy)
        #expect(check.blocking.map(\.action) == ["Test – iOS · LegiloMobile"])
        #expect(check.blocking.first?.reasons["mini"] == ["update the worker (run the install command again)"])
    }

    @Test func aBusyMachineIsAWarningNotABlocker() async throws {
        let fixture = try fixture()
        let machine = try addMachine(fixture, "mini", report: report(freeDisk: 5))
        // Its one slot is taken by a running job.
        let other = try await fixture.server.buildService.deploy(DeployRequest(app: "legilo", workflow: "beta", ref: "main"))
        _ = try fixture.server.builds.assign(jobID: other.jobs[0].id, to: machine.id, at: clock)
        let check = try await check(fixture)
        #expect(check.canDeploy)
        #expect(check.blocking.isEmpty)
        #expect(check.warnings.first?.reasons["mini"]?.contains("busy") == true)
        #expect(check.machines.first?.problems == [])
    }

    @Test func aPausedMachineIsAWarningNotABlocker() async throws {
        let fixture = try fixture()
        let machine = try addMachine(fixture, "mini", report: report())
        _ = try fixture.server.machines.setPaused(id: machine.id, true)
        let answer = try await check(fixture)
        #expect(answer.canDeploy)
        #expect(answer.blocking.isEmpty)
        #expect(answer.warnings.map(\.action) == ["Archive – macOS · Legilo", "Archive – iOS · LegiloMobile"])
        #expect(answer.warnings.first?.reasons == ["mini": ["builds paused"]])
        let judged = try #require(answer.machines.first)
        #expect(judged.paused && judged.online)
        #expect(judged.problems.isEmpty && judged.waits == ["builds paused"])

        // Pinned to it, the build waits too.
        let pinned = try await check(fixture, "workflow=testflight&ref=main&machine=mini")
        #expect(pinned.canDeploy && pinned.blocking.isEmpty && pinned.warnings.count == 2)
    }

    @Test func aPausedMachineStillBlocksForWhatItLacks() async throws {
        let fixture = try fixture()
        let machine = try addMachine(fixture, "mini", report: report(xcode: "26.1"))
        _ = try fixture.server.machines.setPaused(id: machine.id, true)
        let answer = try await check(fixture)
        #expect(!answer.canDeploy)
        #expect(answer.blocking.first?.reasons["mini"] == ["builds paused", "Xcode 27.2 not installed"])
        #expect(answer.machines.first?.problems == ["Xcode 27.2 not installed"])
        #expect(answer.machines.first?.waits == ["builds paused"])
    }

    @Test func aDeployToOnlyPausedMachinesQueuesAndWaits() async throws {
        let fixture = try fixture()
        let machine = try addMachine(fixture, "mini", report: report())
        _ = try fixture.server.machines.setPaused(id: machine.id, true)
        let build = try await fixture.server.buildService.deploy(DeployRequest(app: "legilo", workflow: "testflight", ref: "main"))
        try await fixture.server.scheduler.tick()
        for job in build.jobs {
            let waiting = try #require(try fixture.server.builds.job(id: job.id))
            #expect(waiting.status == .queued)
            #expect(waiting.queueNote == "mini: builds paused")
        }
    }

    @Test func aPinnedMachineIsJudgedAlone() async throws {
        let fixture = try fixture()
        _ = try addMachine(fixture, "good", report: report())
        _ = try addMachine(fixture, "old", report: report(xcode: "26.1"))
        #expect(try await check(fixture).canDeploy)
        let pinned = try await check(fixture, "workflow=testflight&ref=main&machine=old")
        #expect(!pinned.canDeploy)
        #expect(pinned.machines.map(\.name) == ["old"])
    }

    @Test func checksAtACommitAskTheRepositoryOnceThenNever() async throws {
        let fixture = try fixture()
        _ = try addMachine(fixture, "mini", report: report())
        let commit = fixture.host.state.withLock { $0.commit }
        for _ in 0..<3 {
            #expect(try await check(fixture, "workflow=testflight&commit=\(commit)").canDeploy)
        }
        let state = fixture.host.state.withLock { $0 }
        #expect(state.refs.isEmpty)  // never resolved: the sheet passes the commit it already has
        #expect(state.reads == [WorkflowFile.path])  // read once, then cached per commit
    }

    @Test func aStoredWorkflowNeedsNoRepositoryAtAll() async throws {
        let fixture = try fixture()
        let yaml = fixture.host.state.withLock { $0.files[WorkflowFile.path]! }
        try fixture.server.workflowFiles.set(appID: try #require(try fixture.server.apps.find(slugOrID: "legilo")).id, yaml: yaml)
        let commit = fixture.host.state.withLock { $0.commit }
        _ = try await check(fixture, "workflow=testflight&commit=\(commit)")
        _ = try await check(fixture, "workflow=testflight&commit=\(commit)")
        let state = fixture.host.state.withLock { $0 }
        #expect(state.refs.isEmpty && state.reads.isEmpty)
    }

    @Test func warnsAboutScriptsBeforeTheBuildRuns() async throws {
        let fixture = try fixture()
        _ = try addMachine(fixture, "mini", report: report())
        let app = try #require(try fixture.server.apps.find(slugOrID: "legilo"))
        try fixture.server.variables.set(scope: .app(app.id), name: "SENTRY_ORG", input: VariableInput(value: "acme"))
        fixture.host.state.withLock { state in
            state.tree = RepositoryTree(
                paths: ["ci_scripts", "ci_scripts/ci_post_clone.sh", "ci_scripts/ci_post_xcodebuild.sh", "ci_scripts/nested/x.sh", "README.md"],
                executables: ["ci_scripts/ci_post_xcodebuild.sh"])
            state.files["ci_scripts/ci_post_clone.sh"] = "#!/bin/sh\ncd $CI_PRIMARY_REPOSITORY_PATH\necho \"$SENTRY_DSN\" > dsn\n"
            state.files["ci_scripts/ci_post_xcodebuild.sh"] = "#!/bin/sh\nsentry-cli --org $SENTRY_ORG --auth-token $SENTRY_AUTH_TOKEN\n"
        }
        let commit = fixture.host.state.withLock { $0.commit }

        let first = try await check(fixture, "workflow=testflight&commit=\(commit)")

        #expect(first.canDeploy)
        let check = first
        #expect(check.notices.map(\.code) == ["undefined-variables", "undefined-variables", "script-not-executable"])
        #expect(check.notices[0].message.hasPrefix("ci_scripts/ci_post_clone.sh uses $SENTRY_DSN, which isn’t defined in Hangar"))
        #expect(check.notices[1].message.hasPrefix("ci_scripts/ci_post_xcodebuild.sh uses $SENTRY_AUTH_TOKEN,"))
        #expect(check.notices[2].message.hasPrefix("ci_scripts/ci_post_clone.sh isn’t executable"))

        // Read once per commit, however often the sheet asks.
        _ = try await self.check(fixture, "workflow=testflight&commit=\(commit)")
        let state = fixture.host.state.withLock { $0 }
        #expect(state.treeReads == 1)
        #expect(state.reads.filter { $0.hasPrefix("ci_scripts/") }.sorted() == ["ci_scripts/ci_post_clone.sh", "ci_scripts/ci_post_xcodebuild.sh"])
    }

    @Test func aRepositoryThatCannotBeReadOnlyMeansNoNotices() async throws {
        let fixture = try fixture()
        _ = try addMachine(fixture, "mini", report: report())
        fixture.host.state.withLock { $0.treeError = .http(status: 500, body: "boom") }
        let check = try await check(fixture)
        #expect(check.canDeploy)
        #expect(check.notices.isEmpty)
    }

    @Test func warnsWhenExternalReviewHasNoBetaAppDescription() async throws {
        let localizations = [ASCBetaAppLocalization(locale: "en-US", description: " ")]
        let fixture = try APIFixture(
            appStoreConnectFactory: { _ in DescriptionASC(localizations: localizations) }, now: { clock })
        try fixture.createApp()
        try fixture.server.variables.set(scope: .global, name: "HANGAR_ASC_KEY_ID", input: VariableInput(value: "K"))
        try fixture.server.variables.set(
            scope: .global, name: "HANGAR_ASC_KEY_PATH", input: VariableInput(value: "pem", isSecret: true, asFile: true))
        _ = try addMachine(fixture, "mini", report: report())
        fixture.host.state.withLock {
            $0.files[WorkflowFile.path] = """
                version: 1
                workflows:
                  external:
                    project: Legilo.xcodeproj
                    xcode: "27.2"
                    actions:
                      - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
                    post-actions:
                      - testflight: { groups: [Public], submit-for-external-review: true }
                  internal:
                    project: Legilo.xcodeproj
                    xcode: "27.2"
                    actions:
                      - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
                    post-actions:
                      - testflight: { groups: [Internal] }
                """
        }
        let external = try await check(fixture, "workflow=external&ref=main")
        #expect(external.notices.map(\.code) == ["beta-app-description-missing"])
        #expect(external.notices.first?.message.contains("TestFlight › Test Information") == true)
        #expect(try await check(fixture, "workflow=internal&ref=main").notices.isEmpty)
    }

    @Test func aMalformedCommitIsRefused() async throws {
        let fixture = try fixture()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/deploy-check?workflow=testflight&commit=main", method: .get) { response throws in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func actionsAreLabelledLikeTheWorkflowAction() {
        let action = WorkflowAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect)
        #expect(HangarServerApp.label(action) == "\(action.kindLabel) · Legilo")
    }

    /// Names as the wizard allows them, sent the way URLSearchParams (`+` for a space) and encodeURIComponent (`%20`) send them.
    @Test(arguments: [
        ("UX Review Keep", ["UX+Review+Keep", "UX%20Review%20Keep"]),
        ("A+B", ["A%2BB"]),
        ("R&D", ["R%26D"]),
        ("Wydanie łódź", ["Wydanie+%C5%82%C3%B3d%C5%BA", "Wydanie%20%C5%82%C3%B3d%C5%BA"]),
    ])
    func aWorkflowNameIsReadAsAFormEncodesIt(name: String, encodings: [String]) async throws {
        let fixture = try fixture()
        let yaml = testWorkflow.replacingOccurrences(of: "  ci:", with: "  \"\(name)\":")
        fixture.host.state.withLock { $0.files[WorkflowFile.path] = yaml }
        _ = try addMachine(fixture, "mini", report: report())
        for encoded in encodings {
            #expect(try await check(fixture, "workflow=\(encoded)&ref=main").canDeploy, "\(encoded)")
        }
    }

    @Test func anUnknownWorkflowIsAnError() async throws {
        let fixture = try fixture()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/deploy-check?workflow=nope&ref=main", method: .get) { response throws in
                #expect(try decode(APIError.self, response).code == "workflow_not_found")
            }
        }
    }
}
