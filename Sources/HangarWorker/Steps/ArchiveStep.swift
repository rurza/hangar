import Foundation
import HangarCore

/// A team App Store Connect API key as `xcodebuild` authentication arguments: the `.p8` that
/// `AppStoreConnectKeyFile` wrote, its ID and its issuer. xcodebuild only accepts team keys; with an individual key
/// there are no such arguments and `-allowProvisioningUpdates` uses the developer account signed in to Xcode on the Mac.
public struct ASCKeyArguments: Sendable {
    public let keyPath: String
    public let keyID: String
    public let issuerID: String

    public init(keyPath: String, keyID: String, issuerID: String) {
        self.keyPath = keyPath
        self.keyID = keyID
        self.issuerID = issuerID
    }

    public var xcodebuildArguments: [String] {
        ["-authenticationKeyPath", keyPath, "-authenticationKeyID", keyID, "-authenticationKeyIssuerID", issuerID]
    }
}

/// The assignment's App Store Connect key as a file, only for as long as one step needs it: written 0600 into a 0700
/// directory of the job just before the step, removed right after it, whether it worked or not. Hooks therefore
/// never find it; the step's own build phases and package plugins, which run as this user, still can.
public struct AppStoreConnectKeyFile: Sendable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    /// The file's path for `keyID`; only letters and digits of the ID make it into the name.
    public func path(keyID: String) -> String {
        let safe = String(keyID.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
        return directory + "/AuthKey_\(safe.isEmpty ? "key" : safe).p8"
    }

    /// Runs `body` with the arguments for `key` (nil when there is no team key: nothing is written).
    public func with<Value: Sendable>(
        _ key: AppStoreConnectKey?, _ body: (ASCKeyArguments?) async throws -> Value
    ) async throws -> Value {
        guard let key, key.isTeamKey, let issuerID = key.issuerID else { return try await body(nil) }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = path(keyID: key.keyID)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try SecretFile.write(Data(key.privateKey.utf8), to: path)
        return try await body(ASCKeyArguments(keyPath: path, keyID: key.keyID, issuerID: issuerID))
    }
}

/// How an archive gets its development signing.
public enum ArchiveSigning: Sendable, Equatable {
    /// Automatic signing with `-allowProvisioningUpdates`: Xcode fetches or makes the profiles, with the key's
    /// arguments when there is one (a host Mac, or a VM guest with the development key).
    case automatic
    /// Manual signing with installed profiles, chosen per target by an `-xcconfig` (a VM guest with the profiles
    /// Hangar provides): no Apple account and no key, so no `-allowProvisioningUpdates`.
    case profiles(xcconfig: String)
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case xcodebuildFailed(exitCode: Int32)
    case packageResolutionFailed(exitCode: Int32)
    case invalidScheme(String)

    public var description: String {
        switch self {
        case .invalidScheme(let scheme): "invalid scheme name '\(scheme)'"
        case .xcodebuildFailed(let exitCode): "xcodebuild archive exited with status \(exitCode)"
        case .packageResolutionFailed(let exitCode):
            "xcodebuild -resolvePackageDependencies exited with status \(exitCode)"
        }
    }
}

/// Runs `xcodebuild archive` for one archive action with cloud-managed signing.
///
/// Swift packages are resolved first, in a separate `xcodebuild -resolvePackageDependencies` run that uses the system
/// git with the GitHub token's credential helper, so private packages on GitHub resolve. Only that run sees the
/// token; the archive itself runs with automatic package resolution disabled and no secret in its environment.
public struct ArchiveStep: Sendable {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    private static func container(_ workflow: Workflow, repository: String) -> [String] {
        workflow.project.map { ["-project", "\(repository)/\($0)"] }
            ?? workflow.workspace.map { ["-workspace", "\(repository)/\($0)"] } ?? []
    }

    /// `environment` is the xcodebuild environment (no secrets); the token's credential settings are added to it.
    public static func resolveCommand(
        workflow: Workflow, action: WorkflowAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        environment: [String: String], gitHubToken: String?
    ) -> ProcessCommand {
        let arguments =
            ["-resolvePackageDependencies"] + container(workflow, repository: repository) + [
                "-scheme", action.scheme,
                "-derivedDataPath", layout.derivedData,
                "-scmProvider", "system",
            ]
        var environment = environment.merging(gitHubToken.map(Checkout.credentialEnvironment) ?? [:]) { _, new in new }
        environment["DEVELOPER_DIR"] = developerDir
        return ProcessCommand(executable: "/usr/bin/xcodebuild", arguments: arguments, environment: environment)
    }

    public static func command(
        workflow: Workflow, action: WorkflowAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        key: ASCKeyArguments?, environment: [String: String], signing: ArchiveSigning = .automatic
    ) -> ProcessCommand {
        let signingArguments: [String] = switch signing {
        case .automatic: ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"]
        case .profiles(let xcconfig): ["-xcconfig", xcconfig]
        }
        let arguments =
            ["archive"] + container(workflow, repository: repository) + [
                "-scheme", action.scheme,
                "-destination", action.platform.genericDestination,
                "-archivePath", layout.archive(scheme: action.scheme),
                "-derivedDataPath", layout.derivedData,
                "-resultBundlePath", layout.resultBundle,
            ] + signingArguments + [
                "-skipMacroValidation", "-skipPackagePluginValidation",
                "-disableAutomaticPackageResolution",
            ] + (signing == .automatic ? key?.xcodebuildArguments ?? [] : [])
        var environment = environment
        environment["DEVELOPER_DIR"] = developerDir
        return ProcessCommand(executable: "/usr/bin/xcodebuild", arguments: arguments, environment: environment)
    }

    /// xcodebuild refuses to overwrite an existing result bundle and archive, so both are removed first.
    public func run(
        workflow: Workflow, action: WorkflowAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        key: ASCKeyArguments?, environment: [String: String], gitHubToken: String?,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        try await resolve(
            workflow: workflow, action: action, repository: repository, layout: layout, developerDir: developerDir,
            environment: environment, gitHubToken: gitHubToken, log: log)
        try await archive(
            workflow: workflow, action: action, repository: repository, layout: layout, developerDir: developerDir,
            key: key, environment: environment, log: log)
    }

    /// The first half: removes the old archive and result bundle and resolves the packages. Package manifests are the
    /// repository's code, so this half never has the App Store Connect key's file around.
    public func resolve(
        workflow: Workflow, action: WorkflowAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        environment: [String: String], gitHubToken: String?, log: @escaping @Sendable (String) -> Void
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
        let resolve = Self.resolveCommand(
            workflow: workflow, action: action, repository: repository, layout: layout, developerDir: developerDir,
            environment: environment, gitHubToken: gitHubToken)
        let resolved = try await runner.run(resolve, onLine: log)
        guard resolved.exitCode == 0 else { throw ArchiveError.packageResolutionFailed(exitCode: resolved.exitCode) }
    }

    /// The second half: `xcodebuild archive` itself.
    public func archive(
        workflow: Workflow, action: WorkflowAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        key: ASCKeyArguments?, environment: [String: String], signing: ArchiveSigning = .automatic,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let command = Self.command(
            workflow: workflow, action: action, repository: repository, layout: layout, developerDir: developerDir,
            key: key, environment: environment, signing: signing)
        let outcome = try await runner.run(command, onLine: log)
        guard outcome.exitCode == 0 else { throw ArchiveError.xcodebuildFailed(exitCode: outcome.exitCode) }
    }
}
