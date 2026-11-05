import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct ArchiveStepTests {
    private static let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let layout = WorkspaceLayout(dataDirectory: "/data", appSlug: "legilo", jobID: jobID)
    private static let key = ASCKeyArguments(environment: [
        "HANGAR_ASC_KEY_PATH": "/data/secrets/key.p8", "HANGAR_ASC_KEY_ID": "KEY123", "HANGAR_ASC_ISSUER_ID": "ISSUER-UUID",
    ])!
    private static let keyArguments = [
        "-authenticationKeyPath", "/data/secrets/key.p8", "-authenticationKeyID", "KEY123",
        "-authenticationKeyIssuerID", "ISSUER-UUID",
    ]
    private static let tail = [
        "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "-skipMacroValidation",
        "-skipPackagePluginValidation", "-disableAutomaticPackageResolution",
    ]

    private func command(
        _ workflow: Workflow, _ action: WorkflowAction, key: ASCKeyArguments? = ArchiveStepTests.key
    ) -> ProcessCommand {
        ArchiveStep.command(
            workflow: workflow, action: action, repository: Self.layout.repository, layout: Self.layout,
            developerDir: "/Applications/Xcode-27.2.app/Contents/Developer", key: key,
            environment: ["PATH": "/usr/bin:/bin"])
    }

    @Test func legiloMobileCommand() {
        let action = WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect)
        let workflow = Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action])
        let command = command(workflow, action)
        #expect(command.executable == "/usr/bin/xcodebuild")
        #expect(
            command.arguments
                == [
                    "archive", "-project", "/data/workspaces/legilo/repository/Legilo.xcodeproj",
                    "-scheme", "LegiloMobile", "-destination", "generic/platform=iOS",
                    "-archivePath", "/data/jobs/\(Self.jobID.uuidString)/archive/LegiloMobile.xcarchive",
                    "-derivedDataPath", "/data/workspaces/legilo/DerivedData",
                    "-resultBundlePath", "/data/jobs/\(Self.jobID.uuidString)/result.xcresult",
                ] + Self.tail + Self.keyArguments)
        #expect(command.environment["DEVELOPER_DIR"] == "/Applications/Xcode-27.2.app/Contents/Developer")
        #expect(command.environment["PATH"] == "/usr/bin:/bin")
    }

    @Test func commandWithoutKeyArgumentsWhenNoTeamKey() {
        let action = WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect)
        let workflow = Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action])
        let command = command(workflow, action, key: nil)
        #expect(Array(command.arguments.suffix(Self.tail.count)) == Self.tail)
        #expect(!command.arguments.contains { $0.hasPrefix("-authenticationKey") })
    }

    @Test func resolveCommandUsesSystemGitWithTheTokenOnly() {
        let action = WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect)
        let workflow = Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action])
        let command = ArchiveStep.resolveCommand(
            workflow: workflow, action: action, repository: Self.layout.repository, layout: Self.layout,
            developerDir: "/Applications/Xcode-27.2.app/Contents/Developer", environment: ["PATH": "/usr/bin:/bin"],
            gitHubToken: "ghp_token")
        #expect(command.executable == "/usr/bin/xcodebuild")
        #expect(
            command.arguments == [
                "-resolvePackageDependencies", "-project", "/data/workspaces/legilo/repository/Legilo.xcodeproj",
                "-scheme", "LegiloMobile", "-derivedDataPath", "/data/workspaces/legilo/DerivedData",
                "-scmProvider", "system",
            ])
        #expect(
            command.environment
                == Checkout.credentialEnvironment(token: "ghp_token").merging([
                    "PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/Applications/Xcode-27.2.app/Contents/Developer",
                ]) { _, new in new })
        #expect(command.environment["HANGAR_GITHUB_TOKEN"] == "ghp_token")

        // Without a token (public packages only) there is no credential helper.
        let anonymous = ArchiveStep.resolveCommand(
            workflow: workflow, action: action, repository: Self.layout.repository, layout: Self.layout,
            developerDir: "/dev", environment: ["PATH": "/usr/bin:/bin"], gitHubToken: nil)
        #expect(anonymous.environment == ["PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/dev"])
    }

    @Test func failedResolutionStopsBeforeTheArchive() async throws {
        let root = NSTemporaryDirectory() + "hangar-archive-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let layout = WorkspaceLayout(dataDirectory: root, appSlug: "legilo", jobID: Self.jobID)
        let action = WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect)
        let workflow = Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action])
        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments.first == "-resolvePackageDependencies" }, lines: ["error: auth"], exitCode: 74)
        let lines = LineSink()
        await #expect(throws: ArchiveError.packageResolutionFailed(exitCode: 74)) {
            try await ArchiveStep(runner: runner).run(
                workflow: workflow, action: action, repository: layout.repository, layout: layout,
                developerDir: "/dev", key: Self.key, environment: [:], gitHubToken: "ghp_token", log: lines.append)
        }
        #expect(lines.all == ["error: auth"])
        #expect(runner.commands.count == 1)
    }

    @Test func workspaceInSubdirectory() {
        let action = WorkflowAction(scheme: "Legilo", platform: .macOS, export: .developerID)
        let workflow = Workflow(workspace: "apps/mac/Legilo.xcworkspace", xcode: "27.2", actions: [action])
        let command = command(workflow, action)
        #expect(command.arguments.prefix(5) == [
            "archive", "-workspace", "/data/workspaces/legilo/repository/apps/mac/Legilo.xcworkspace", "-scheme", "Legilo",
        ])
        #expect(!command.arguments.contains("-project"))
        #expect(command.arguments.contains("generic/platform=macOS"))
    }

    @Test func keyArgumentsNeedAllThreeVariables() {
        let full = [
            "HANGAR_ASC_KEY_PATH": "/k.p8", "HANGAR_ASC_KEY_ID": "K", "HANGAR_ASC_ISSUER_ID": "I",
        ]
        #expect(ASCKeyArguments(environment: full) != nil)
        for name in full.keys {
            var missing = full
            missing[name] = nil
            #expect(ASCKeyArguments(environment: missing) == nil)
            var empty = full
            empty[name] = ""
            #expect(ASCKeyArguments(environment: empty) == nil)
        }
    }

    @Test func runRemovesStaleOutputsAndForwardsLines() async throws {
        let root = NSTemporaryDirectory() + "hangar-archive-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let layout = WorkspaceLayout(dataDirectory: root, appSlug: "legilo", jobID: Self.jobID)
        let action = WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect)
        let workflow = Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action])
        try FileManager.default.createDirectory(
            atPath: layout.resultBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: layout.archive(scheme: "LegiloMobile"), withIntermediateDirectories: true)

        let runner = RecordingProcessRunner()
        runner.script({ _ in true }, lines: ["** ARCHIVE SUCCEEDED **"])
        let lines = LineSink()
        try await ArchiveStep(runner: runner).run(
            workflow: workflow, action: action, repository: layout.repository, layout: layout,
            developerDir: "/dev", key: Self.key, environment: [:], gitHubToken: nil, log: lines.append)

        #expect(!FileManager.default.fileExists(atPath: layout.resultBundle))
        #expect(!FileManager.default.fileExists(atPath: layout.archive(scheme: "LegiloMobile")))
        var isDirectory: ObjCBool = false
        let archiveParent = (layout.archive(scheme: "LegiloMobile") as NSString).deletingLastPathComponent
        #expect(FileManager.default.fileExists(atPath: archiveParent, isDirectory: &isDirectory) && isDirectory.boolValue)
        // The script answers both runs: package resolution, then the archive.
        #expect(lines.all == ["** ARCHIVE SUCCEEDED **", "** ARCHIVE SUCCEEDED **"])
        #expect(runner.commands.map { $0.arguments.first } == ["-resolvePackageDependencies", "archive"])
    }

    @Test func nonZeroExitThrows() async throws {
        let root = NSTemporaryDirectory() + "hangar-archive-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let layout = WorkspaceLayout(dataDirectory: root, appSlug: "legilo", jobID: Self.jobID)
        let action = WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect)
        let workflow = Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action])
        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments.first == "archive" }, lines: ["error: boom"], exitCode: 65)
        await #expect(throws: ArchiveError.xcodebuildFailed(exitCode: 65)) {
            try await ArchiveStep(runner: runner).run(
                workflow: workflow, action: action, repository: layout.repository, layout: layout,
                developerDir: "/dev", key: Self.key, environment: [:], gitHubToken: nil, log: { _ in })
        }
    }

    @Test func unsafeSchemeThrowsBeforeAnyRemoval() async throws {
        let root = NSTemporaryDirectory() + "hangar-archive-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let layout = WorkspaceLayout(dataDirectory: root, appSlug: "legilo", jobID: Self.jobID)
        // With scheme `../../x` the archive path would resolve to `<root>/x.xcarchive`, outside the job directory.
        try FileManager.default.createDirectory(atPath: root + "/x.xcarchive", withIntermediateDirectories: true)
        for scheme in ["../../x", "a/b", "..", "a..b", ""] {
            let action = WorkflowAction(scheme: scheme, platform: .iOS, export: .appStoreConnect)
            let workflow = Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action])
            let runner = RecordingProcessRunner()
            await #expect(throws: ArchiveError.invalidScheme(scheme)) {
                try await ArchiveStep(runner: runner).run(
                    workflow: workflow, action: action, repository: layout.repository, layout: layout,
                    developerDir: "/dev", key: Self.key, environment: [:], gitHubToken: nil, log: { _ in })
            }
            #expect(runner.commands.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: root + "/x.xcarchive"))
        #expect(!FileManager.default.fileExists(atPath: layout.jobDirectory))
    }
}
