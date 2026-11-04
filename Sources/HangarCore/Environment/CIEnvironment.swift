import Foundation

/// Builds the Xcode Cloud-compatible environment every job runs with.
public struct CIEnvironment: Sendable {
    public struct Paths: Sendable, Equatable {
        public var repository: String
        public var projectFile: String
        public var derivedData: String
        public var archive: String
        public var resultBundle: String
        /// The job directory (`CI_WORKSPACE`).
        public var workspace: String

        public init(
            repository: String, projectFile: String, derivedData: String, archive: String,
            resultBundle: String, workspace: String
        ) {
            self.repository = repository
            self.projectFile = projectFile
            self.derivedData = derivedData
            self.archive = archive
            self.resultBundle = resultBundle
            self.workspace = workspace
        }
    }

    public struct MergedEnvironment: Sendable {
        public var env: [String: String]
        public var filesToWrite: [(path: String, contents: String)]
        /// Never contain variable values.
        public var warnings: [String]
    }

    /// Variables copied from the worker's own environment when set. LaunchAgents start with a bare one, and tools
    /// like xcodegen, brew, swift and git fail without a user name, a temp directory or a UTF-8 locale.
    static let passthroughNames = ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "LC_ALL", "LC_CTYPE"]

    /// Names Hangar sets for every job, which variables cannot replace, besides every `CI_` name. The web UI's
    /// variables editor (`variables.js`) refuses the same names.
    public static let reservedNames: Set<String> = ["PATH", "HOME", "DEVELOPER_DIR", "USER", "LOGNAME", "TMPDIR", "SHELL"]
    static let reservedSummary = "CI_*, PATH, HOME, DEVELOPER_DIR, USER, LOGNAME, TMPDIR and SHELL"

    /// Locale variables an app variable may override; everything else in the job environment is fixed.
    static let overridableNames: Set<String> = ["LANG", "LC_ALL", "LC_CTYPE"]

    /// The identity and locale subset of a process environment: `passthroughNames` when set and non-empty,
    /// `USER`/`LOGNAME` derived from `NSUserName()` when missing, and `LANG=en_US.UTF-8` when missing.
    public static func identityEnvironment(from processEnvironment: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for name in passthroughNames {
            if let value = processEnvironment[name], !value.isEmpty { env[name] = value }
        }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["LOGNAME"] == nil { env["LOGNAME"] = env["USER"] }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// `processEnvironment` defaults to the worker's own; tests inject a fixed one.
    public static func make(
        app: App, workflow name: String, action: ArchiveAction, buildNumber: Int, jobID: UUID, buildID: UUID,
        commit: String, ref: String, teamID: String?, paths: Paths, developerDir: String, basePATH: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [
            "CI": "TRUE",
            "CI_HANGAR": "TRUE",
            "CI_START_CONDITION": "manual",
            "CI_XCODEBUILD_ACTION": "archive",
            "CI_PRIMARY_REPOSITORY_PATH": paths.repository,
            "CI_WORKSPACE": paths.workspace,
            "CI_PROJECT_FILE_PATH": paths.projectFile,
            "CI_DERIVED_DATA_PATH": paths.derivedData,
            "CI_ARCHIVE_PATH": paths.archive,
            "CI_RESULT_BUNDLE_PATH": paths.resultBundle,
            "CI_BUILD_NUMBER": String(buildNumber),
            "CI_BUILD_ID": jobID.uuidString,
            "CI_WORKFLOW": name,
            "CI_WORKFLOW_ID": name,
            "CI_PRODUCT": app.name,
            "CI_PRODUCT_ID": app.slug,
            "CI_PRODUCT_PLATFORM": action.platform.ciName,
            "CI_XCODE_SCHEME": action.scheme,
            "CI_COMMIT": commit,
            "DEVELOPER_DIR": developerDir,
            "PATH": dedupedPATH(basePATH + ":/opt/homebrew/bin:/usr/local/bin"),
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if !isFullSHA(ref) { env["CI_BRANCH"] = ref }
        if let teamID { env["CI_TEAM_ID"] = teamID }
        env.merge(identityEnvironment(from: processEnvironment)) { ci, _ in ci }
        return env
    }

    public static func postXcodebuildAdditions(
        exitCode: Int32, action: ArchiveAction, exportedAppPath: String?
    ) -> [String: String] {
        var additions = ["CI_XCODEBUILD_EXIT_CODE": String(exitCode)]
        if let exportedAppPath {
            switch action.export {
            case .appStoreConnect: additions["CI_APP_STORE_SIGNED_APP_PATH"] = exportedAppPath
            case .developerID: additions["CI_DEVELOPER_ID_SIGNED_APP_PATH"] = exportedAppPath
            }
        }
        return additions
    }

    /// User entries never override the CI set (only `LANG`, `LC_ALL` and `LC_CTYPE` may be overridden): a name in `ci`,
    /// in `reservedNames` or starting with `CI_` is dropped with a warning that says why.
    /// As-file entries become `<secretsDirectory>/<NAME>`, which is the env value; the stored value is the file body.
    public static func merge(ci: [String: String], entries: [EnvEntry], secretsDirectory: String) -> MergedEnvironment {
        var merged = MergedEnvironment(env: ci, filesToWrite: [], warnings: [])
        for entry in entries {
            if entry.name.hasPrefix("CI_") {
                merged.warnings.append(
                    "Ignoring variable \(entry.name): names starting with CI_ are reserved by Hangar (reserved: \(reservedSummary))")
                continue
            }
            if reservedNames.contains(entry.name) || (ci[entry.name] != nil && !overridableNames.contains(entry.name)) {
                merged.warnings.append(
                    "Ignoring variable \(entry.name): Hangar sets \(entry.name) for every job (reserved: \(reservedSummary))")
                continue
            }
            if entry.asFile {
                let path = "\(secretsDirectory)/\(entry.name)"
                merged.env[entry.name] = path
                merged.filesToWrite.removeAll { $0.path == path }
                merged.filesToWrite.append((path: path, contents: entry.value))
            } else {
                merged.env[entry.name] = entry.value
            }
        }
        return merged
    }

    private static func isFullSHA(_ ref: String) -> Bool {
        ref.utf8.count == 40 && ref.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }
    }

    /// Drops empty components and later duplicates; first occurrence order wins.
    private static func dedupedPATH(_ path: String) -> String {
        var seen = Set<Substring>()
        return path.split(separator: ":").filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}
