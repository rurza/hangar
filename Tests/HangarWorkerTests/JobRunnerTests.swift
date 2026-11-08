import Clocks
import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging
import Synchronization
import Testing

@testable import HangarWorker

/// Answers App Store Connect with one processed build, or fails with `failure` as the error's description.
private struct ProcessedBuildClient: AppStoreConnectClient {
    struct Failure: Error, CustomStringConvertible { let description: String }

    var buildID = "asc-build"
    var failure: String?

    func builds(appID: String, version: String?) async throws -> [ASCBuild] {
        if let failure { throw Failure(description: failure) }
        return [ASCBuild(id: buildID, version: version ?? "", processingState: "VALID", platform: "IOS", uploadedDate: nil)]
    }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { [] }
    func appIconURL(appID: String) async throws -> String? { nil }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "new", name: name, isInternal: isInternal)
    }
    func submitForBetaReview(buildID: String) async throws {}
}

/// A `RecordingProcessRunner` that also leaves the files the real tools would: a clone with `ci_scripts`, an archive
/// and an exported `.ipa`. `onCommand` sees every command first.
private final class PipelineRunner: ProcessRunner {
    let recording = RecordingProcessRunner()
    private let onCommand = Mutex<(@Sendable (ProcessCommand) -> Void)?>(nil)

    func whenRunning(_ handler: @escaping @Sendable (ProcessCommand) -> Void) {
        onCommand.withLock { $0 = handler }
    }

    var commands: [ProcessCommand] { recording.commands }

    func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
        onCommand.withLock { $0 }?(command)
        let outcome = try await recording.run(command, onLine: onLine)
        let arguments = command.arguments
        let fileManager = FileManager.default
        // `xcodebuild test` leaves a result bundle whether the tests pass or not.
        if arguments.first == "test", let result = arguments.firstIndex(of: "-resultBundlePath") {
            try fileManager.createDirectory(atPath: arguments[result + 1], withIntermediateDirectories: true)
        }
        guard outcome.exitCode == 0 else { return outcome }
        if arguments.first == "clone", let repository = arguments.last {
            try fileManager.createDirectory(atPath: repository + "/.git", withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: repository + "/ci_scripts", withIntermediateDirectories: true)
            for hook in Hook.allCases {
                let path = repository + "/ci_scripts/" + hook.rawValue
                fileManager.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            }
        } else if arguments.first == "archive", let index = arguments.firstIndex(of: "-archivePath"),
            let result = arguments.firstIndex(of: "-resultBundlePath")
        {
            let archive = arguments[index + 1]
            try fileManager.createDirectory(atPath: arguments[result + 1], withIntermediateDirectories: true)
            let app = archive + "/Products/Applications/Demo.app"
            try fileManager.createDirectory(atPath: app, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: archive + "/dSYMs", withIntermediateDirectories: true)
            try Self.plist(["CFBundleVersion": "1"], to: app + "/Info.plist")
            try Self.plist(["ApplicationProperties": ["CFBundleVersion": "1"]], to: archive + "/Info.plist")
        } else if arguments.contains("-exportArchive"), let index = arguments.firstIndex(of: "-exportPath") {
            // A Developer ID export leaves the .app; App Store exports here stand in with an .ipa.
            let options = arguments.firstIndex(of: "-exportOptionsPlist").flatMap { FileManager.default.contents(atPath: arguments[$0 + 1]) }
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            if options?["method"] as? String == "developer-id" {
                try fileManager.createDirectory(atPath: arguments[index + 1] + "/Demo.app/Contents", withIntermediateDirectories: true)
            } else {
                fileManager.createFile(atPath: arguments[index + 1] + "/Demo.ipa", contents: Data("ipa".utf8))
            }
        }
        return outcome
    }

    private static func plist(_ value: [String: Any], to path: String) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path))
    }
}

/// A value shared with `@Sendable` closures.
private final class Shared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func get() -> Value { value.withLock { $0 } }
    func update(_ change: (inout Value) -> Void) { value.withLock { change(&$0) } }
}

@Suite(.timeLimit(.minutes(1))) struct JobRunnerTests {
    private static let pem = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----\n"
    private static let pemBody = "MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg"
    private static let githubToken = "ghp_0123456789abcdef"
    private static let allSteps = [
        "checkout", "post-clone", "pre-xcodebuild", "archive", "stamp", "export", "post-xcodebuild",
        "post-action:testflight", "upload-artifacts", "cleanup",
    ]

    private struct Fixture {
        let dataDirectory = NSTemporaryDirectory() + "hangar-job-" + UUID().uuidString
        /// Stands in for the per-user temp directory's `hangar-jobs`, so tests never touch the real one.
        let temporaryRoot = NSTemporaryDirectory() + "hangar-job-tmp-" + UUID().uuidString
        let applications: String
        let runner = PipelineRunner()
        let connection: FakeServerConnection
        let clock = TestClock()
        let credentials = Shared<[ASCCredentials]>([])
        var appStoreConnect = ProcessedBuildClient()
        var assignment: JobAssignment
        /// Set by `makeJobKeychain()`: the job then signs with its own keychain, as in a VM guest.
        var keychain: JobKeychain?
        var jobTimeout: Duration?

        init(xcode: String = "27.2", connection: FakeServerConnection = FakeServerConnection()) throws {
            self.connection = connection
            applications = dataDirectory + "-apps"
            try XcodeLocatorTests.makeXcode(
                in: URL(fileURLWithPath: applications), name: "Xcode.app", version: xcode, build: "27C100")
            let job = Job(
                id: UUID(), buildID: UUID(), action: WorkflowAction(scheme: "Demo", platform: .iOS, export: .appStoreConnect),
                status: .assigned, createdAt: Date(timeIntervalSince1970: 0))
            assignment = JobAssignment(
                job: job,
                app: App(
                    id: UUID(), slug: "demo", name: "Demo", repoURL: "https://github.com/acme/demo.git",
                    appStoreConnectAppID: "1234", createdAt: Date(timeIntervalSince1970: 0)),
                workflow: Workflow(
                    project: "Demo.xcodeproj", xcode: "27.2", teamID: "TEAM123", actions: [job.action],
                    postActions: [PostActionSpec(name: "testflight")]),
                workflowName: "release", buildNumber: 311, commit: String(repeating: "a", count: 40), ref: "main",
                environment: [
                    EnvEntry(name: "SIGNING_NOTES", value: "notes", isSecret: true, asFile: true),
                    EnvEntry(name: "HANGAR_GITHUB_TOKEN", value: JobRunnerTests.githubToken, isSecret: true),
                ],
                appStoreConnectKey: AppStoreConnectKey(keyID: "KEY123", issuerID: "issuer-1", privateKey: JobRunnerTests.pem))
        }

        var layout: WorkspaceLayout {
            WorkspaceLayout(
                dataDirectory: dataDirectory, appSlug: "demo", jobID: assignment.job.id, temporaryRoot: temporaryRoot)
        }

        /// Makes the job a test action of `DemoTests` and scripts the simulator list and the result summary.
        mutating func makeTestJob(
            _ action: WorkflowAction = .test(scheme: "DemoTests", platform: .iOS, testPlan: "Smoke"),
            simulators: String = "simctl-devices", summary: String? = "xcresult-summary-passed", summaryJSON: String? = nil
        ) throws {
            assignment.job.action = action
            assignment.workflow.actions = [action]
            let devices = String(decoding: try SimulatorCatalogTests.fixture(simulators), as: UTF8.self)
            // Noise as CoreSimulator writes it to stderr; the live runner drops stderr, the parser skips it anyway.
            runner.recording.script({ $0.arguments.starts(with: ["simctl", "list"]) }, lines: [SimulatorCatalogTests.noise, devices])
            if let summaryJSON {
                runner.recording.script({ $0.arguments.first == "xcresulttool" }, lines: [summaryJSON])
            } else if let summary {
                let json = String(decoding: try SimulatorCatalogTests.fixture(summary), as: UTF8.self)
                runner.recording.script({ $0.arguments.first == "xcresulttool" }, lines: [json])
            } else {
                runner.recording.script({ $0.arguments.first == "xcresulttool" }, lines: ["Error: no result bundle"], exitCode: 1)
            }
        }

        func jobRunner(mode: JobRunner.Mode = .standard) -> JobRunner {
            JobRunner(
                connection: connection, runner: runner,
                locator: XcodeLocator(runner: RecordingProcessRunner(), applicationsDirectory: applications),
                dataDirectory: dataDirectory, temporaryRoot: temporaryRoot, machineName: "Studio", clock: clock,
                appStoreConnectFactory: { [credentials, appStoreConnect] received in
                    credentials.update { $0.append(received) }
                    return appStoreConnect
                },
                keychain: keychain, jobTimeout: jobTimeout, mode: mode)
        }

        func run(
            cancelled: @escaping @Sendable () -> Bool = { false }, stopReason: @escaping @Sendable () -> String? = { nil }
        ) async -> JobResult {
            await jobRunner().run(assignment, cancelled: cancelled, stopReason: stopReason)
        }

        /// As a VM guest runs it: the guest's copy of the assignment, which has no App Store Connect key.
        func runGuest(_ signing: JobRunner.GuestSigning) async -> GuestRunOutcome {
            var guestCopy = assignment
            guestCopy.appStoreConnectKey = nil
            return await jobRunner(mode: .guest(signing)).execute(guestCopy, cancelled: { false }, stopReason: { nil })
        }

        /// Runs while a ticker moves the test clock forward, for steps that wait on it.
        func runTicking(
            cancelled: @escaping @Sendable () -> Bool, stopReason: @escaping @Sendable () -> String? = { nil }
        ) async -> JobResult {
            let ticker = Task {
                while !Task.isCancelled {
                    await clock.advance(by: .seconds(1))
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            defer { ticker.cancel() }
            return await run(cancelled: cancelled, stopReason: stopReason)
        }

        /// A job keychain (password `keychain-secret`, in memory) next to the data directory, as `GuestKeychain`
        /// makes one in a VM; `security` itself is the recording runner's, which answers 0.
        mutating func makeJobKeychain() throws {
            let directory = dataDirectory + "-keychain"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let keychain = JobKeychain(path: directory + "/job.keychain-db", password: SensitiveText("keychain-secret"))
            FileManager.default.createFile(atPath: keychain.path, contents: Data())
            self.keychain = keychain
        }

        func command(_ match: (ProcessCommand) -> Bool) -> ProcessCommand? { runner.commands.first(where: match) }

        func hook(_ hook: Hook) -> ProcessCommand? { command { $0.executable.hasSuffix("/" + hook.rawValue) } }

        func removeAll() {
            try? FileManager.default.removeItem(atPath: dataDirectory)
            try? FileManager.default.removeItem(atPath: temporaryRoot)
            try? FileManager.default.removeItem(atPath: applications)
            try? FileManager.default.removeItem(atPath: dataDirectory + "-keychain")
        }
    }

    private static func isArchive(_ command: ProcessCommand) -> Bool { command.arguments.first == "archive" }

    @Test func happyPathStepOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        // Whether the job's TMPDIR existed when the first hook ran.
        let temporaryExisted = Shared<Bool?>(nil)
        // Whether the App Store Connect key's file existed while each hook and each xcodebuild ran.
        let keyFileSeen = Shared<[String: Bool]>([:])
        fixture.runner.whenRunning { [layout = fixture.layout] command in
            if command.executable.hasSuffix("/" + Hook.postClone.rawValue) {
                temporaryExisted.update { $0 = FileManager.default.fileExists(atPath: layout.temporary) }
            }
            let name = command.executable.hasSuffix("xcodebuild")
                ? command.arguments.first ?? "" : (command.executable as NSString).lastPathComponent
            let exists = FileManager.default.fileExists(atPath: layout.keyDirectory + "/AuthKey_KEY123.p8")
            keyFileSeen.update { $0[name] = ($0[name] ?? false) || exists }
        }

        let result = await fixture.run()

        #expect(result == JobResult(
            status: .succeeded,
            outputs: ["testflight.buildID": "asc-build", "testflight.processingState": "VALID"]))
        #expect(fixture.connection.events.first == .start)
        #expect(fixture.connection.events.last == .finish(result))
        // The worker build first, then the Xcode the job picked.
        #expect(fixture.connection.infos.count == 2)
        #expect(fixture.connection.infos.first?.workerVersion?.hasPrefix(HangarVersion.current) == true)
        #expect(fixture.connection.infos.last?.xcodeVersion == "27.2")
        #expect(fixture.connection.infos.last?.xcodeBuild?.isEmpty == false)
        #expect(fixture.connection.steps.map(\.name) == Self.allSteps.flatMap { [$0, $0] })
        #expect(fixture.connection.steps.map(\.status) == Self.allSteps.flatMap { _ in [.running, .succeeded] })

        let layout = fixture.layout
        let postXcodebuild = try #require(fixture.hook(.postXcodebuild))
        #expect(postXcodebuild.environment["CI_XCODEBUILD_EXIT_CODE"] == "0")
        #expect(postXcodebuild.environment["CI_APP_STORE_SIGNED_APP_PATH"] == layout.export + "/Demo.ipa")
        #expect(postXcodebuild.currentDirectory == layout.repository + "/ci_scripts")
        let postClone = try #require(fixture.hook(.postClone))
        #expect(postClone.environment["CI_BUILD_NUMBER"] == "311")
        #expect(postClone.environment["CI_WORKFLOW"] == "release")
        #expect(postClone.environment["CI_WORKFLOW_ID"] == "release")
        #expect(!postClone.environment.keys.contains { $0.hasPrefix("HANGAR_ASC_") })
        #expect(!postClone.environment.values.contains { $0.contains(Self.pemBody) || $0.contains(layout.keyDirectory) })
        #expect(postClone.environment["DEVELOPER_DIR"] == fixture.applications + "/Xcode.app/Contents/Developer")
        #expect(postClone.environment["TMPDIR"] == fixture.temporaryRoot + "/" + fixture.assignment.job.id.uuidString)
        #expect(postClone.environment["TMPDIR"] == layout.temporary)
        #expect(!layout.temporary.hasPrefix(layout.jobDirectory))
        #expect(temporaryExisted.get() == true)
        #expect(!FileManager.default.fileExists(atPath: layout.temporary))

        let clone = try #require(fixture.command { $0.arguments.first == "clone" })
        #expect(clone.environment["HANGAR_GITHUB_TOKEN"] == Self.githubToken)
        let archive = try #require(fixture.command(Self.isArchive))
        #expect(archive.arguments.contains(layout.keyDirectory + "/AuthKey_KEY123.p8"))
        // The key's file exists only while an xcodebuild step that uses it (or the TestFlight upload) runs.
        let seen = keyFileSeen.get()
        #expect(seen["archive"] == true && seen["-exportArchive"] == true)
        for hook in Hook.allCases { #expect(seen[hook.rawValue] == false, "\(hook.rawValue) saw the key's file") }
        #expect(seen["-resolvePackageDependencies"] == false)
        #expect(fixture.credentials.get().map(\.privateKeyPEM) == [Self.pem])
        #expect(fixture.credentials.get().map(\.keyID) == ["KEY123"])

        #expect(fixture.connection.uploads == ["Demo-dSYMs.zip", "Demo.xcresult.zip", "Demo.ipa", "ExportOptions.plist"])
        // Cleanup: the repository is cleaned and the job directory (secrets included) is gone.
        #expect(fixture.runner.commands.last?.arguments == ["-C", layout.repository, "clean", "-ffdx"])
        #expect(!FileManager.default.fileExists(atPath: layout.jobDirectory))
        #expect(FileManager.default.fileExists(atPath: fixture.dataDirectory + "/jobs"))
    }

    // MARK: Test jobs

    private static let testSteps = ["checkout", "post-clone", "pre-xcodebuild", "test", "post-xcodebuild", "upload-artifacts", "cleanup"]
    private static func isTest(_ command: ProcessCommand) -> Bool { command.arguments.first == "test" }

    @Test func testJobRunsItsStepsWithTheChosenSimulatorAndReportsTheSummary() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeTestJob()

        let result = await fixture.run()

        #expect(result == JobResult(status: .succeeded, outputs: [
            "test.passed": "42", "test.failed": "0", "test.skipped": "0", "test.total": "42", "test.failures": "[]",
        ]))
        // No stamp, export or post-actions, though the workflow has a TestFlight post-action.
        #expect(fixture.connection.finalStatuses.map(\.name) == Self.testSteps)
        #expect(fixture.connection.finalStatuses.allSatisfy { $0.status == .succeeded })

        let layout = fixture.layout
        let test = try #require(fixture.command(Self.isTest))
        #expect(test.arguments.contains("platform=iOS Simulator,id=98DAE3C9-6916-4BC4-89CD-DB0A8BC793CD"))
        #expect(test.arguments.contains("-testPlan"))
        #expect(test.environment["CI_XCODEBUILD_ACTION"] == "test")
        #expect(test.environment["CI_TEST_DESTINATION_DEVICE_TYPE"] == "iPhone 17")
        #expect(test.environment["CI_TEST_DESTINATION_RUNTIME"] == "iOS 27.2")
        #expect(test.environment["CI_TEST_PLAN"] == "Smoke")
        #expect(test.environment["CI_ARCHIVE_PATH"] == nil)
        #expect(test.environment["CI_RESULT_BUNDLE_PATH"] == layout.resultBundle)
        #expect(test.environment["HANGAR_GITHUB_TOKEN"] == nil)
        #expect(test.environment["HANGAR_ASC_KEY_PATH"] == nil)
        #expect(!test.environment.values.contains { $0.contains(Self.githubToken) || $0.contains(Self.pemBody) })
        let simctl = try #require(fixture.command { $0.arguments.starts(with: ["simctl"]) })
        #expect(simctl.discardsStandardError)
        #expect(simctl.environment["DEVELOPER_DIR"] == fixture.applications + "/Xcode.app/Contents/Developer")
        #expect(simctl.environment["HANGAR_GITHUB_TOKEN"] == nil)
        let summary = try #require(fixture.command { $0.arguments.first == "xcresulttool" })
        #expect(summary.environment["HANGAR_GITHUB_TOKEN"] == nil)
        #expect(summary.discardsStandardError)
        #expect(fixture.hook(.postXcodebuild)?.environment["CI_XCODEBUILD_ACTION"] == "test")
        #expect(fixture.hook(.postXcodebuild)?.environment["CI_XCODEBUILD_EXIT_CODE"] == "0")
        #expect(!fixture.runner.commands.contains(where: Self.isArchive))
        #expect(fixture.connection.logLines.contains("Tests: 42 passed · 0 failed · 0 skipped"))
        #expect(fixture.connection.uploads == ["DemoTests.xcresult.zip"])
    }

    @Test func failingTestsFailTheJobWithTheirCountAndList() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeTestJob(summary: "xcresult-summary-failed")
        fixture.runner.recording.script(Self.isTest, lines: ["** TEST FAILED **"], exitCode: 65)

        let result = await fixture.run()

        #expect(result.status == .failed)
        #expect(result.failureReason == "test: 3 tests failed")
        #expect(result.outputs["test.failed"] == "3")
        #expect(result.outputs["test.passed"] == "1")
        let failures = try JSONDecoder().decode([TestFailure].self, from: Data(try #require(result.outputs["test.failures"]).utf8))
        #expect(failures.count == 3)
        #expect(failures[0].message == "XCTAssertTrue failed")
        #expect(fixture.connection.status(of: "test") == .failed)
        #expect(fixture.connection.status(of: "post-xcodebuild") == .succeeded)
        #expect(fixture.hook(.postXcodebuild)?.environment["CI_XCODEBUILD_EXIT_CODE"] == "65")
        #expect(fixture.connection.logLines.contains { $0.contains("SwiftUIRecorderTests/testTabFromAFieldReachesTheRecorder()") })
    }

    @Test func failingTestNamesAndMessagesAreMaskedBeforeEncoding() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        let secret = #"p"ss\word"#
        fixture.assignment.environment.append(EnvEntry(name: "QUOTED_SECRET", value: secret, isSecret: true))
        let failures: [[String: Any]] = [["testIdentifierString": "T/test()", "failureText": "got \(secret) back"]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [
            "passedTests": 0, "failedTests": 1, "testFailures": failures,
        ]), as: UTF8.self)
        try fixture.makeTestJob(summaryJSON: json)
        fixture.runner.recording.script(Self.isTest, lines: [], exitCode: 65)

        let result = await fixture.run()

        let list = try #require(result.outputs["test.failures"])
        #expect(!list.contains("ss\\\\word") && !list.contains("ss\\word"))
        #expect(try JSONDecoder().decode([TestFailure].self, from: Data(list.utf8))
            == [TestFailure(name: "T/test()", message: "got [masked] back")])
    }

    @Test func aTestRunThatBreaksKeepsTheXcodebuildReason() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeTestJob(summary: nil)
        fixture.runner.recording.script(Self.isTest, lines: ["error: build failed"], exitCode: 70)

        let result = await fixture.run()

        // The log's error says more than the exit status, which follows it.
        #expect(result == JobResult(status: .failed, failureReason: "test: error: build failed (xcodebuild exited with 70)"))
    }

    /// A build that fails before any test ran leaves a result bundle with no tests in it: no Tests section then.
    @Test func aBuildFailureReportsNoEmptyTotals() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeTestJob(summary: "xcresult-summary-empty")
        fixture.runner.recording.script(Self.isTest, lines: ["** TEST FAILED **"], exitCode: 65)

        let result = await fixture.run()

        #expect(result == JobResult(status: .failed, failureReason: "test: xcodebuild exited with 65"))
        #expect(!fixture.connection.logLines.contains { $0.hasPrefix("Tests:") })
    }

    @Test func noSimulatorFailsBeforeCheckout() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeTestJob(.test(scheme: "DemoTests", platform: .visionOS))

        let result = await fixture.run()

        #expect(result.failureReason
            == "No visionOS simulator available on Studio; install one in Xcode › Settings › Components")
        #expect(!fixture.runner.commands.contains { $0.arguments.first == "clone" })
        #expect(fixture.connection.finalStatuses.map(\.name) == Self.testSteps)
        #expect(fixture.connection.status(of: "test") == .skipped)
    }

    @Test func anUnknownNamedSimulatorSaysWhichOnesExist() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeTestJob(.test(scheme: "DemoTests", platform: .iOS, destination: "iPhone 99"))

        let result = await fixture.run()

        #expect(result.failureReason?.hasPrefix("No iOS simulator named “iPhone 99” on Studio") == true)
        #expect(result.failureReason?.contains("iPhone 17") == true)
    }

    @Test func macOSTestsNeedNoSimulatorNorAppStoreConnectKey() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeTestJob(.test(scheme: "DemoTests", platform: .macOS))
        fixture.assignment.environment = [EnvEntry(name: "HANGAR_GITHUB_TOKEN", value: Self.githubToken, isSecret: true)]
        fixture.assignment.appStoreConnectKey = nil

        let result = await fixture.run()

        #expect(result.status == .succeeded)
        #expect(!fixture.runner.commands.contains { $0.arguments.starts(with: ["simctl"]) })
        let test = try #require(fixture.command(Self.isTest))
        #expect(test.arguments.contains("platform=macOS"))
        #expect(!test.arguments.contains("-authenticationKeyPath"))
    }

    @Test func archiveFailureStillRunsPostXcodebuildAndUploads() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.runner.recording.script(Self.isArchive, lines: ["** ARCHIVE FAILED **"], exitCode: 65)

        let result = await fixture.run()

        #expect(result == JobResult(status: .failed, failureReason: "archive: xcodebuild exited with 65"))
        #expect(fixture.connection.result == result)
        let statuses = fixture.connection.finalStatuses
        #expect(statuses.map(\.name) == Self.allSteps)
        #expect(statuses.map(\.status) == [
            .succeeded, .succeeded, .succeeded, .failed, .skipped, .skipped, .succeeded, .skipped, .succeeded, .succeeded,
        ])
        let postXcodebuild = try #require(fixture.hook(.postXcodebuild))
        #expect(postXcodebuild.environment["CI_XCODEBUILD_EXIT_CODE"] == "65")
        #expect(postXcodebuild.environment["CI_APP_STORE_SIGNED_APP_PATH"] == nil)
        #expect(!fixture.runner.commands.contains { $0.arguments.contains("-exportArchive") })
        #expect(fixture.connection.logLines.contains("** ARCHIVE FAILED **"))
    }

    @Test func aCondensedArchiveLogUploadsTheFullLogToo() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.runner.recording.script(Self.isArchive, lines: [
            "SwiftDriver Demo normal arm64 com.apple.xcode.tools.swift.compiler (in target 'Demo' from project 'Demo')",
            "    cd /Users/me/w/Demo",
            "    builtin-SwiftDriver -- swiftc -module-name Demo /Users/me/w/Demo/A.swift /Users/me/w/Demo/B.swift",
            "",
            "** ARCHIVE SUCCEEDED **",
        ])

        let result = await fixture.run()

        #expect(result.status == .succeeded)
        #expect(fixture.connection.logLines.contains("▸ Compile Demo (arm64)"))
        #expect(!fixture.connection.logLines.contains { $0.contains("builtin-SwiftDriver") })
        #expect(fixture.connection.uploads.last == "full-log.txt")
    }

    @Test func failedStepNamesTheFirstErrorItsLogShows() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.runner.recording.script(Self.isArchive, lines: [
            "CompileSwift normal arm64 /src/AnalyticsClient+Live.swift",
            "/Users/me/w/BatFiKit/Sources/AnalyticsClient+Live.swift:19:35: error: cannot find 'analyticsDSN' in scope",
            "/Users/me/w/BatFiKit/Sources/Other.swift:3:1: error: a later error",
            "** ARCHIVE FAILED **",
        ], exitCode: 65)

        let result = await fixture.run()

        let cause = "AnalyticsClient+Live.swift:19:35: error: cannot find 'analyticsDSN' in scope (xcodebuild exited with 65)"
        #expect(result.failureReason == "archive: " + cause)
        #expect(fixture.connection.lastUpdate(of: "archive")?.status == .failed)
        #expect(fixture.connection.lastUpdate(of: "archive")?.detail == cause)
    }

    @Test func secretsWipedEvenOnFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        let keyFile = fixture.layout.secrets + "/SIGNING_NOTES"
        let probe = fixture.dataDirectory + "/probe"
        fixture.runner.whenRunning { command in
            // A second name for the key file's inode shows what the wipe left behind.
            if Self.isArchive(command) { _ = link(keyFile, probe) }
        }
        fixture.runner.recording.script(Self.isArchive, lines: [], exitCode: 65)

        let result = await fixture.run()

        #expect(result.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.secrets))
        let wiped = try Data(contentsOf: URL(fileURLWithPath: probe))
        #expect(wiped.count == "notes".utf8.count)
        #expect(wiped.allSatisfy { $0 == 0 })
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
    }

    @Test func logLinesAreMasked() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.runner.recording.script(
            Self.isArchive,
            lines: ["key: " + Self.pemBody, "token=\(Self.githubToken)", "cat key: " + Self.pem])

        let result = await fixture.run()

        #expect(result.status == .succeeded)
        let lines = fixture.connection.logLines
        #expect(lines.contains("key: [masked]"))
        #expect(lines.contains("token=[masked]"))
        #expect(!lines.contains { $0.contains(Self.pemBody) || $0.contains(Self.githubToken) || $0.contains("PRIVATE KEY") })
    }

    @Test func missingXcodeFailsBeforeCheckout() async throws {
        let fixture = try Fixture(xcode: "26.4")
        defer { fixture.removeAll() }

        let result = await fixture.run()

        #expect(result == JobResult(status: .failed, failureReason: "Xcode 27.2 not installed"))
        #expect(fixture.connection.result == result)
        #expect(!fixture.runner.commands.contains { $0.executable == "/usr/bin/git" })
        #expect(fixture.connection.finalStatuses.map(\.status) == [
            .failed, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .succeeded, .succeeded,
        ])
        #expect(fixture.connection.logLines.contains("Xcode 27.2 not installed"))
    }

    @Test(arguments: ["none", "privateKey", "keyID"])
    func missingASCKeyFailsBeforeCheckout(missing: String) async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        switch missing {
        case "none": fixture.assignment.appStoreConnectKey = nil
        case "privateKey": fixture.assignment.appStoreConnectKey?.privateKey = ""
        default: fixture.assignment.appStoreConnectKey?.keyID = ""
        }

        let result = await fixture.run()

        #expect(result == JobResult(
            status: .failed, failureReason: "App Store Connect key not configured; set it in Settings"))
        #expect(fixture.runner.commands.isEmpty)
        #expect(fixture.connection.status(of: "checkout") == .failed)
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.jobDirectory))
    }

    @Test func individualKeyBuildsWithoutKeyArgumentsAndLogsIt() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.assignment.appStoreConnectKey?.issuerID = nil

        let result = await fixture.run()

        #expect(result == JobResult(
            status: .succeeded,
            outputs: ["testflight.buildID": "asc-build", "testflight.processingState": "VALID"]))
        let xcodebuilds = fixture.runner.commands.filter { $0.executable == "/usr/bin/xcodebuild" }
        // Archive, export and TestFlight's upload export, besides package resolution.
        #expect(xcodebuilds.filter { $0.arguments.contains("-allowProvisioningUpdates") }.count == 3)
        for command in xcodebuilds {
            #expect(!command.arguments.contains { $0.hasPrefix("-authenticationKey") })
            #expect(!command.arguments.contains { $0.hasPrefix(fixture.layout.keyDirectory) })
            #expect(!command.environment.keys.contains { $0.hasPrefix("HANGAR_ASC_") })
            #expect(!command.environment.values.contains { $0.contains(Self.pemBody) })
        }
        let notice = "No team API key; xcodebuild signs with the Xcode account on this Mac."
        #expect(fixture.connection.logLines.filter { $0 == notice }.count == 1)
        // The App Store Connect client still gets the individual key.
        #expect(fixture.credentials.get().map(\.keyID) == ["KEY123"])
        #expect(fixture.credentials.get().map(\.issuerID) == [nil])
        #expect(fixture.credentials.get().map(\.privateKeyPEM) == [Self.pem])
    }

    @Test func emptyIssuerIsAnIndividualKey() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.assignment.appStoreConnectKey?.issuerID = ""

        let result = await fixture.run()

        #expect(result.status == .succeeded)
        #expect(!fixture.runner.commands.contains { $0.arguments.contains("-authenticationKeyIssuerID") })
        #expect(fixture.credentials.get().map(\.issuerID) == [nil])
    }

    @Test func teamKeyLogsNoXcodeAccountNotice() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }

        _ = await fixture.run()

        #expect(!fixture.connection.logLines.contains { $0.contains("Xcode account") })
        #expect(fixture.credentials.get().map(\.issuerID) == ["issuer-1"])
    }

    // MARK: A job keychain (VM guest)

    private static func isPartitionList(_ command: ProcessCommand) -> Bool {
        command.standardInput?.value.hasPrefix("set-key-partition-list") == true
    }

    @Test func aJobKeychainIsUnlockedFirstAndCodesignAllowedAfterArchiveAndExport() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeJobKeychain()
        let keychain = try #require(fixture.keychain)

        let result = await fixture.run()

        #expect(result.status == .succeeded)
        let commands = fixture.runner.commands
        let unlock = try #require(commands.firstIndex { $0.standardInput?.value.hasPrefix("unlock-keychain") == true })
        let clone = try #require(commands.firstIndex { $0.arguments.first == "clone" })
        #expect(unlock < clone)
        #expect(commands[unlock].arguments == ["-i"])
        #expect(commands[unlock].standardInput?.value == "unlock-keychain -p keychain-secret \"\(keychain.path)\"\n")
        #expect(commands.contains { $0.arguments == ["default-keychain", "-d", "user", "-s", keychain.path] })
        // After the archive and after the export, before the next step.
        let archive = try #require(commands.firstIndex(where: Self.isArchive))
        let export = try #require(commands.firstIndex { $0.arguments.contains("-exportArchive") })
        #expect(Self.isPartitionList(commands[archive + 1]))
        #expect(Self.isPartitionList(commands[export + 1]))
        #expect(commands[archive + 1].standardInput?.value
            == "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k keychain-secret \"\(keychain.path)\"\n")
        // The password is never an argument and never logged.
        #expect(!commands.contains { $0.arguments.contains { $0.contains("keychain-secret") } })
        #expect(!fixture.connection.logLines.contains { $0.contains("keychain-secret") })
        #expect(fixture.connection.logLines.contains("unlocked the job's keychain (\(keychain.path))"))
    }

    @Test func aFailedArchiveStillLetsCodesignUseItsNewKey() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeJobKeychain()
        fixture.runner.recording.script(Self.isArchive, lines: ["** ARCHIVE FAILED **"], exitCode: 65)

        let result = await fixture.run()

        #expect(result.failureReason == "archive: xcodebuild exited with 65")
        let commands = fixture.runner.commands
        let archive = try #require(commands.firstIndex(where: Self.isArchive))
        #expect(Self.isPartitionList(commands[archive + 1]))
    }

    @Test func aTestWithAJobKeychainAllowsCodesignAfterTheTest() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeJobKeychain()
        try fixture.makeTestJob()

        let result = await fixture.run()

        #expect(result.status == .succeeded)
        let commands = fixture.runner.commands
        // After the test step's xcodebuild and result bundle reading, before the next step.
        let test = try #require(commands.firstIndex(where: Self.isTest))
        let allow = try #require(commands.firstIndex(where: Self.isPartitionList))
        let postXcodebuild = try #require(commands.firstIndex { $0.executable.hasSuffix("/" + Hook.postXcodebuild.rawValue) })
        #expect(test < allow && allow < postXcodebuild)
    }

    @Test func anArchiveWithAJobKeychainAndAnIndividualKeyFailsBeforeCheckout() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeJobKeychain()
        fixture.assignment.appStoreConnectKey?.issuerID = nil

        let result = await fixture.run()

        #expect(result.status == .failed)
        #expect(result.failureReason == "Signing in a VM on Studio needs a team App Store Connect key (with an issuer ID): a VM has no Xcode account. Add the issuer ID in Settings.")
        #expect(!fixture.runner.commands.contains { $0.arguments.first == "clone" })
        #expect(!fixture.runner.commands.contains(where: Self.isArchive))
    }

    @Test func aKeychainThatDoesNotUnlockFailsBeforeCheckout() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        try fixture.makeJobKeychain()
        fixture.runner.recording.script(
            { $0.standardInput?.value.hasPrefix("unlock-keychain") == true }, lines: ["security: SecKeychainUnlock: wrong"], exitCode: 51)

        let result = await fixture.run()

        #expect(result.failureReason == "The job's keychain on Studio is not ready: the job keychain does not unlock with its password")
        #expect(!fixture.runner.commands.contains { $0.arguments.first == "clone" })
    }

    @Test func aWorkerInALoginSessionNeverTouchesAKeychain() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }

        _ = await fixture.run()

        #expect(!fixture.runner.commands.contains { $0.executable == "/usr/bin/security" })
    }

    @Test func cancellationBetweenStepsYieldsCancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        let connection = fixture.connection

        let result = await fixture.run(cancelled: { connection.status(of: "checkout") == .succeeded })

        #expect(result.status == .cancelled)
        #expect(connection.result?.status == .cancelled)
        #expect(connection.finalStatuses.map(\.status) == [
            .succeeded, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .skipped, .succeeded, .succeeded,
        ])
        #expect(fixture.hook(.postClone) == nil)
        #expect(!fixture.runner.commands.contains { $0.executable == "/usr/bin/xcodebuild" })
    }

    @Test func cancellationDuringAStepStopsItsProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.runner.recording.scriptHang(Self.isArchive)
        let archiveStarted = Shared(false)
        fixture.runner.whenRunning { if Self.isArchive($0) { archiveStarted.update { $0 = true } } }

        let result = await fixture.runTicking(cancelled: { archiveStarted.get() })

        #expect(result.status == .cancelled)
        #expect(fixture.connection.status(of: "archive") == .cancelled)
        #expect(fixture.connection.lastUpdate(of: "archive")?.detail == "Cancelled")
        #expect(result.failureReason == nil)
        #expect(fixture.connection.status(of: "post-xcodebuild") == .skipped)
        #expect(fixture.hook(.postXcodebuild) == nil)
        #expect(fixture.connection.status(of: "upload-artifacts") == .succeeded)
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
    }

    @Test func aWorkerStopCancelsTheStepWithItsReasonAndSkipsTheUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.runner.recording.scriptHang(Self.isArchive)
        let archiveStarted = Shared(false)
        fixture.runner.whenRunning { if Self.isArchive($0) { archiveStarted.update { $0 = true } } }
        let reason = "hangar-worker on Studio was stopped (SIGTERM)"

        let result = await fixture.runTicking(
            cancelled: { archiveStarted.get() }, stopReason: { archiveStarted.get() ? reason : nil })

        #expect(result == JobResult(status: .cancelled, failureReason: reason + " during archive"))
        #expect(fixture.connection.result == result)
        #expect(fixture.connection.status(of: "archive") == .cancelled)
        #expect(fixture.connection.lastUpdate(of: "archive")?.detail == "Stopped: " + reason)
        #expect(fixture.connection.status(of: "upload-artifacts") == .skipped)
        #expect(fixture.connection.uploads.isEmpty)
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
        #expect(fixture.connection.logLines.contains("job stopped: \(reason); stopped archive"))
    }

    /// A hung xcodebuild, a codesign prompt or a wedged simctl does not hold the Mac for good: the job is stopped at
    /// its timeout, as a VM job is, and says so.
    @Test func aJobPastItsTimeoutIsStoppedAndSaysWhy() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.jobTimeout = .seconds(60)
        fixture.runner.recording.scriptHang(Self.isArchive)
        let archiveStarted = Shared(false)
        fixture.runner.whenRunning { if Self.isArchive($0) { archiveStarted.update { $0 = true } } }
        // The clock moves only once the archive hangs, so the timeout falls inside it.
        let ticker = Task { [clock = fixture.clock] in
            while !Task.isCancelled {
                if archiveStarted.get() { await clock.advance(by: .seconds(60)) }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { ticker.cancel() }

        let result = await fixture.run()

        let reason = "the job ran longer than 1 min, the job timeout on Studio"
        #expect(result == JobResult(status: .cancelled, failureReason: reason + " during archive"))
        #expect(fixture.connection.lastUpdate(of: "archive")?.detail == "Stopped: " + reason)
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
    }

    @Test func failureReasonAndOutputsAreMasked() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.appStoreConnect.failure = "HTTP 401: {\"detail\": \"bad token \(Self.githubToken)\"}"

        let result = await fixture.run()

        #expect(result.status == .failed)
        #expect(result.failureReason == "post-action:testflight: HTTP 401: {\"detail\": \"bad token [masked]\"}")
        #expect(fixture.connection.result == result)

        var leaking = try Fixture()
        defer { leaking.removeAll() }
        leaking.appStoreConnect.buildID = Self.githubToken
        let succeeded = await leaking.run()
        #expect(succeeded.status == .succeeded)
        #expect(succeeded.outputs["testflight.buildID"] == "[masked]")
    }

    @Test func xcodebuildNeverSeesSecretVariables() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }

        _ = await fixture.run()

        let all = fixture.runner.commands.filter { $0.executable == "/usr/bin/xcodebuild" }
        // Package resolution first, then archive, the export, and TestFlight's upload export.
        #expect(all.count == 4)
        let resolve = try #require(all.first)
        #expect(resolve.arguments.first == "-resolvePackageDependencies")
        let xcodebuilds = Array(all.dropFirst())
        #expect(xcodebuilds.first?.arguments.first == "archive")
        #expect(xcodebuilds.first?.arguments.contains("-disableAutomaticPackageResolution") == true)
        // Resolution gets git's credential helper and the GitHub token on top of the archive's environment, and
        // no other secret.
        let archive = try #require(xcodebuilds.first)
        #expect(resolve.environment == archive.environment.merging(Checkout.credentialEnvironment(token: Self.githubToken)) { _, new in new })
        #expect(resolve.environment["HANGAR_GITHUB_TOKEN"] == Self.githubToken)
        #expect(resolve.environment["GIT_CONFIG_KEY_2"] == "credential.https://github.com.helper")
        #expect(resolve.environment["HANGAR_ASC_KEY_PATH"] == nil)
        #expect(!resolve.environment.values.contains { $0.contains(Self.pemBody) })
        #expect(!resolve.environment.filter { $0.key != "HANGAR_GITHUB_TOKEN" }.values.contains { $0.contains(Self.githubToken) })
        for command in xcodebuilds {
            #expect(command.environment["HANGAR_GITHUB_TOKEN"] == nil)
            #expect(command.environment["HANGAR_ASC_KEY_PATH"] == nil)
            #expect(!command.environment.values.contains { $0.contains(Self.githubToken) || $0.contains(Self.pemBody) })
            #expect(!command.environment.keys.contains { $0.hasPrefix("HANGAR_ASC_") })
            #expect(command.environment["CI_WORKFLOW"] == "release")
        }
        for hook in Hook.allCases {
            let command = try #require(fixture.hook(hook))
            #expect(command.environment["HANGAR_GITHUB_TOKEN"] == Self.githubToken)
            #expect(!command.environment.keys.contains { $0.hasPrefix("HANGAR_ASC_") })
            #expect(!command.environment.values.contains { $0.contains(Self.pemBody) })
        }
    }

    @Test func artifactFailuresDoNotStopTheOthers() async throws {
        let fixture = try Fixture(connection: FakeServerConnection(failUploads: ["Demo.ipa"]))
        defer { fixture.removeAll() }
        fixture.runner.recording.script(
            { $0.executable == "/usr/bin/ditto" && $0.arguments.contains { $0.hasSuffix("/dSYMs") } }, lines: [],
            exitCode: 1)

        let result = await fixture.run()

        #expect(fixture.connection.uploads == ["Demo.xcresult.zip", "ExportOptions.plist"])
        #expect(fixture.connection.status(of: "upload-artifacts") == .failed)
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
        #expect(result.status == .failed)
        #expect(result.failureReason?.hasPrefix("upload-artifacts: ditto exited with status 1 while zipping Demo-dSYMs.zip") == true)
        #expect(result.failureReason?.contains("could not upload Demo.ipa") == true)
    }

    /// A server restarting as the build ends: the upload is tried again, and the build does not fail for it.
    @Test func anUploadTheServerMissedIsTriedAgain() async throws {
        let fixture = try Fixture(connection: FakeServerConnection(unreachableUploads: ["Demo.ipa": 3]))
        defer { fixture.removeAll() }

        let result = await fixture.runTicking(cancelled: { false })

        #expect(result.status == .succeeded)
        #expect(fixture.connection.uploads.contains("Demo.ipa"))
        #expect(fixture.connection.status(of: "upload-artifacts") == .succeeded)
    }

    /// One line per reason, not a dump of the URL error for every artifact.
    @Test func uploadsThatNeverGetThroughFailWithOneShortReason() async throws {
        let fixture = try Fixture(connection: FakeServerConnection(
            unreachableUploads: ["Demo.ipa": .max, "Demo.xcresult.zip": .max, "ExportOptions.plist": .max]))
        defer { fixture.removeAll() }

        let result = await fixture.runTicking(cancelled: { false })

        #expect(result.status == .failed)
        let reason = try #require(result.failureReason)
        #expect(reason.contains(
            "could not upload Demo.xcresult.zip, Demo.ipa and ExportOptions.plist: Could not connect to the server."))
        #expect(!reason.contains("NSURLErrorDomain"))
    }

    @Test func aRefusedLogBatchIsStillDelivered() async throws {
        let fixture = try Fixture(connection: FakeServerConnection(failLogCalls: 1))
        defer { fixture.removeAll() }
        fixture.runner.recording.script(Self.isArchive, lines: ["archived"])

        let result = await fixture.runTicking(cancelled: { false })

        #expect(result.status == .succeeded)
        #expect(fixture.connection.logLines.contains("archived"))
        #expect(fixture.connection.logLines.contains("git clone -- https://github.com/acme/demo.git \(fixture.layout.repository)"))
        #expect(fixture.connection.events.last == .finish(result))
    }

    @Test func aDroppedFinishIsRetried() async throws {
        let fixture = try Fixture(connection: FakeServerConnection(finishErrors: [FakeServerConnection.Unavailable()]))
        defer { fixture.removeAll() }

        let result = await fixture.runTicking(cancelled: { false })

        #expect(result.status == .succeeded)
        #expect(fixture.connection.finishAttempts == 2)
        #expect(fixture.connection.events.last == .finish(result))
    }

    /// Ten minutes of attempts: a server restarting, or a network drop, does not lose a finished build.
    @Test func finishGivesUpAfterTenMinutesAndTreatsAConflictAsDone() async throws {
        #expect(JobRunner.finishRetryDelays.reduce(.zero, +) == .seconds(600))
        let down = try Fixture(connection: FakeServerConnection(finishErrors: Array(repeating: FakeServerConnection.Unavailable(), count: 40)))
        defer { down.removeAll() }
        _ = await down.runTicking(cancelled: { false })
        #expect(down.connection.finishAttempts == JobRunner.finishRetryDelays.count + 1)
        #expect(down.connection.result == nil)

        // 409: the job is already terminal on the server (e.g. failed as lost); nothing to retry.
        let conflict = ServerConnectionError.status(409, method: "POST", path: "/api/v1/worker/jobs/x/finish")
        let terminal = try Fixture(connection: FakeServerConnection(finishErrors: [conflict, conflict]))
        defer { terminal.removeAll() }
        _ = await terminal.runTicking(cancelled: { false })
        #expect(terminal.connection.finishAttempts == 1)
    }

    /// A worker shutting down does not wait out the retries: launchd kills it two minutes after asking it to stop.
    @Test func aWorkerShuttingDownMakesOneLastAttemptToReportTheResult() async throws {
        let connection = FakeServerConnection(finishErrors: Array(repeating: FakeServerConnection.Unavailable(), count: 40))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await JobRunner.reportFinish(
                jobID: UUID(), JobResult(status: .succeeded), connection: connection, clock: TestClock(),
                logger: Logger(label: "test"))
        }
        await task.value
        #expect(connection.finishAttempts == 2)
    }

    /// A 409 at start: the job was handed out twice, or moved or ended meanwhile. The copy that does run it must not
    /// be failed by this one's finish; any other start error is reported.
    @Test func aJobTheServerWouldNotStartHereIsNotFinished() async throws {
        let conflict = ServerConnectionError.status(409, method: "POST", path: "/api/v1/worker/jobs/x/start")
        let refused = try Fixture(connection: FakeServerConnection(startError: conflict))
        defer { refused.removeAll() }
        let result = await refused.runTicking(cancelled: { false })
        #expect(result.status == .failed)
        #expect(refused.connection.events == [.start])
        #expect(refused.connection.finishAttempts == 0)

        let down = try Fixture(connection: FakeServerConnection(startError: FakeServerConnection.Unavailable()))
        defer { down.removeAll() }
        _ = await down.runTicking(cancelled: { false })
        #expect(down.connection.result?.status == .failed)
    }
}

/// A VM archive is split: the guest archives with the server's profiles (or the development key) and hands off after
/// post-xcodebuild; the host exports and uploads with the server's key (security review 2026-11-06, C1).
extension JobRunnerTests {
    private static let profile = JobProvisioningProfile(
        bundleID: "com.acme.demo", name: "Hangar Development com.acme.demo 2026-11-06 0100", uuid: "1111-AAAA", isMac: false,
        content: Data("profile".utf8))
    private static let developmentKey = AppStoreConnectKey(keyID: "DEV1", issuerID: "issuer-1", privateKey: "-----BEGIN PRIVATE KEY-----\nDEVKEY\n-----END PRIVATE KEY-----\n")

    @Test func aGuestArchiveSignsWithTheServersProfilesAndHandsOffWithoutAnyKey() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        let outcome = await fixture.runGuest(JobRunner.GuestSigning(profiles: [Self.profile], notes: ["created development profile x"]))

        let layout = fixture.layout
        guard case .handOff(let handOff) = outcome else {
            Issue.record("expected a hand-off, got \(outcome)")
            return
        }
        #expect(handOff.archivePath == layout.archive(scheme: "Demo"))
        #expect(handOff.resultBundlePath == layout.resultBundle)
        #expect(handOff.testFlightDirectory == layout.repository + "/TestFlight")
        #expect(handOff.fullLogPath == layout.fullLog)
        let archive = try #require(fixture.command(Self.isArchive))
        #expect(!archive.arguments.contains("-allowProvisioningUpdates"))
        #expect(!archive.arguments.contains { $0.hasPrefix("-authenticationKey") })
        let xcconfig = try #require(archive.arguments.firstIndex(of: "-xcconfig").map { archive.arguments[$0 + 1] })
        let text = try String(contentsOfFile: xcconfig, encoding: .utf8)
        #expect(text.contains("CODE_SIGN_STYLE = Manual\n"))
        #expect(text.contains("PROVISIONING_PROFILE_SPECIFIER = $(HANGAR_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:identifier))\n"))
        #expect(text.contains("HANGAR_PROFILE_com_acme_demo = Hangar Development com.acme.demo 2026-11-06 0100\n"))
        // No export in the guest, and post-xcodebuild without the exported product.
        #expect(!fixture.runner.commands.contains { $0.arguments.contains("-exportArchive") })
        let postXcodebuild = try #require(fixture.hook(.postXcodebuild))
        #expect(postXcodebuild.environment["CI_XCODEBUILD_EXIT_CODE"] == "0")
        #expect(postXcodebuild.environment["CI_APP_STORE_SIGNED_APP_PATH"] == nil)
        #expect(fixture.connection.finalStatuses.map(\.name) == [
            "checkout", "post-clone", "pre-xcodebuild", "archive", "stamp", "post-xcodebuild",
        ])
        #expect(fixture.connection.result == nil)
        #expect(fixture.connection.uploads.isEmpty)
        #expect(FileManager.default.fileExists(atPath: layout.archive(scheme: "Demo")))
        #expect(fixture.connection.logLines.contains("created development profile x"))
        #expect(fixture.connection.logLines.contains { $0.contains("no App Store Connect key is in this VM") })
        #expect(fixture.credentials.get().isEmpty)
    }

    @Test func aGuestArchiveWithAMissingProfileSignsWithTheDevelopmentKeyOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        let keyFileSeen = Shared<Bool>(false)
        fixture.runner.whenRunning { [layout = fixture.layout] command in
            if command.arguments.first == "archive" {
                keyFileSeen.update { $0 = FileManager.default.fileExists(atPath: layout.keyDirectory + "/AuthKey_DEV1.p8") }
            }
        }
        let outcome = await fixture.runGuest(JobRunner.GuestSigning(
            developmentKey: Self.developmentKey, missing: [MissingProfile(bundleID: "com.acme.demo.widget", reason: "not registered")]))

        guard case .handOff = outcome else { Issue.record("expected a hand-off, got \(outcome)"); return }
        let archive = try #require(fixture.command(Self.isArchive))
        #expect(archive.arguments.contains("-allowProvisioningUpdates"))
        #expect(archive.arguments.contains("DEV1"))
        #expect(!archive.arguments.contains("KEY123"))
        #expect(keyFileSeen.get())
        #expect(fixture.connection.logLines.contains("no development profile for com.acme.demo.widget: not registered"))
        #expect(fixture.connection.logLines.contains { $0.contains("development key DEV1") })
    }

    @Test func aGuestArchiveThatFailsEndsInTheGuest() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        fixture.runner.recording.script(Self.isArchive, lines: ["error: nope"], exitCode: 65)
        let outcome = await fixture.runGuest(JobRunner.GuestSigning(profiles: [Self.profile]))
        guard case .finished(let result) = outcome else { Issue.record("expected the guest to finish, got \(outcome)"); return }
        #expect(result.status == .failed)
        #expect(fixture.connection.result == result)
        #expect(fixture.connection.status(of: "export") == .skipped)
        #expect(fixture.connection.status(of: "post-action:testflight") == .skipped)
        #expect(fixture.connection.status(of: "post-xcodebuild") == .succeeded)
        #expect(fixture.connection.status(of: "upload-artifacts") != nil)
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
    }

    /// Lays out what the host copies out of the VM: the stamped archive, the result bundle, the TestFlight notes and
    /// the guest's full log.
    private func handedOffFiles(_ fixture: Fixture) throws {
        let layout = fixture.layout
        let fileManager = FileManager.default
        let archive = layout.archive(scheme: "Demo")
        try fileManager.createDirectory(atPath: archive + "/Products/Applications/Demo.app", withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: archive + "/dSYMs", withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: layout.resultBundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: layout.repository + "/TestFlight", withIntermediateDirectories: true)
        try "What to test".write(toFile: layout.repository + "/TestFlight/WhatToTest.en-US.txt", atomically: true, encoding: .utf8)
        try "2026-11-06T01:00:00.000Z [archive] a guest line\n".write(toFile: layout.fullLog, atomically: true, encoding: .utf8)
    }

    @Test func theHostExportsUploadsAndReportsWithTheServersKeyAndNoJobVariables() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        try handedOffFiles(fixture)
        let result = await fixture.jobRunner().runHostExport(fixture.assignment, guestLogAbridged: true, cancelled: { false })

        #expect(result == JobResult(status: .succeeded, outputs: ["testflight.buildID": "asc-build", "testflight.processingState": "VALID"]))
        #expect(fixture.connection.result == result)
        #expect(fixture.connection.finalStatuses.map(\.name) == ["export", "post-action:testflight", "upload-artifacts", "cleanup"])
        #expect(fixture.connection.finalStatuses.allSatisfy { $0.status == .succeeded })
        let exports = fixture.runner.commands.filter { $0.arguments.contains("-exportArchive") }
        #expect(exports.count == 2)  // the export, and TestFlight's upload
        for export in exports {
            #expect(export.arguments.contains(fixture.layout.keyDirectory + "/AuthKey_KEY123.p8"))
            // This Mac's own environment: none of the job's variables, no CI_ names.
            #expect(Set(export.environment.keys).isSubset(of: Set(CIEnvironment.identityEnvironment(from: ProcessInfo.processInfo.environment).keys).union(["PATH", "DEVELOPER_DIR", "TMPDIR"])))
            #expect(!export.environment.values.contains { $0.contains(Self.githubToken) || $0 == "notes" })
        }
        #expect(!fixture.runner.commands.contains { $0.arguments.first == "clone" || $0.arguments.first == "archive" })
        #expect(fixture.connection.uploads.contains("Demo-dSYMs.zip"))
        #expect(fixture.connection.uploads.contains("Demo.xcresult.zip"))
        #expect(fixture.connection.uploads.contains("Demo.ipa"))
        #expect(fixture.connection.uploads.contains(JobLog.fullLogArtifactName))
        #expect(fixture.credentials.get().map(\.keyID) == ["KEY123"])
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.jobDirectory))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.keyDirectory + "/AuthKey_KEY123.p8"))
    }

    /// Build 259: BatFi's VM archive carried Hangar's development profile, and its Developer ID export asked for a
    /// Developer ID profile. The host takes the profile out and re-signs ad hoc before it exports.
    @Test func aDeveloperIDExportFirstTakesHangarsDevelopmentProfileOutOfTheArchive() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        let action = WorkflowAction(scheme: "Demo", platform: .macOS, export: .developerID, notarize: false)
        fixture.assignment.job.action = action
        fixture.assignment.workflow.actions = [action]
        fixture.assignment.workflow.postActions = []
        try handedOffFiles(fixture)
        let app = fixture.layout.archive(scheme: "Demo") + "/Products/Applications/Demo.app"
        try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app + "/Contents/embedded.provisionprofile", contents: Data())
        fixture.runner.recording.script(
            { $0.executable == "/usr/bin/codesign" && $0.arguments.first == "-d" },
            lines: ["<plist version=\"1.0\"><dict><key>com.apple.application-identifier</key><string>T.demo</string></dict></plist>"])

        let result = await fixture.jobRunner().runHostExport(fixture.assignment, guestLogAbridged: false, cancelled: { false })

        #expect(result.status == .succeeded)
        let commands = fixture.runner.commands
        let resign = try #require(commands.firstIndex { $0.executable == "/usr/bin/codesign" && $0.arguments.first == "--force" })
        let export = try #require(commands.firstIndex { $0.arguments.contains("-exportArchive") })
        #expect(resign < export)
        #expect(commands[resign].arguments.last == app)
    }

    /// BatFi 263 left Hangar signed with Developer ID but not notarized: Gatekeeper and Sparkle refused it.
    @Test func aDeveloperIDExportIsNotarizedAndStapledBeforeItIsUploaded() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        let action = WorkflowAction(scheme: "Demo", platform: .macOS, export: .developerID)
        fixture.assignment.job.action = action
        fixture.assignment.workflow.actions = [action]
        fixture.assignment.workflow.postActions = []
        try handedOffFiles(fixture)
        fixture.runner.recording.script(
            { $0.arguments.prefix(2) == ["notarytool", "submit"] },
            lines: [#"{"id":"2efe2717-52ef-43a5-96dc-0797e4ca1041","message":"Processing complete","status":"Accepted"}"#])

        let result = await fixture.jobRunner().runHostExport(fixture.assignment, guestLogAbridged: false, cancelled: { false })

        #expect(result.status == .succeeded)
        #expect(result.outputs == [
            "notarization.submissionID": "2efe2717-52ef-43a5-96dc-0797e4ca1041", "notarization.status": "Accepted",
        ])
        #expect(fixture.connection.finalStatuses.map(\.name) == ["export", "notarize", "upload-artifacts", "cleanup"])
        let commands = fixture.runner.commands
        let export = try #require(commands.firstIndex { $0.arguments.contains("-exportArchive") })
        let submit = try #require(commands.firstIndex { $0.arguments.prefix(2) == ["notarytool", "submit"] })
        let staple = try #require(commands.firstIndex { $0.arguments.prefix(2) == ["stapler", "staple"] })
        let validate = try #require(commands.firstIndex { $0.arguments.prefix(2) == ["stapler", "validate"] })
        let zipApp = try #require(commands.lastIndex { $0.executable == "/usr/bin/ditto" && $0.arguments.last?.hasSuffix("Demo.app.zip") == true })
        #expect(export < submit && submit < staple && staple < validate && validate < zipApp)
        #expect(commands[submit].arguments.contains(fixture.layout.keyDirectory + "/AuthKey_KEY123.p8"))
        #expect(commands[submit].arguments.contains("--wait"))
        #expect(commands[staple].arguments.last == fixture.layout.export + "/Demo.app")
        #expect(commands[zipApp].arguments.contains("--noextattr"))
        #expect(fixture.connection.uploads.contains("Demo.app.zip"))
        #expect(fixture.connection.logLines.contains { $0.contains("submission 2efe2717-52ef-43a5-96dc-0797e4ca1041: Accepted") })
    }

    @Test func anInvalidNotarizationFailsTheJobWithTheNotaryLog() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        let action = WorkflowAction(scheme: "Demo", platform: .macOS, export: .developerID)
        fixture.assignment.job.action = action
        fixture.assignment.workflow.actions = [action]
        fixture.assignment.workflow.postActions = []
        try handedOffFiles(fixture)
        fixture.runner.recording.script(
            { $0.arguments.prefix(2) == ["notarytool", "submit"] },
            lines: [#"{"id":"abc-123","message":"Processing complete","status":"Invalid"}"#], exitCode: 1)
        fixture.runner.recording.script(
            { $0.arguments.prefix(2) == ["notarytool", "log"] },
            lines: [#"{"issues":[{"message":"The binary is not signed with a valid Developer ID certificate."}]}"#])

        let result = await fixture.jobRunner().runHostExport(fixture.assignment, guestLogAbridged: false, cancelled: { false })

        #expect(result.status == .failed)
        #expect(fixture.connection.status(of: "notarize") == .failed)
        #expect(result.failureReason?.contains("Invalid") == true)
        #expect(!fixture.runner.commands.contains { $0.arguments.first == "stapler" })
        #expect(fixture.runner.commands.contains { $0.arguments.prefix(3) == ["notarytool", "log", "abc-123"] })
        #expect(fixture.connection.logLines.contains { $0.contains("not signed with a valid Developer ID certificate") })
    }

    @Test func notarizeFalseSkipsTheNotaryService() async throws {
        var fixture = try Fixture()
        defer { fixture.removeAll() }
        let action = WorkflowAction(scheme: "Demo", platform: .macOS, export: .developerID, notarize: false)
        fixture.assignment.job.action = action
        fixture.assignment.workflow.actions = [action]
        fixture.assignment.workflow.postActions = []
        try handedOffFiles(fixture)
        let result = await fixture.jobRunner().runHostExport(fixture.assignment, guestLogAbridged: false, cancelled: { false })
        #expect(result.status == .succeeded)
        #expect(!fixture.runner.commands.contains { $0.arguments.first == "notarytool" || $0.arguments.first == "stapler" })
        #expect(fixture.connection.status(of: "notarize") == nil)
    }

    @Test func anAppStoreExportLeavesTheArchiveAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.removeAll() }
        try handedOffFiles(fixture)
        let app = fixture.layout.archive(scheme: "Demo") + "/Products/Applications/Demo.app"
        try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app + "/Contents/embedded.provisionprofile", contents: Data())
        _ = await fixture.jobRunner().runHostExport(fixture.assignment, guestLogAbridged: false, cancelled: { false })
        #expect(!fixture.runner.commands.contains { $0.executable == "/usr/bin/codesign" })
    }

    @Test func aHostWithoutTheWorkflowsXcodeFailsTheExport() async throws {
        let fixture = try Fixture(xcode: "26.4")
        defer { fixture.removeAll() }
        try handedOffFiles(fixture)
        let result = await fixture.jobRunner().runHostExport(fixture.assignment, guestLogAbridged: false, cancelled: { false })
        #expect(result.status == .failed)
        #expect(result.failureReason == "Xcode 27.2 not installed")
        #expect(fixture.connection.status(of: "export") == .failed)
        #expect(fixture.connection.status(of: "post-action:testflight") == .skipped)
        #expect(fixture.connection.status(of: "cleanup") == .succeeded)
    }

    @Test func theXcconfigMapsBundleIDsToProfilesAndNothingElse() {
        let signing = JobRunner.GuestSigning(profiles: [
            JobProvisioningProfile(bundleID: "com.acme.app.widget-ext", name: "P1", uuid: "U1", isMac: false, content: Data()),
            JobProvisioningProfile(bundleID: "com.acme.app", name: "iOS Team Provisioning Profile: com.acme.app", uuid: "U2", isMac: false, content: Data()),
            JobProvisioningProfile(bundleID: "com.acme.evil", name: "$(HOME)", uuid: "U3", isMac: false, content: Data()),
        ])
        let lines = signing.xcconfig.split(separator: "\n").map(String.init)
        #expect(lines.contains("HANGAR_PROFILE_com_acme_app = iOS Team Provisioning Profile: com.acme.app"))
        #expect(lines.contains("HANGAR_PROFILE_com_acme_app_widget_ext = P1"))
        #expect(!lines.contains { $0.contains("evil") })
        #expect(JobRunner.GuestSigning.identifier("9lives.app") == "_9lives_app")
    }

    /// Package resource bundles and macros have no profile and no team of their own: "Signing for "GRDB_GRDB" requires
    /// a development team" failed a real Legilo archive until the certificate's team was set for every target.
    @Test func theXcconfigGivesEveryTargetTheCertificatesTeam() {
        func lines(_ teamID: String?) -> [String] {
            JobRunner.GuestSigning(teamID: teamID).xcconfig.split(separator: "\n").map(String.init)
        }
        #expect(lines("YL78V8PY6H").contains("DEVELOPMENT_TEAM = YL78V8PY6H"))
        #expect(!lines(nil).contains { $0.hasPrefix("DEVELOPMENT_TEAM") })
        #expect(!lines("X $(HOME)").contains { $0.hasPrefix("DEVELOPMENT_TEAM") })
    }
}
