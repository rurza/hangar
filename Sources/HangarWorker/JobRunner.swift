import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging
import SystemConfiguration
import Synchronization

/// Runs one assigned job end to end in the order the spec fixes (`StepName.sequence(for:postActions:)`):
/// `checkout` → `post-clone` → `pre-xcodebuild` → `archive` → `stamp` → `export` → `post-xcodebuild` →
/// `post-action:<name>`… → `upload-artifacts` → `cleanup` for an archive, and
/// `checkout` → `post-clone` → `pre-xcodebuild` → `test` → `post-xcodebuild` → `upload-artifacts` → `cleanup`
/// for a test.
///
/// The job's environment is prepared inside the `checkout` step, before any git command: Xcode is picked, a test's
/// simulator chosen, the CI environment merged with the job's variables, as-file variables written, and for an
/// archive the App Store Connect key checked.
/// When that fails, `checkout` reports `failed` and the failure reason is the preparation error alone.
///
/// Secrets never leave the machine unmasked: every line goes through `JobLog`, which masks each secret value and the
/// contents of every as-file variable. `upload-artifacts` and `cleanup` run whatever happened, and cleanup problems
/// are logged without changing the job's result.
public struct JobRunner: Sendable {
    public typealias AppStoreConnectFactory = @Sendable (ASCCredentials) -> any AppStoreConnectClient

    private static let basePATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    private let connection: any ServerConnection
    private let runner: any ProcessRunner
    private let locator: XcodeLocator
    private let dataDirectory: String
    /// Holds every job's `TMPDIR`; see `WorkspaceLayout.temporaryRoot`.
    private let temporaryRoot: String
    /// Names this Mac in failure reasons.
    private let machineName: String
    private let clock: any Clock<Duration>
    private let appStoreConnectFactory: AppStoreConnectFactory
    private let logger = Logger(label: "app.hangar.worker.job")

    public init(
        connection: any ServerConnection, runner: any ProcessRunner, locator: XcodeLocator, dataDirectory: String,
        temporaryRoot: String = WorkspaceLayout.systemTemporaryRoot,
        machineName: String = JobRunner.computerName,
        clock: any Clock<Duration> = ContinuousClock(),
        appStoreConnectFactory: @escaping AppStoreConnectFactory = {
            LiveAppStoreConnectClient(credentials: $0, transport: URLSessionTransport())
        }
    ) {
        self.connection = connection
        self.runner = runner
        self.locator = locator
        self.dataDirectory = dataDirectory
        self.temporaryRoot = temporaryRoot
        self.machineName = machineName
        self.clock = clock
        self.appStoreConnectFactory = appStoreConnectFactory
    }

    /// What the `checkout` step prepares for the steps after it.
    private struct Prepared: Sendable {
        /// Everything, for hooks and post-actions.
        var environment: [String: String]
        /// `environment` without secret variables: xcodebuild records the environment in DerivedData logs and the
        /// result bundle, which is uploaded.
        var xcodebuildEnvironment: [String: String]
        var developerDir: String
        /// Nil for an individual key: xcodebuild then signs with the Xcode account on this Mac.
        var key: ASCKeyArguments?
        /// Test jobs only.
        var testDestination: TestDestination?
    }

    public func run(_ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool) async -> JobResult {
        let jobID = assignment.job.id
        let layout = WorkspaceLayout(dataDirectory: dataDirectory, appSlug: assignment.app.slug, jobID: jobID,
            temporaryRoot: temporaryRoot)
        let masker = SecretMasker(secrets: assignment.environment.filter { $0.isSecret || $0.asFile }.map(\.value))
        let log = JobLog(jobID: jobID, masker: masker, connection: connection, clock: clock)
        let materializer = SecretsMaterializer(directory: layout.secrets)

        do {
            try await connection.start(jobID: jobID)
        } catch {
            logger.error("could not start job: \(error)", metadata: ["job": "\(jobID)"])
            let result = JobResult(status: .failed, failureReason: masker.mask("start: \(error)"))
            await reportFinish(jobID: jobID, result)
            return result
        }

        var pipeline = JobPipeline(jobID: jobID, connection: connection, log: log, clock: clock, cancelled: cancelled)
        let prepared = await pipeline.step(StepName.checkout) { [self] in
            let prepared = try await prepare(assignment, layout: layout, materializer: materializer, log: log.lines(StepName.checkout))
            try await Checkout(runner: runner, layout: layout).run(
                repoURL: assignment.app.repoURL, commit: assignment.commit,
                token: prepared.environment["HANGAR_GITHUB_TOKEN"], log: log.lines(StepName.checkout))
            return prepared
        }

        var outputs: [String: String] = [:]
        if let prepared {
            outputs = await build(
                assignment, prepared: prepared, layout: layout, log: log, masker: masker, pipeline: &pipeline)
        } else {
            let sequence = StepName.sequence(
                for: assignment.job.action, postActions: assignment.workflow.postActions.map(\.name))
            let later = sequence.filter { ![StepName.checkout, StepName.uploadArtifacts, StepName.cleanup].contains($0) }
            for name in later { await pipeline.skip(name) }
        }

        await pipeline.step(StepName.uploadArtifacts, .always) { [connection, runner] in
            let lines = log.lines(StepName.uploadArtifacts)
            // Every piece is attempted; the step fails at the end if any could not be zipped or uploaded.
            let collection = try await ArtifactCollector(runner: runner)
                .collect(layout: layout, scheme: assignment.job.action.scheme, log: lines)
            var failures = collection.failures
            for artifact in collection.artifacts {
                lines("uploading \(artifact.name)")
                do {
                    try await connection.uploadArtifact(jobID: jobID, name: artifact.name, fileURL: artifact.url)
                } catch {
                    lines("error: could not upload \(artifact.name): \(error)")
                    failures.append("could not upload \(artifact.name): \(error)")
                }
            }
            if !failures.isEmpty { throw ArtifactError.incomplete(failures) }
        }

        await pipeline.report(StepName.cleanup, .running)
        let cleanedUp = await cleanup(layout: layout, materializer: materializer, log: log.lines(StepName.cleanup))
        await pipeline.report(StepName.cleanup, cleanedUp ? .succeeded : .failed)
        await log.finalFlush()

        // Error descriptions (an App Store Connect response body, say) and post-action outputs may hold a secret.
        let result = JobResult(
            status: pipeline.status, failureReason: pipeline.failureReason.map(masker.mask),
            outputs: outputs.mapValues(masker.mask))
        await reportFinish(jobID: jobID, result)
        return result
    }

    /// The Mac's computer name (System Settings › General › Sharing), read once without a DNS lookup.
    public static let computerName: String = {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return "this Mac"
    }()

    /// Delays between attempts to report a job's result; five attempts in all.
    static let finishRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    /// Reports the result, retrying on the injected clock: a lost finish would leave the job running on the server
    /// until the heartbeat stops listing it. A 409 means the job is already terminal there, which counts as done.
    private func reportFinish(jobID: UUID, _ result: JobResult) async {
        var delays = Self.finishRetryDelays[...]
        while true {
            do {
                try await connection.finish(jobID: jobID, result)
                return
            } catch ServerConnectionError.status(409, _, _) {
                logger.info("the server already has the job finished", metadata: ["job": "\(jobID)"])
                return
            } catch {
                guard let delay = delays.popFirst() else {
                    logger.error("could not report the job's result: \(error)", metadata: ["job": "\(jobID)"])
                    return
                }
                logger.warning("could not report the job's result: \(error); retrying in \(delay)", metadata: ["job": "\(jobID)"])
                // A cancelled sleep (the worker shutting down) still gets the remaining attempts, without waiting.
                try? await clock.sleep(for: delay)
            }
        }
    }

    /// Picks Xcode, assembles the environment, writes as-file variables and checks the App Store Connect key: the key
    /// ID and key are required, the issuer ID only for a team key, which is the only kind xcodebuild accepts.
    private func prepare(
        _ assignment: JobAssignment, layout: WorkspaceLayout, materializer: SecretsMaterializer,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> Prepared {
        let workflow = assignment.workflow
        let action = assignment.job.action
        guard let xcode = XcodeVersion.best(try await locator.installed(), requested: workflow.xcode) else {
            throw PreparationError.xcodeNotInstalled(workflow.xcode)
        }
        log("using Xcode \(xcode.version) (\(xcode.build)) at \(xcode.path)")
        let developerDir = xcode.path + "/Contents/Developer"
        let testDestination = action.kind == .test ? try await destination(for: action, developerDir: developerDir) : nil
        if let testDestination {
            log("testing on \([testDestination.deviceType, testDestination.runtime].compactMap { $0 }.joined(separator: ", "))")
        }
        let paths = CIEnvironment.Paths(
            repository: layout.repository, projectFile: layout.repository + "/" + workflow.projectOrWorkspacePath,
            derivedData: layout.derivedData, archive: layout.archive(scheme: action.scheme),
            resultBundle: layout.resultBundle, workspace: layout.jobDirectory,
            temporary: layout.temporary)
        let ci = CIEnvironment.make(
            app: assignment.app, workflow: assignment.workflowName, action: action, buildNumber: assignment.buildNumber,
            jobID: assignment.job.id, buildID: assignment.job.buildID, commit: assignment.commit, ref: assignment.ref,
            teamID: workflow.teamID, paths: paths, developerDir: developerDir, basePATH: Self.basePATH,
            testDestination: testDestination)
        let merged = CIEnvironment.merge(ci: ci, entries: assignment.environment, secretsDirectory: layout.secrets)
        // TMPDIR must exist before the first hook; cleanup removes it. The root is created 0700 too: it is the user's
        // temp directory, but nothing else has a reason to read another job's files.
        for directory in [layout.temporaryRoot, layout.temporary] {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        merged.warnings.forEach(log)
        try materializer.write(merged.filesToWrite)
        // Tests sign with the key when there is one, but do not need it.
        let keyConfigured = Self.nonEmpty(merged.env["HANGAR_ASC_KEY_ID"]) != nil
            && Self.nonEmpty(merged.env["HANGAR_ASC_KEY_PATH"]) != nil
        if action.kind == .archive, !keyConfigured { throw PreparationError.appStoreConnectKeyMissing }
        let key = ASCKeyArguments(environment: merged.env)
        if key == nil, action.kind == .archive { log("No team API key; xcodebuild signs with the Xcode account on this Mac.") }
        let secretNames = Set(assignment.environment.filter(\.isSecret).map(\.name))
        return Prepared(
            environment: merged.env, xcodebuildEnvironment: merged.env.filter { !secretNames.contains($0.key) },
            developerDir: developerDir, key: key, testDestination: testDestination)
    }

    /// `platform=macOS` for macOS; otherwise the simulator `SimulatorCatalog.select` picks from this Mac's list,
    /// read with the job's Xcode.
    private func destination(for action: WorkflowAction, developerDir: String) async throws -> TestDestination {
        if action.platform == .macOS { return TestDestination(xcodebuildDestination: "platform=macOS", deviceType: "Mac") }
        var environment = CIEnvironment.identityEnvironment(from: ProcessInfo.processInfo.environment)
        environment["DEVELOPER_DIR"] = developerDir
        environment["PATH"] = Self.basePATH
        let command = ProcessCommand(
            executable: "/usr/bin/xcrun", arguments: SimulatorCatalog.listArguments, environment: environment,
            discardsStandardError: true)
        let outcome = try await runner.run(command, onLine: { _ in })
        let devices = outcome.exitCode == 0 ? SimulatorCatalog.devices(fromJSON: Data(outcome.output.utf8)) : []
        let platform = action.platform.ciName
        guard let device = SimulatorCatalog.select(platform: action.platform, destination: action.destination, from: devices)
        else {
            let available = devices.filter { $0.platform == action.platform }.map(\.name)
            if let name = action.destination, !available.isEmpty {
                throw PreparationError.simulatorNotFound(
                    name: name, platform: platform, machine: machineName, available: Array(Set(available)).sorted())
            }
            throw PreparationError.noSimulator(platform: platform, machine: machineName)
        }
        return device.testDestination
    }

    /// The steps from `post-clone` through the post-actions; returns the post-actions' merged outputs.
    private func build(
        _ assignment: JobAssignment, prepared: Prepared, layout: WorkspaceLayout, log: JobLog, masker: SecretMasker,
        pipeline: inout JobPipeline
    ) async -> [String: String] {
        let workflow = assignment.workflow
        let action = assignment.job.action
        let environment = prepared.environment
        let projectDirectory = workflow.projectDirectory
        let scripts = layout.repository + (projectDirectory == "." ? "" : "/" + projectDirectory) + "/ci_scripts"
        let hooks = HookRunner(runner: runner)
        let archivePath = layout.archive(scheme: action.scheme)
        let absent: (HookOutcome) -> Bool = { $0 == .absent }

        for (name, hook) in [(StepName.postClone, Hook.postClone), (StepName.preXcodebuild, Hook.preXcodebuild)] {
            await pipeline.step(name, skippedIf: absent) {
                try await hooks.run(hook, scriptsDirectory: scripts, environment: environment, log: log.lines(name))
            }
        }
        switch action.kind {
        case .archive: break
        case .test:
            guard let destination = prepared.testDestination else { preconditionFailure("prepare picks a test's destination") }
            let summary = await test(
                assignment, prepared: prepared, destination: destination, layout: layout, log: log, pipeline: &pipeline,
                hooks: hooks, scripts: scripts)
            return summary?.masked(by: masker.mask).outputs ?? [:]
        }
        await pipeline.step(StepName.archive, .xcodebuild) { [runner] in
            try await ArchiveStep(runner: runner).run(
                workflow: workflow, action: action, repository: layout.repository, layout: layout,
                developerDir: prepared.developerDir, key: prepared.key, environment: prepared.xcodebuildEnvironment,
                gitHubToken: environment["HANGAR_GITHUB_TOKEN"], log: log.lines(StepName.archive))
        }
        await pipeline.step(StepName.stamp) {
            try BuildNumberStamper().stamp(
                archivePath: archivePath, buildNumber: assignment.buildNumber, log: log.lines(StepName.stamp))
        }
        guard let export = action.export else { preconditionFailure("the parser requires an archive's export") }
        let exported = await pipeline.step(StepName.export, .xcodebuild) { [runner] in
            try await ExportStep(runner: runner).run(
                archivePath: archivePath, method: export, destination: "export", exportPath: layout.export,
                jobDirectory: layout.jobDirectory, teamID: workflow.teamID, developerDir: prepared.developerDir,
                key: prepared.key, signing: .cloudManaged, environment: prepared.xcodebuildEnvironment,
                log: log.lines(StepName.export))
        }
        let additions = CIEnvironment.postXcodebuildAdditions(
            exitCode: pipeline.xcodebuildExitCode ?? 0, action: action,
            exportedAppPath: exported?.exportedArtifactPath)
        await pipeline.step(StepName.postXcodebuild, .postXcodebuild, skippedIf: absent) {
            try await hooks.run(
                .postXcodebuild, scriptsDirectory: scripts, environment: environment.merging(additions) { _, new in new },
                log: log.lines(StepName.postXcodebuild))
        }

        var outputs: [String: String] = [:]
        let appStoreConnect = workflow.postActions.isEmpty ? nil : appStoreConnectClient(environment)
        for spec in workflow.postActions {
            let name = StepName.postAction(spec.name)
            let context = PostActionContext(
                app: assignment.app, action: action, buildNumber: assignment.buildNumber, archivePath: archivePath,
                exportedArtifactPath: exported?.exportedArtifactPath, repository: layout.repository,
                projectDirectory: projectDirectory, environment: environment,
                xcodebuildEnvironment: prepared.xcodebuildEnvironment, layout: layout,
                developerDir: prepared.developerDir, teamID: workflow.teamID, key: prepared.key,
                appStoreConnect: appStoreConnect, runner: runner, clock: clock, log: log.lines(name))
            let output = await pipeline.step(name) { try await PostActionRegistry.make(spec).run(context) }
            if let output {
                log.line(step: name, output.summary)
                outputs.merge(output.outputs) { _, new in new }
            }
        }
        return outputs
    }

    /// `test` and `post-xcodebuild` of a test job; returns the summary when the result bundle could be read, whether
    /// the tests passed or not.
    private func test(
        _ assignment: JobAssignment, prepared: Prepared, destination: TestDestination, layout: WorkspaceLayout,
        log: JobLog, pipeline: inout JobPipeline, hooks: HookRunner, scripts: String
    ) async -> TestSummary? {
        let action = assignment.job.action
        let summary = Captured<TestSummary?>(nil)
        await pipeline.step(StepName.test, .xcodebuild) { [runner] in
            let run = try await TestStep(runner: runner).run(
                workflow: assignment.workflow, action: action, repository: layout.repository, layout: layout,
                developerDir: prepared.developerDir, destination: destination, key: prepared.key,
                environment: prepared.xcodebuildEnvironment, gitHubToken: prepared.environment["HANGAR_GITHUB_TOKEN"],
                log: log.lines(StepName.test))
            summary.set(run.summary)
            try run.check()
        }
        let additions = CIEnvironment.postXcodebuildAdditions(
            exitCode: pipeline.xcodebuildExitCode ?? 0, action: action, exportedAppPath: nil)
        await pipeline.step(StepName.postXcodebuild, .postXcodebuild, skippedIf: { $0 == .absent }) {
            try await hooks.run(
                .postXcodebuild, scriptsDirectory: scripts,
                environment: prepared.environment.merging(additions) { _, new in new },
                log: log.lines(StepName.postXcodebuild))
        }
        return summary.get()
    }

    /// Credentials from the reserved variables; the private key is read from the file `HANGAR_ASC_KEY_PATH` names,
    /// which `prepare` wrote. No issuer ID means an individual key. Nil when the key ID or the key is missing.
    private func appStoreConnectClient(_ environment: [String: String]) -> (any AppStoreConnectClient)? {
        guard let keyID = Self.nonEmpty(environment["HANGAR_ASC_KEY_ID"]),
            let keyPath = Self.nonEmpty(environment["HANGAR_ASC_KEY_PATH"]),
            let pem = try? String(contentsOfFile: keyPath, encoding: .utf8)
        else { return nil }
        return appStoreConnectFactory(
            ASCCredentials(keyID: keyID, issuerID: Self.nonEmpty(environment["HANGAR_ASC_ISSUER_ID"]), privateKeyPEM: pem))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Wipes the secrets, cleans the repository and removes the job directory. Every problem is logged and the rest
    /// still runs; returns whether all of it worked.
    private func cleanup(layout: WorkspaceLayout, materializer: SecretsMaterializer, log: @escaping @Sendable (String) -> Void) async -> Bool {
        var succeeded = true
        func attempt(_ what: String, _ body: () async throws -> Void) async {
            do { try await body() } catch {
                log("error: could not \(what): \(error)")
                succeeded = false
            }
        }
        await attempt("wipe secrets") { try materializer.wipe() }
        if FileManager.default.fileExists(atPath: layout.repository) {
            await attempt("clean the repository") {
                // Doubled -f, as in Checkout: nested repositories are removed too.
                let command = ProcessCommand(
                    executable: "/usr/bin/git", arguments: ["-C", layout.repository, "clean", "-ffdx"],
                    environment: Checkout.environment(token: nil))
                let outcome = try await runner.run(command, onLine: log)
                if outcome.exitCode != 0 { throw CheckoutError.gitFailed(command: "git clean -ffdx", exitCode: outcome.exitCode) }
            }
        }
        await attempt("remove the temporary directory") {
            try SafeRemoval.removeItem(atPath: layout.temporary, within: layout.temporaryRoot)
        }
        await attempt("remove the job directory") {
            try SafeRemoval.removeItem(atPath: layout.jobDirectory, within: dataDirectory + "/jobs")
        }
        return succeeded
    }
}

/// A value a `@Sendable` step body hands back to the code around it.
final class Captured<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func get() -> Value { value.withLock { $0 } }
    func set(_ new: Value) { value.withLock { $0 = new } }
}
