import Foundation
import HangarCore

/// How the export is signed. Phase 1 only supports Apple's cloud-managed signing; `.temporaryKeychain` is the slot
/// Phase 2 fills in without changing `ExportStep`'s signature.
public enum SigningMode: Sendable {
    case cloudManaged
    case temporaryKeychain(p12Path: String, password: String)
}

public enum ExportError: Error, Equatable, CustomStringConvertible {
    case xcodebuildFailed(exitCode: Int32)
    case unsupportedSigningMode

    public var description: String {
        switch self {
        case .xcodebuildFailed(let exitCode): "xcodebuild -exportArchive exited with status \(exitCode)"
        case .unsupportedSigningMode: "temporary-keychain signing is not supported yet"
        }
    }
}

public enum ExportOptions {
    /// `destination` is `export` (write the artifact to disk) or `upload` (xcodebuild uploads to App Store Connect).
    /// The build number is never touched here: Hangar stamps it itself.
    public static func plist(method: ExportMethod, destination: String, teamID: String?) -> Data {
        var options: [String: Any] = [
            "method": method.rawValue,
            "signingStyle": "automatic",
            "manageAppVersionAndBuildNumber": false,
            "uploadSymbols": true,
            "destination": destination,
        ]
        if let teamID { options["teamID"] = teamID }
        // Serialising a dictionary of plist-native values cannot fail.
        return try! PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0)
    }
}

public struct ExportResult: Sendable, Equatable {
    /// First `.ipa`, `.pkg` or `.app` under the export directory; nil for destination `upload` or an empty export.
    public var exportedArtifactPath: String?
}

/// Runs `xcodebuild -exportArchive`. `key` is nil without a team key; xcodebuild then signs with the Xcode account.
public struct ExportStep: Sendable {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    /// `jobDirectory` (`layout.jobDirectory`) is the only place `exportPath` may be cleared in.
    public func run(
        archivePath: String, method: ExportMethod, destination: String, exportPath: String, jobDirectory: String,
        teamID: String?,
        developerDir: String, key: ASCKeyArguments?, signing: SigningMode, environment: [String: String],
        log: @escaping @Sendable (String) -> Void
    ) async throws -> ExportResult {
        guard case .cloudManaged = signing else { throw ExportError.unsupportedSigningMode }

        // Start from an empty directory so an old artifact is never mistaken for this export's output.
        let fileManager = FileManager.default
        try SafeRemoval.removeItem(atPath: exportPath, within: jobDirectory)
        try fileManager.createDirectory(atPath: exportPath, withIntermediateDirectories: true)
        let plistPath = exportPath + "/ExportOptions.plist"
        try ExportOptions.plist(method: method, destination: destination, teamID: teamID)
            .write(to: URL(fileURLWithPath: plistPath))

        var environment = environment
        environment["DEVELOPER_DIR"] = developerDir
        let command = ProcessCommand(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-exportArchive", "-archivePath", archivePath, "-exportOptionsPlist", plistPath,
                "-exportPath", exportPath, "-allowProvisioningUpdates",
            ] + (key?.xcodebuildArguments ?? []),
            environment: environment)
        let outcome = try await runner.run(command, onLine: log)
        guard outcome.exitCode == 0 else { throw ExportError.xcodebuildFailed(exitCode: outcome.exitCode) }

        guard destination == "export" else { return ExportResult(exportedArtifactPath: nil) }
        let artifact = try fileManager.contentsOfDirectory(atPath: exportPath).sorted().first {
            ["ipa", "pkg", "app"].contains(($0 as NSString).pathExtension)
        }
        return ExportResult(exportedArtifactPath: artifact.map { exportPath + "/" + $0 })
    }
}
