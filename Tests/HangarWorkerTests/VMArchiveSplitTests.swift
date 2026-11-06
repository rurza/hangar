import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

/// Leaves what `tar` would when the host copies a path out of the VM (`GuestSSH.fetch`), and an `.ipa` for an export.
final class FetchingRunner: ProcessRunner {
    let recording = RecordingProcessRunner()
    /// A link to put into the copied archive, to check that the host refuses it.
    let planted = Mutex<String?>(nil)

    var commands: [ProcessCommand] { recording.commands }

    func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
        let outcome = try await recording.run(command, onLine: onLine)
        let fileManager = FileManager.default
        if command.executable == "/bin/sh", let script = command.arguments.last, script.contains("/usr/bin/tar -xf - --no-same-owner -C "),
            let staging = script.components(separatedBy: " -C ").last,
            let name = script.components(separatedBy: " -cf - ").last?.components(separatedBy: "'").first
        {
            let root = staging + "/" + name
            switch (name as NSString).pathExtension {
            case "xcarchive":
                try fileManager.createDirectory(atPath: root + "/Products/Applications/Demo.app", withIntermediateDirectories: true)
                try fileManager.createDirectory(atPath: root + "/dSYMs", withIntermediateDirectories: true)
                if let target = planted.withLock({ $0 }) {
                    try fileManager.createSymbolicLink(atPath: root + "/Products/Applications/Demo.app/token", withDestinationPath: target)
                }
            case "xcresult": try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
            case "txt": try "guest line\n".write(toFile: root, atomically: true, encoding: .utf8)
            default:
                try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
                try "notes".write(toFile: root + "/WhatToTest.en-US.txt", atomically: true, encoding: .utf8)
            }
        }
        if command.arguments.contains("-exportArchive"), let index = command.arguments.firstIndex(of: "-exportPath") {
            fileManager.createFile(atPath: command.arguments[index + 1] + "/Demo.ipa", contents: Data("ipa".utf8))
        }
        return outcome
    }
}

@Suite(.timeLimit(.minutes(1))) struct VMArchiveSplitTests {
    static let handOff = ArchiveHandOff(
        archivePath: "/Volumes/workspace/hangar/jobs/demo/J/Demo.xcarchive",
        resultBundlePath: "/Volumes/workspace/hangar/jobs/demo/J/Demo.xcresult",
        testFlightDirectory: "/Volumes/workspace/hangar/jobs/demo/J/repo/TestFlight",
        fullLogPath: "/Volumes/workspace/hangar/jobs/demo/J/full-log.txt", fullLogAbridged: true)

    struct Setup {
        let fixture: VMFixture
        let engine = FakeEngine()
        let runner = FetchingRunner()
        let connection = FakeTokenConnection()
        let launcher: FakeSessionLauncher
        let applications = NSTemporaryDirectory() + "hangar-vm-apps-" + UUID().uuidString

        init(script: @escaping @Sendable (FakeGuestSession, String) -> Void = VMArchiveSplitTests.handingOff) throws {
            fixture = try VMFixture()
            try fixture.saveSlot(0)
            launcher = FakeSessionLauncher(script: script)
            try XcodeLocatorTests.makeXcode(
                in: URL(fileURLWithPath: applications), name: "Xcode.app", version: "27.2", build: "27C100")
        }

        func jobRunner() -> VMJobRunner {
            var launcherConfig = VMLauncher(host: fixture.host(engine, runner: runner))
            launcherConfig.pollInterval = .milliseconds(10)
            var jobRunner = VMJobRunner(
                launcher: launcherConfig, connection: connection, serverURL: URL(string: "http://mini:8787")!,
                identity: VMIdentityStore(dataDirectory: fixture.root), slots: VMSlotPool(count: 1),
                workerBinary: "/usr/local/bin/hangar-worker", sessions: launcher, cancelGrace: .seconds(5))
            jobRunner.hostLocator = XcodeLocator(runner: RecordingProcessRunner(), applicationsDirectory: applications)
            return jobRunner
        }

        func cleanUp() {
            fixture.cleanUp()
            try? FileManager.default.removeItem(atPath: applications)
        }
    }

    /// The guest answers the bundle with a hand-off, as `run-job` does for an archive that got through post-xcodebuild.
    static func handingOff(_ session: FakeGuestSession, _ line: String) {
        guard line.hasPrefix("{") else { return }
        session.print(GuestJobRunner.outcomeLine(.handOff(handOff)))
        session.end(0)
    }

    static func archive() -> JobAssignment {
        var assignment = WorkerLoopTests.assignment()
        assignment.appStoreConnectKey = VMJobRunnerTests.key
        assignment.signingIdentity = JobSigningIdentity(p12: Data("p12".utf8), password: "pw")
        assignment.environment = [EnvEntry(name: "SENTRY_AUTH_TOKEN", value: "sentry-secret", isSecret: true)]
        return assignment
    }

    @Test func aHandedOffArchiveIsCopiedOutOfTheVMAndExportedOnTheHost() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let assignment = Self.archive()
        let result = await setup.jobRunner().run(assignment, cancelled: { false }, stopReason: { nil })

        #expect(result.status == .succeeded, "\(result)")
        // The host reported the export's steps and the result with its own connection.
        let base = setup.connection.base
        #expect(base.result == result)
        #expect(base.finalStatuses.map(\.name) == ["export", "upload-artifacts", "cleanup"])
        #expect(base.uploads.contains("Demo.ipa") && base.uploads.contains("Demo-dSYMs.zip") && base.uploads.contains("full-log.txt"))
        // Copied out with tar over SSH, then the VM stopped before anything exported.
        let commands = setup.runner.commands
        let fetches = commands.filter { $0.executable == "/bin/sh" && $0.arguments.last?.contains("tar -xf -") == true }
        #expect(fetches.count == 4)
        let export = try #require(commands.firstIndex { $0.arguments.contains("-exportArchive") })
        #expect(commands[export].arguments.contains("-authenticationKeyID"))
        #expect(!commands[export].environment.values.contains("sentry-secret"))
        #expect(setup.engine.machines.first?.calls.last == .stop)
        // The guest never saw the key.
        let bundleLine = try #require(setup.launcher.sessions.first?.sent.first)
        #expect(!bundleLine.contains("ADMIN"))
        #expect(try JSONCoding.decoder.decode(GuestJobBundle.self, from: Data(bundleLine.utf8)).assignment.appStoreConnectKey == nil)
        #expect(setup.connection.revoked == [assignment.job.id])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: setup.fixture.storage.jobs)) ?? [] == [])
    }

    @Test func anArchiveWithALinkOutOfItIsNotExported() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        setup.runner.planted.withLock { $0 = "/Users/hangar/.hangar/machine-token" }
        let result = await setup.jobRunner().run(Self.archive(), cancelled: { false }, stopReason: { nil })
        #expect(result.status == .failed)
        #expect(result.failureReason?.contains("is a link to /Users/hangar/.hangar/machine-token, outside it") == true)
        #expect(!setup.runner.commands.contains { $0.arguments.contains("-exportArchive") })
        #expect(setup.connection.base.result == result)
    }

    @Test func handedOffPathsThatAreNotAnArchivesAreRefused() async throws {
        let setup = try Setup { session, line in
            guard line.hasPrefix("{") else { return }
            var handOff = VMArchiveSplitTests.handOff
            handOff.archivePath = "/"
            session.print(GuestJobRunner.outcomeLine(.handOff(handOff)))
            session.end(0)
        }
        defer { setup.cleanUp() }
        let result = await setup.jobRunner().run(Self.archive(), cancelled: { false }, stopReason: { nil })
        #expect(result.failureReason == "the build VM handed off paths that are not an archive's")
        #expect(!setup.runner.commands.contains { $0.arguments.last?.contains("tar -xf -") == true })
    }

    @Test func aMissingIOSProfileWithoutADevelopmentKeyFailsBeforeTheVMStarts() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        setup.connection.provisioningAnswer.withLock {
            $0 = .success(JobProvisioning(missing: [MissingProfile(bundleID: "com.acme.demo", reason: "the bundle ID is not registered for this team")]))
        }
        let result = await setup.jobRunner().run(Self.archive(), cancelled: { false }, stopReason: { nil })
        #expect(result.status == .failed)
        #expect(result.failureReason?.contains("com.acme.demo: the bundle ID is not registered for this team") == true)
        #expect(result.failureReason?.contains("Settings › App Store Connect") == true)
        #expect(setup.engine.machines.isEmpty)
        #expect(setup.connection.issued.isEmpty)
    }

    @Test func aMissingProfileWithTheDevelopmentKeyGoesToTheGuestWithIt() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let key = AppStoreConnectKey(keyID: "DEV1", issuerID: "issuer", privateKey: "DEVPEM")
        setup.connection.provisioningAnswer.withLock {
            $0 = .success(JobProvisioning(missing: [MissingProfile(bundleID: "com.acme.demo", reason: "r")], developmentKey: key))
        }
        _ = await setup.jobRunner().run(Self.archive(), cancelled: { false }, stopReason: { nil })
        let bundleLine = try #require(setup.launcher.sessions.first?.sent.first)
        let bundle = try JSONCoding.decoder.decode(GuestJobBundle.self, from: Data(bundleLine.utf8))
        #expect(bundle.signing?.developmentKey == key)
        #expect(!bundleLine.contains("ADMIN"))
        #expect(setup.connection.provisioningRequests == [JobProvisioningRequest(useServerIdentity: true)])
    }

    @Test func aMacArchiveWithAMissingProfileStillRuns() {
        let provisioning = JobProvisioning(missing: [MissingProfile(bundleID: "com.acme.mac", reason: "r")])
        #expect(VMJobRunner.signingProblem(provisioning, platform: .macOS) == nil)
        #expect(VMJobRunner.signingProblem(provisioning, platform: .iOS) != nil)
        #expect(VMJobRunner.signingProblem(JobProvisioning(), platform: .iOS) == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct GuestCopyTests {
    static func root() throws -> String {
        let root = NSTemporaryDirectory() + "hangar-copy-" + UUID().uuidString + "/Demo.xcarchive"
        try FileManager.default.createDirectory(atPath: root + "/Products/Applications/Demo.app/Frameworks/K.framework/Versions/A", withIntermediateDirectories: true)
        return root
    }

    @Test func linksInsideTheCopyAreFine() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let framework = root + "/Products/Applications/Demo.app/Frameworks/K.framework"
        try FileManager.default.createSymbolicLink(atPath: framework + "/Versions/Current", withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework + "/K", withDestinationPath: "Versions/Current/K")
        try GuestCopy.check(root)
    }

    @Test(arguments: ["/etc/passwd", "../../../../outside", "../../../../../Demo.xcarchive-sibling"])
    func linksThatLeaveTheCopyAreRefused(target: String) throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try FileManager.default.createSymbolicLink(atPath: root + "/Products/Applications/Demo.app/x", withDestinationPath: target)
        #expect(throws: GuestCopy.Problem.self) { try GuestCopy.check(root) }
    }

    @Test func aFIFOIsRefused() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        #expect(mkfifo(root + "/Products/pipe", 0o600) == 0)
        #expect(throws: GuestCopy.Problem.notAFile("Products/pipe")) { try GuestCopy.check(root) }
    }

    @Test func theGuestInstallsTheProfilesWhereXcodeLooks() throws {
        let home = NSTemporaryDirectory() + "hangar-home-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try GuestJobRunner.installProfiles([
            JobProvisioningProfile(bundleID: "a", name: "A", uuid: "AAAA-1111", isMac: false, content: Data("ios".utf8)),
            JobProvisioningProfile(bundleID: "b", name: "B", uuid: "../../evil", isMac: true, content: Data("mac".utf8)),
        ], home: home)
        for directory in GuestJobRunner.profileDirectories(home: home) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory).sorted() == ["AAAA-1111.mobileprovision", "e.provisionprofile"])
        }
    }
}
