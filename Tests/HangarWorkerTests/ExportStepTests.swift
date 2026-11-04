import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

/// Collects log lines from a `@Sendable` callback.
final class LineSink: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    @Sendable func append(_ line: String) { lines.withLock { $0.append(line) } }
}

/// Stands in for xcodebuild's export side effect: wraps a `RecordingProcessRunner` and, when it sees the
/// `-exportArchive` command, first records what was in the export directory and then drops `produce` into it.
private final class ExportingRunner: ProcessRunner {
    let recording = RecordingProcessRunner()
    let exportPath: String
    let produce: String?
    private let seen = Mutex<[String]>([])

    init(exportPath: String, produce: String?) {
        self.exportPath = exportPath
        self.produce = produce
    }

    /// Directory contents at the moment the export command started.
    var contentsAtExport: [String] { seen.withLock { $0 } }

    func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
        if command.arguments.contains("-exportArchive") {
            seen.withLock { $0 = ((try? FileManager.default.contentsOfDirectory(atPath: exportPath)) ?? []).sorted() }
            if let produce {
                FileManager.default.createFile(atPath: exportPath + "/" + produce, contents: Data())
            }
        }
        return try await recording.run(command, onLine: onLine)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ExportStepTests {
    private static let key = ASCKeyArguments(environment: [
        "HANGAR_ASC_KEY_PATH": "/k.p8", "HANGAR_ASC_KEY_ID": "K", "HANGAR_ASC_ISSUER_ID": "I",
    ])!

    private func plist(_ data: Data) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func tempDirectory() -> String {
        NSTemporaryDirectory() + "hangar-export-\(UUID().uuidString)"
    }

    private func run(
        _ runner: any ProcessRunner, exportPath: String, method: ExportMethod = .developerID,
        destination: String = "export", signing: SigningMode = .cloudManaged, jobDirectory: String? = nil,
        key: ASCKeyArguments? = ExportStepTests.key
    ) async throws -> ExportResult {
        try await ExportStep(runner: runner).run(
            archivePath: "/jobs/1/archive/Legilo.xcarchive", method: method, destination: destination,
            exportPath: exportPath,
            jobDirectory: jobDirectory ?? (exportPath as NSString).deletingLastPathComponent, teamID: "TEAM123456", developerDir: "/dev", key: key, signing: signing,
            environment: ["PATH": "/usr/bin"], log: { _ in })
    }

    @Test func plistForAppStoreUpload() throws {
        let dict = try plist(ExportOptions.plist(method: .appStoreConnect, destination: "upload", teamID: "TEAM123456"))
        #expect(dict["method"] as? String == "app-store-connect")
        #expect(dict["destination"] as? String == "upload")
        #expect(dict["signingStyle"] as? String == "automatic")
        #expect(dict["manageAppVersionAndBuildNumber"] as? Bool == false)
        #expect(dict["uploadSymbols"] as? Bool == true)
        #expect(dict["teamID"] as? String == "TEAM123456")
    }

    @Test func plistForDeveloperIDExport() throws {
        let data = ExportOptions.plist(method: .developerID, destination: "export", teamID: nil)
        let dict = try plist(data)
        #expect(dict["method"] as? String == "developer-id")
        #expect(dict["destination"] as? String == "export")
        #expect(dict["teamID"] == nil)
        #expect(dict["manageAppVersionAndBuildNumber"] as? Bool == false)
        #expect(String(decoding: data, as: UTF8.self).contains("<?xml"))
    }

    @Test func commandAndPlistAreWrittenAndFindsExportedPkgForMac() async throws {
        let exportPath = tempDirectory() + "/export"
        defer { try? FileManager.default.removeItem(atPath: (exportPath as NSString).deletingLastPathComponent) }
        let runner = ExportingRunner(exportPath: exportPath, produce: "Legilo.pkg")
        let result = try await run(runner, exportPath: exportPath)
        #expect(result.exportedArtifactPath == exportPath + "/Legilo.pkg")

        let command = try #require(runner.recording.commands.first)
        #expect(command.executable == "/usr/bin/xcodebuild")
        #expect(
            command.arguments
                == [
                    "-exportArchive", "-archivePath", "/jobs/1/archive/Legilo.xcarchive",
                    "-exportOptionsPlist", exportPath + "/ExportOptions.plist", "-exportPath", exportPath,
                    "-allowProvisioningUpdates",
                    "-authenticationKeyPath", "/k.p8", "-authenticationKeyID", "K", "-authenticationKeyIssuerID", "I",
                ])
        #expect(command.environment["DEVELOPER_DIR"] == "/dev")
        #expect(command.environment["PATH"] == "/usr/bin")
        let written = try plist(Data(contentsOf: URL(fileURLWithPath: exportPath + "/ExportOptions.plist")))
        #expect(written["method"] as? String == "developer-id")
        #expect(written["teamID"] as? String == "TEAM123456")
    }

    @Test func commandWithoutKeyArgumentsWhenNoTeamKey() async throws {
        let exportPath = tempDirectory() + "/export"
        defer { try? FileManager.default.removeItem(atPath: (exportPath as NSString).deletingLastPathComponent) }
        let runner = ExportingRunner(exportPath: exportPath, produce: "Legilo.pkg")
        _ = try await run(runner, exportPath: exportPath, key: nil)
        let command = try #require(runner.recording.commands.first)
        #expect(command.arguments == [
            "-exportArchive", "-archivePath", "/jobs/1/archive/Legilo.xcarchive",
            "-exportOptionsPlist", exportPath + "/ExportOptions.plist", "-exportPath", exportPath,
            "-allowProvisioningUpdates",
        ])
    }

    @Test func uploadDestinationHasNoArtifact() async throws {
        let exportPath = tempDirectory() + "/export"
        defer { try? FileManager.default.removeItem(atPath: (exportPath as NSString).deletingLastPathComponent) }
        let runner = ExportingRunner(exportPath: exportPath, produce: "Legilo.ipa")
        let result = try await run(runner, exportPath: exportPath, method: .appStoreConnect, destination: "upload")
        #expect(result.exportedArtifactPath == nil)
    }

    @Test func noArtifactWhenExportProducedNothing() async throws {
        let exportPath = tempDirectory() + "/export"
        defer { try? FileManager.default.removeItem(atPath: (exportPath as NSString).deletingLastPathComponent) }
        let result = try await run(ExportingRunner(exportPath: exportPath, produce: nil), exportPath: exportPath)
        #expect(result.exportedArtifactPath == nil)
    }

    @Test func staleArtifactIsRemovedBeforeExport() async throws {
        let exportPath = tempDirectory() + "/export"
        defer { try? FileManager.default.removeItem(atPath: (exportPath as NSString).deletingLastPathComponent) }
        try FileManager.default.createDirectory(atPath: exportPath, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exportPath + "/Aardvark.ipa", contents: Data())

        // The export produces nothing, so the stale Aardvark.ipa would be picked up if it survived.
        let runner = ExportingRunner(exportPath: exportPath, produce: nil)
        let result = try await run(runner, exportPath: exportPath)
        #expect(runner.contentsAtExport == ["ExportOptions.plist"])
        #expect(result.exportedArtifactPath == nil)
    }

    @Test func nonZeroExitThrows() async throws {
        let exportPath = tempDirectory() + "/export"
        defer { try? FileManager.default.removeItem(atPath: (exportPath as NSString).deletingLastPathComponent) }
        let runner = RecordingProcessRunner()
        runner.script({ _ in true }, lines: ["error: no signing"], exitCode: 70)
        await #expect(throws: ExportError.xcodebuildFailed(exitCode: 70)) {
            _ = try await run(runner, exportPath: exportPath)
        }
    }

    @Test func temporaryKeychainUnsupportedInPhase1() async throws {
        let exportPath = tempDirectory() + "/export"
        let runner = RecordingProcessRunner()
        await #expect(throws: ExportError.unsupportedSigningMode) {
            _ = try await run(runner, exportPath: exportPath, signing: .temporaryKeychain(p12Path: "/c.p12", password: "x"))
        }
        #expect(runner.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: exportPath))
    }

    @Test func refusesToClearPathsOutsideTheJobDirectory() async throws {
        let root = tempDirectory()
        let job = root + "/jobs/1"
        let sentinel = root + "/sentinel.txt"
        try FileManager.default.createDirectory(atPath: job, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sentinel, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: root) }

        for bad in ["/", "", job, root, root + "/other", job + "/../..", job + "/../sentinel.txt", "relative/export"] {
            let runner = RecordingProcessRunner()
            await #expect(throws: SafeRemovalError.self) {
                _ = try await run(runner, exportPath: bad, jobDirectory: job)
            }
            #expect(runner.commands.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel))
        #expect(FileManager.default.fileExists(atPath: job))
    }
}
