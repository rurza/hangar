import Foundation
import HangarCore

// A VM archive is split between the guest and its host (VM builds design, *First slice as built*, decision 19;
// security review 2026-11-06, C1). No App Store Connect key of the server's ever enters the guest:
//
// - The guest runs `checkout` through `stamp` and then `post-xcodebuild`, signing the archive for development with the
//   profiles the server provides (or, only when one is missing, the optional development key). It reports those steps
//   itself and hands the archive off instead of exporting it (`ArchiveHandOff`).
// - The host copies the archive, the result bundle, the TestFlight notes and the full log out of the VM, deletes the
//   VM, and runs `export`, the post-actions, `upload-artifacts` and `cleanup` with the server's key
//   (`runHostExport`), then reports the result. Before a Developer ID export it takes Hangar's development profile
//   out of the archive when no entitlement needs one (`DevelopmentProfileRemoval`, decision 25). A macOS archive's
//   resource bundles lose the development signature the export would leave on them (`ResourceBundleSignatureRemoval`).
//
// The step names and their order on the build page stay the same; only `post-xcodebuild` now runs before `export`,
// so `CI_APP_STORE_SIGNED_APP_PATH` and `CI_DEVELOPER_ID_SIGNED_APP_PATH` are not set for it in a VM.

extension JobRunner {
    /// How much of the pipeline a `JobRunner` runs.
    public enum Mode: Sendable {
        /// All of it, on this Mac.
        case standard
        /// A VM guest: an archive stops after `post-xcodebuild` and hands off to the host; `GuestSigning` says how it
        /// signs. Test jobs run whole.
        case guest(GuestSigning)
    }

    /// What a guest's archive signs with: the server's development profiles (installed by `GuestJobRunner`), or the
    /// development key when the server could not provide one of them.
    public struct GuestSigning: Codable, Sendable, Equatable {
        public var profiles: [JobProvisioningProfile]
        public var developmentKey: AppStoreConnectKey?
        public var missing: [MissingProfile]
        /// What the server did ("created development profile …"), for the archive's log.
        public var notes: [String]
        /// The certificate's team, for the targets that sign without a profile.
        public var teamID: String?

        public init(
            profiles: [JobProvisioningProfile] = [], developmentKey: AppStoreConnectKey? = nil, missing: [MissingProfile] = [],
            notes: [String] = [], teamID: String? = nil
        ) {
            self.profiles = profiles
            self.developmentKey = developmentKey
            self.missing = missing
            self.notes = notes
            self.teamID = teamID
        }

        /// Manual development signing for every target whose bundle ID has a profile, chosen per target by bundle
        /// ID: `$(PRODUCT_BUNDLE_IDENTIFIER:identifier)` names a setting only those targets have, so frameworks and
        /// package targets get no profile, which they would refuse. A target without one signs with the identity
        /// alone (enough for a macOS app that needs no profile; an iOS app then fails with Xcode's own message).
        public var xcconfig: String {
            var lines = [
                "// Written by Hangar for a VM archive: development signing with the profiles Hangar provides.",
                "CODE_SIGN_STYLE = Manual",
                "CODE_SIGN_IDENTITY = Apple Development",
                "PROVISIONING_PROFILE_SPECIFIER = $(HANGAR_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:identifier))",
            ]
            // Every target signs with the certificate; those without a profile (package resource bundles, macros) need
            // its team, which a package target does not set itself.
            if let teamID, teamID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), !teamID.isEmpty {
                lines.append("DEVELOPMENT_TEAM = \(teamID)")
            }
            for profile in profiles.sorted(by: { $0.bundleID < $1.bundleID }) {
                // A name that could expand into another setting is never written.
                guard !profile.name.contains("$"), !profile.name.contains(where: \.isNewline) else { continue }
                lines.append("HANGAR_PROFILE_\(Self.identifier(profile.bundleID)) = \(profile.name)")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        /// Xcode's `:identifier`: every character that is not a letter, a digit or `_` becomes `_`, and a leading
        /// digit gets a `_` before it.
        static func identifier(_ text: String) -> String {
            var result = String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
            if result.first?.isNumber == true { result = "_" + result }
            return result
        }
    }

    /// The archive step's signing, logged: automatic on a host Mac or with the development key, the server's profiles
    /// otherwise. Writes the `-xcconfig` for the latter.
    func guestArchiveSigning(layout: WorkspaceLayout, log: @escaping @Sendable (String) -> Void) throws -> ArchiveSigning {
        guard case .guest(let signing) = mode else { return .automatic }
        signing.notes.forEach(log)
        for missing in signing.missing { log("no development profile for \(missing.bundleID): \(missing.reason)") }
        if let key = signing.developmentKey {
            log("signing for development with Hangar's development key \(key.keyID), since a profile is missing; Hangar's own App Store Connect key is not in this VM")
            return .automatic
        }
        let names = signing.profiles.map(\.bundleID).sorted()
        log(names.isEmpty
            ? "signing for development with Hangar's certificate and no profile; no App Store Connect key is in this VM"
            : "signing for development with Hangar's profiles for \(names.joined(separator: ", ")); no App Store Connect key is in this VM")
        let path = layout.jobDirectory + "/hangar-signing.xcconfig"
        try FileManager.default.createDirectory(atPath: layout.jobDirectory, withIntermediateDirectories: true)
        try Data(signing.xcconfig.utf8).write(to: URL(fileURLWithPath: path))
        return .profiles(xcconfig: path)
    }

    /// A guest archive's `post-xcodebuild`, which runs before the host's export: without the exported product's path.
    /// Returns the hand-off when the job is still going; otherwise skips the export and the post-actions, and the job
    /// ends in the guest as any other.
    func guestPostXcodebuild(
        _ assignment: JobAssignment, layout: WorkspaceLayout, log: JobLog, pipeline: inout JobPipeline, hooks: HookRunner,
        scripts: String, environment: [String: String]
    ) async -> ArchiveHandOff? {
        let action = assignment.job.action
        let additions = CIEnvironment.postXcodebuildAdditions(
            exitCode: pipeline.xcodebuildExitCode ?? 0, action: action, exportedAppPath: nil)
        await pipeline.step(StepName.postXcodebuild, .postXcodebuild, skippedIf: { $0 == .absent }) {
            try await hooks.run(
                .postXcodebuild, scriptsDirectory: scripts, environment: environment.merging(additions) { _, new in new },
                log: log.lines(StepName.postXcodebuild))
        }
        guard pipeline.status == .succeeded else {
            await pipeline.skip(StepName.export)
            if action.notarizes { await pipeline.skip(StepName.notarize) }
            for spec in assignment.workflow.postActions { await pipeline.skip(StepName.postAction(spec.name)) }
            return nil
        }
        log.line(step: StepName.postXcodebuild, "the archive goes to this VM's host, which exports and uploads it")
        return ArchiveHandOff(
            archivePath: layout.archive(scheme: action.scheme), resultBundlePath: layout.resultBundle,
            testFlightDirectory: layout.repository
                + (assignment.workflow.projectDirectory == "." ? "" : "/" + assignment.workflow.projectDirectory) + "/TestFlight",
            fullLogPath: layout.fullLog)
    }

    /// Where this runner keeps `assignment`'s files.
    public func layout(for assignment: JobAssignment) -> WorkspaceLayout {
        WorkspaceLayout(
            dataDirectory: dataDirectory, appSlug: assignment.app.slug, jobID: assignment.job.id, temporaryRoot: temporaryRoot)
    }

    /// The host's half of a VM archive, after the guest handed it off and its files were copied into `layout(for:)`
    /// (the archive, the result bundle, the TestFlight notes under the repository, the guest's full log): `export`, the
    /// post-actions, `upload-artifacts`, `cleanup`, and the job's result. The server's key is written for the export
    /// and each post-action only (`AppStoreConnectKeyFile`). No job variable reaches these steps' environment: the
    /// archive is the only thing of the build's that runs through this Mac's `xcodebuild`.
    public func runHostExport(
        _ assignment: JobAssignment, guestLogAbridged: Bool, cancelled: @escaping @Sendable () -> Bool,
        stopReason: @escaping @Sendable () -> String? = { nil }
    ) async -> JobResult {
        let jobID = assignment.job.id
        let layout = layout(for: assignment)
        let masker = SecretMasker(
            secrets: assignment.environment.filter { $0.isSecret || $0.asFile }.map(\.value)
                + [assignment.appStoreConnectKey?.privateKey].compactMap { $0 })
        let log = JobLog(
            jobID: jobID, masker: masker, connection: connection, clock: clock, fullLogPath: layout.fullLog, continuing: true,
            alreadyAbridged: guestLogAbridged)
        var pipeline = JobPipeline(
            jobID: jobID, connection: connection, log: log, clock: clock, cancelled: cancelled, stopReason: stopReason)

        var outputs: [String: String] = [:]
        do {
            let prepared = try await prepareHostExport(assignment, layout: layout, log: log.lines(StepName.export))
            if assignment.job.action.platform == .macOS {
                try ResourceBundleSignatureRemoval.run(
                    archivePath: layout.archive(scheme: assignment.job.action.scheme), log: log.lines(StepName.export))
            }
            if assignment.job.action.export == .developerID {
                _ = try await DevelopmentProfileRemoval(runner: runner).run(
                    archivePath: layout.archive(scheme: assignment.job.action.scheme), scratchDirectory: layout.temporary,
                    environment: prepared.environment, log: log.lines(StepName.export))
            }
            let exported = await export(assignment, prepared: prepared, layout: layout, log: log, pipeline: &pipeline)
            outputs = await notarize(
                assignment, prepared: prepared, layout: layout, exported: exported, log: log, pipeline: &pipeline)
            outputs.merge(await postActions(
                assignment, prepared: prepared, layout: layout, exported: exported, log: log, masker: masker, pipeline: &pipeline)
            ) { _, new in new }
        } catch {
            await pipeline.step(StepName.export) { () async throws -> Void in throw error }
            if assignment.job.action.notarizes { await pipeline.skip(StepName.notarize) }
            for spec in assignment.workflow.postActions { await pipeline.skip(StepName.postAction(spec.name)) }
        }

        if pipeline.stopNote != nil {
            await pipeline.skip(StepName.uploadArtifacts)
        } else {
            await uploadArtifacts(assignment, layout: layout, log: log, pipeline: &pipeline)
        }
        await pipeline.report(StepName.cleanup, .running)
        var cleanedUp = true
        for (what, path, root) in [
            ("remove the temporary directory", layout.temporary, layout.temporaryRoot),
            ("remove the job directory", layout.jobDirectory, dataDirectory + "/jobs"),
        ] where FileManager.default.fileExists(atPath: path) {
            do { try SafeRemoval.removeItem(atPath: path, within: root) } catch {
                log.line(step: StepName.cleanup, "error: could not \(what): \(error)")
                cleanedUp = false
            }
        }
        await pipeline.report(StepName.cleanup, cleanedUp ? .succeeded : .failed)
        await log.finalFlush()

        let result = JobResult(
            status: pipeline.status, failureReason: pipeline.reason.map(masker.mask), outputs: outputs.mapValues(masker.mask))
        await reportFinish(jobID: jobID, result)
        return result
    }

    /// This Mac's Xcode for the workflow and an environment of its own: none of the job's variables.
    private func prepareHostExport(
        _ assignment: JobAssignment, layout: WorkspaceLayout, log: @escaping @Sendable (String) -> Void
    ) async throws -> Prepared {
        guard let xcode = XcodeVersion.best(try await locator.installed(), requested: assignment.workflow.xcode) else {
            throw PreparationError.xcodeNotInstalled(assignment.workflow.xcode)
        }
        log("exporting on \(machineName) with Xcode \(xcode.version) (\(xcode.build)), outside the VM")
        guard let key = assignment.appStoreConnectKey else { throw PreparationError.appStoreConnectKeyMissing }
        for directory in [layout.temporaryRoot, layout.temporary] {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let developerDir = xcode.path + "/Contents/Developer"
        var environment = CIEnvironment.identityEnvironment(from: ProcessInfo.processInfo.environment)
        environment["PATH"] = Self.basePATH
        environment["DEVELOPER_DIR"] = developerDir
        environment["TMPDIR"] = layout.temporary
        return Prepared(
            environment: environment, xcodebuildEnvironment: environment, developerDir: developerDir,
            teamKey: key.isTeamKey ? key : nil, keyFile: AppStoreConnectKeyFile(directory: layout.keyDirectory),
            testDestination: nil)
    }
}

/// What a guest's archive leaves for its host, as paths in the guest. It travels as the last line of the guest's
/// standard output (`hangar-handoff {json}`).
public struct ArchiveHandOff: Codable, Equatable, Sendable {
    public var archivePath: String
    public var resultBundlePath: String
    /// `<repository>/<project directory>/TestFlight`: the What to Test notes the TestFlight post-action reads.
    public var testFlightDirectory: String
    public var fullLogPath: String
    /// Whether the server's log left something out of the guest's part (the full log is then uploaded).
    public var fullLogAbridged: Bool

    public init(
        archivePath: String, resultBundlePath: String, testFlightDirectory: String, fullLogPath: String,
        fullLogAbridged: Bool = false
    ) {
        self.archivePath = archivePath
        self.resultBundlePath = resultBundlePath
        self.testFlightDirectory = testFlightDirectory
        self.fullLogPath = fullLogPath
        self.fullLogAbridged = fullLogAbridged
    }
}

/// How a guest's job ended: reported in full by the guest, or handed to the host to export.
public enum GuestRunOutcome: Sendable, Equatable {
    case finished(JobResult)
    case handOff(ArchiveHandOff)
}
