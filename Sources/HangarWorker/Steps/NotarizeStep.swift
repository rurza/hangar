import Foundation
import HangarCore

public enum NotarizeError: Error, Equatable, CustomStringConvertible {
    /// The export left no `.app` to notarize.
    case noApp
    /// Notarizing needs an App Store Connect team key, and the server has none.
    case noKey
    case zipFailed(exitCode: Int32)
    /// notarytool gave no submission (upload or sign-in failed).
    case submitFailed(exitCode: Int32)
    /// Apple finished with a status other than Accepted ("Invalid", "Rejected").
    case notAccepted(id: String, status: String)
    /// `--wait` ran out while Apple was still working on it.
    case unfinished(id: String)
    case stapleFailed(exitCode: Int32)
    case validateFailed(exitCode: Int32)

    public var description: String {
        switch self {
        case .noApp: "the export left no .app to notarize"
        case .noKey:
            "notarizing needs the server's App Store Connect team key; add one in Settings, or set notarize: false on the action"
        case .zipFailed(let exitCode): "ditto exited with status \(exitCode) while zipping the app for notarization"
        case .submitFailed(let exitCode): "notarytool submit exited with status \(exitCode) without a submission"
        case .notAccepted(let id, let status): "Apple's notary service answered \(status) for submission \(id) (its log is above)"
        case .unfinished(let id): "submission \(id) was still being notarized when Hangar stopped waiting"
        case .stapleFailed(let exitCode): "stapler staple exited with status \(exitCode)"
        case .validateFailed(let exitCode): "stapler validate exited with status \(exitCode)"
        }
    }
}

/// What notarytool said about a submission.
public struct NotarySubmission: Sendable, Equatable {
    public var id: String
    public var status: String?

    /// The submission in `notarytool submit --output-format json`'s output: the last line that is a JSON object with
    /// an `id`. The plain-text form (`  id: …`, `  status: …`) is read too, in case a version prints it.
    public static func parse(_ output: String) -> NotarySubmission? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() where line.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let id = object["id"] as? String, !id.isEmpty
            else { continue }
            return NotarySubmission(id: id, status: object["status"] as? String)
        }
        func value(_ key: String) -> String? {
            lines.last { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces) }
        }
        guard let id = value("id"), !id.isEmpty else { return nil }
        return NotarySubmission(id: id, status: value("status"))
    }
}

/// The `notarize` step of a Developer ID archive: zips the exported `.app`, sends it to Apple's notary service with
/// the team key (`notarytool submit --wait`), staples the ticket to the `.app` and checks it with
/// `stapler validate`. The `.app` in the export directory is stapled in place, so the artifact zipped from it later
/// is the one to distribute. Anything but Accepted fails the step, with notarytool's log for the submission.
public struct NotarizeStep: Sendable {
    /// How long `notarytool submit --wait` waits for Apple; most submissions take minutes.
    static let waitTimeout = "1h"

    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    /// `scratchDirectory` holds the upload zip, removed afterwards.
    public func run(
        appPath: String?, scratchDirectory: String, key: ASCKeyArguments?, developerDir: String,
        environment: [String: String], log: @escaping @Sendable (String) -> Void
    ) async throws -> NotarySubmission {
        guard let appPath, (appPath as NSString).pathExtension == "app" else { throw NotarizeError.noApp }
        guard let key else { throw NotarizeError.noKey }
        var environment = environment
        environment["DEVELOPER_DIR"] = developerDir
        let credentials = ["--key", key.keyPath, "--key-id", key.keyID, "--issuer", key.issuerID]

        try FileManager.default.createDirectory(atPath: scratchDirectory, withIntermediateDirectories: true)
        let upload = scratchDirectory + "/notarize-" + (appPath as NSString).lastPathComponent + ".zip"
        defer { try? SafeRemoval.removeItem(atPath: upload, within: scratchDirectory) }
        log("zipping \((appPath as NSString).lastPathComponent) for the notary service")
        let zipped = try await runner.run(
            ProcessCommand(executable: "/usr/bin/ditto", arguments: Self.zipArguments(appPath, upload), environment: environment),
            onLine: log)
        guard zipped.exitCode == 0 else { throw NotarizeError.zipFailed(exitCode: zipped.exitCode) }

        log("submitting to Apple's notary service and waiting for its answer (at most \(Self.waitTimeout))")
        let submitted = try await runner.run(
            ProcessCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["notarytool", "submit", upload] + credentials
                    + ["--wait", "--timeout", Self.waitTimeout, "--output-format", "json"],
                environment: environment),
            onLine: log)
        guard let submission = NotarySubmission.parse(submitted.output) else {
            throw NotarizeError.submitFailed(exitCode: submitted.exitCode)
        }
        log("notarization submission \(submission.id): \(submission.status ?? "no status")")
        switch submission.status {
        case "Accepted": break
        case "In Progress", nil: throw NotarizeError.unfinished(id: submission.id)
        case let status?:
            log("the notary service's log for \(submission.id):")
            _ = try? await runner.run(
                ProcessCommand(
                    executable: "/usr/bin/xcrun", arguments: ["notarytool", "log", submission.id] + credentials,
                    environment: environment),
                onLine: log)
            throw NotarizeError.notAccepted(id: submission.id, status: status)
        }

        let stapled = try await runner.run(
            ProcessCommand(executable: "/usr/bin/xcrun", arguments: ["stapler", "staple", appPath], environment: environment),
            onLine: log)
        guard stapled.exitCode == 0 else { throw NotarizeError.stapleFailed(exitCode: stapled.exitCode) }
        let validated = try await runner.run(
            ProcessCommand(executable: "/usr/bin/xcrun", arguments: ["stapler", "validate", appPath], environment: environment),
            onLine: log)
        guard validated.exitCode == 0 else { throw NotarizeError.validateFailed(exitCode: validated.exitCode) }
        log("the ticket is stapled to \((appPath as NSString).lastPathComponent)")
        return submission
    }

    /// `ditto -c -k --keepParent` without resource forks or extended attributes: a stray `com.apple.FinderInfo`
    /// makes Sparkle's validation of the unzipped app fail. The stapled ticket is a file in the bundle, so it stays.
    static func zipArguments(_ source: String, _ destination: String) -> [String] {
        ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", source, destination]
    }
}
