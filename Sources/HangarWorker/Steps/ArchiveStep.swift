import Foundation
import HangarCore

/// The App Store Connect API key as `xcodebuild` authentication arguments, built from the job's reserved variables.
public struct ASCKeyArguments: Sendable {
    public let keyPath: String
    public let keyID: String
    public let issuerID: String

    public init(keyPath: String, keyID: String, issuerID: String) {
        self.keyPath = keyPath
        self.keyID = keyID
        self.issuerID = issuerID
    }

    /// Nil unless `HANGAR_ASC_KEY_PATH`, `HANGAR_ASC_KEY_ID` and `HANGAR_ASC_ISSUER_ID` are all set and non-empty.
    public init?(environment: [String: String]) {
        guard let keyPath = environment["HANGAR_ASC_KEY_PATH"], !keyPath.isEmpty,
            let keyID = environment["HANGAR_ASC_KEY_ID"], !keyID.isEmpty,
            let issuerID = environment["HANGAR_ASC_ISSUER_ID"], !issuerID.isEmpty
        else { return nil }
        self.init(keyPath: keyPath, keyID: keyID, issuerID: issuerID)
    }

    public var xcodebuildArguments: [String] {
        ["-authenticationKeyPath", keyPath, "-authenticationKeyID", keyID, "-authenticationKeyIssuerID", issuerID]
    }
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case xcodebuildFailed(exitCode: Int32)
    case invalidScheme(String)

    public var description: String {
        switch self {
        case .invalidScheme(let scheme): "invalid scheme name '\(scheme)'"
        case .xcodebuildFailed(let exitCode): "xcodebuild archive exited with status \(exitCode)"
        }
    }
}

/// Runs `xcodebuild archive` for one archive action with cloud-managed signing.
public struct ArchiveStep: Sendable {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    public static func command(
        workflow: Workflow, action: ArchiveAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        key: ASCKeyArguments, environment: [String: String]
    ) -> ProcessCommand {
        let container =
            workflow.project.map { ["-project", "\(repository)/\($0)"] }
            ?? workflow.workspace.map { ["-workspace", "\(repository)/\($0)"] } ?? []
        let arguments =
            ["archive"] + container + [
                "-scheme", action.scheme,
                "-destination", action.platform.genericDestination,
                "-archivePath", layout.archive(scheme: action.scheme),
                "-derivedDataPath", layout.derivedData,
                "-resultBundlePath", layout.resultBundle,
                "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
                "-skipMacroValidation", "-skipPackagePluginValidation",
            ] + key.xcodebuildArguments
        var environment = environment
        environment["DEVELOPER_DIR"] = developerDir
        return ProcessCommand(executable: "/usr/bin/xcodebuild", arguments: arguments, environment: environment)
    }

    /// xcodebuild refuses to overwrite an existing result bundle and archive, so both are removed first.
    public func run(
        workflow: Workflow, action: ArchiveAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        key: ASCKeyArguments, environment: [String: String], log: @Sendable (String) -> Void
    ) async throws {
        // The scheme comes from the repository's `.hangar.yml` and ends up in a path that is deleted below.
        guard !action.scheme.isEmpty, !action.scheme.contains("/"), !action.scheme.contains("..") else {
            throw ArchiveError.invalidScheme(action.scheme)
        }
        let fileManager = FileManager.default
        let archivePath = layout.archive(scheme: action.scheme)
        for path in [archivePath, layout.resultBundle] {
            try SafeRemoval.removeItem(atPath: path, within: layout.jobDirectory)
            try fileManager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        let command = Self.command(
            workflow: workflow, action: action, repository: repository, layout: layout, developerDir: developerDir,
            key: key, environment: environment)
        let outcome = try await runner.run(command, onLine: log)
        guard outcome.exitCode == 0 else { throw ArchiveError.xcodebuildFailed(exitCode: outcome.exitCode) }
    }
}
