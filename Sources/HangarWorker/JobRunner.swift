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
/// archive the App Store Connect key checked. The key comes in the assignment, never as a variable: its `.p8` is on
/// disk only while an `xcodebuild` step or a post-action that uses it runs (`AppStoreConnectKeyFile`), and no hook
/// sees it in its environment. Build phases and package plugins run as this user during those steps and can read it:
/// on a host Mac that exposure remains (VM builds keep the key out of the guest altogether). In a VM, the job's
/// `JobKeychain` is unlocked first, and codesign may use any key the archive, export or test step created, whether
/// that step succeeded or not; a local build signs with the owner's login keychain.
/// When that fails, `checkout` reports `failed` and the failure reason is the preparation error alone.
///
/// Secrets never leave the machine unmasked: every line goes through `JobLog`, which masks each secret value and the
/// contents of every as-file variable. `upload-artifacts` and `cleanup` run whatever happened, and cleanup problems
/// are logged without changing the job's result.
public struct JobRunner: Sendable {
    public typealias AppStoreConnectFactory = @Sendable (ASCCredentials) -> any AppStoreConnectClient

    static let basePATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    let connection: any ServerConnection
    let runner: any ProcessRunner
    let locator: XcodeLocator
    let dataDirectory: String
    /// Holds every job's `TMPDIR`; see `WorkspaceLayout.temporaryRoot`.
    let temporaryRoot: String
    /// Names this Mac in failure reasons.
    let machineName: String
    let clock: any Clock<Duration>
    let appStoreConnectFactory: AppStoreConnectFactory
    /// The job's own keychain in a VM guest; nil for a local build, where the owner's login keychain signs.
    let keychain: JobKeychain?
    /// The first line of the `checkout` step's log, before anything else is prepared: how a job's VM came up.
    private let preparationNote: String?
    /// A job still running after this is stopped, as a worker stop is, with the timeout as its reason. Nil: none (in
    /// a VM, whose host enforces its own).
    private let jobTimeout: Duration?
    let logger = Logger(label: "app.hangar.worker.job")
    /// How much of the pipeline runs here: all of it, or a VM guest's part of an archive (`JobRunner+VM`).
    let mode: Mode

    public init(
        connection: any ServerConnection, runner: any ProcessRunner, locator: XcodeLocator, dataDirectory: String,
        temporaryRoot: String? = nil,
        machineName: String = JobRunner.computerName,
        clock: any Clock<Duration> = ContinuousClock(),
        appStoreConnectFactory: @escaping AppStoreConnectFactory = {
            LiveAppStoreConnectClient(credentials: $0, transport: URLSessionTransport())
        },
        keychain: JobKeychain? = nil,
        preparationNote: String? = nil,
        jobTimeout: Duration? = nil,
        mode: Mode = .standard
    ) {
        self.jobTimeout = jobTimeout
        self.mode = mode
        self.keychain = keychain
        self.preparationNote = preparationNote
        self.connection = connection
        self.runner = runner
        self.locator = locator
        self.dataDirectory = dataDirectory
        self.temporaryRoot = temporaryRoot ?? WorkspaceLayout.temporaryRoot(dataDirectory: dataDirectory)
        self.machineName = machineName
        self.clock = clock
        self.appStoreConnectFactory = appStoreConnectFactory
    }

    /// What the `checkout` step prepares for the steps after it.
    struct Prepared: Sendable {
        /// Everything, for hooks and post-actions.
        var environment: [String: String]
        /// `environment` without secret variables: xcodebuild records the environment in DerivedData logs and the
        /// result bundle, which is uploaded.
        var xcodebuildEnvironment: [String: String]
        var developerDir: String
        /// The server's team key, for xcodebuild; nil for an individual key (xcodebuild then signs with the Xcode
        /// account on this Mac) or none.
        var teamKey: AppStoreConnectKey?
        /// Where the team key's `.p8` is written while a step that uses it runs.
        var keyFile: AppStoreConnectKeyFile
        /// Test jobs only.
        var testDestination: TestDestination?
    }

    /// `stopReason` says why the worker itself cancelled the job (it is shutting down); the job then reports it.
    public func run(
        _ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool,
        stopReason: @escaping @Sendable () -> String? = { nil }
    ) async -> JobResult {
        switch await execute(assignment, cancelled: cancelled, stopReason: stopReason) {
        case .finished(let result): result
        // Only a VM guest's archive hands off (`GuestJobRunner` asks for that outcome); its host reports the result.
        case .handOff: JobResult(status: .failed, failureReason: "the archive was handed to the VM's host to export")
        }
    }

    func execute(
        _ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool, stopReason: @escaping @Sendable () -> String?
    ) async -> GuestRunOutcome {
        let jobID = assignment.job.id
        let layout = WorkspaceLayout(dataDirectory: dataDirectory, appSlug: assignment.app.slug, jobID: jobID,
            temporaryRoot: temporaryRoot)
        // Marks the workspace as built now and keeps the disk sweep off it until the job ends.
        let workspaceLease = WorkspaceUse.shared.begin(layout.workspace)
        defer { workspaceLease.end() }
        let masker = SecretMasker(
            secrets: assignment.environment.filter { $0.isSecret || $0.asFile }.map(\.value)
                + [assignment.appStoreConnectKey?.privateKey].compactMap { $0 })
        let log = JobLog(jobID: jobID, masker: masker, connection: connection, clock: clock, fullLogPath: layout.fullLog)
        let materializer = SecretsMaterializer(directory: layout.secrets)
        // What the job's scripts leave running (`./mock-server &`) lives until the job ends, as in an Xcode Cloud VM.
        let leftovers = ProcessGroups()

        do {
            try await connection.start(jobID: jobID)
        } catch ServerConnectionError.status(409, _, _) {
            // Started elsewhere, moved or ended: the job is not this run's, and a finish could fail the copy that
            // does run it.
            logger.error("the server would not start the job here; leaving it alone", metadata: ["job": "\(jobID)"])
            return .finished(JobResult(status: .failed, failureReason: "start: the server no longer has this job for this machine"))
        } catch {
            logger.error("could not start job: \(error)", metadata: ["job": "\(jobID)"])
            let result = JobResult(status: .failed, failureReason: masker.mask("start: \(error)"))
            await reportFinish(jobID: jobID, result)
            return .finished(result)
        }

        await reportInfo(jobID: jobID, JobRunInfo(workerVersion: Self.workerVersion))

        // The timeout stops the job the way a worker stop does: the step it was in ends, and the job says why.
        let timedOut = Captured(false)
        let timer = jobTimeout.map { timeout in
            Task { [clock] in
                guard (try? await clock.sleep(for: timeout)) != nil else { return }
                timedOut.set(true)
            }
        }
        defer { timer?.cancel() }
        let overdue: @Sendable () -> Bool = { timedOut.get() }
        let timeoutReason = jobTimeout.map { [machineName] in
            "the job ran longer than \($0.components.seconds / 60) min, the job timeout on \(machineName)"
        }
        var pipeline = JobPipeline(
            jobID: jobID, connection: connection, log: log, clock: clock, cancelled: { cancelled() || overdue() },
            stopReason: { stopReason() ?? (overdue() ? timeoutReason : nil) }, masker: masker)
        let prepared = await pipeline.step(StepName.checkout) { [self] in
            let prepared = try await prepare(assignment, layout: layout, materializer: materializer, log: log.lines(StepName.checkout))
            try await Checkout(runner: runner, layout: layout).run(
                repoURL: assignment.app.repoURL, commit: assignment.commit,
                token: prepared.environment["HANGAR_GITHUB_TOKEN"], log: log.lines(StepName.checkout))
            return prepared
        }

        var outputs: [String: String] = [:]
        if let prepared {
            let built = await build(
                assignment, prepared: prepared, layout: layout, log: log, masker: masker, leftovers: leftovers,
                pipeline: &pipeline)
            if var handOff = built.handOff {
                // The VM's host exports and uploads; nothing is cleaned up in a VM that is about to be deleted.
                await log.finalFlush()
                handOff.fullLogAbridged = log.isAbridged
                return .handOff(handOff)
            }
            outputs = built.outputs
        } else {
            let sequence = StepName.sequence(
                for: assignment.job.action, postActions: assignment.workflow.postActions.map(\.name))
            let later = sequence.filter { ![StepName.checkout, StepName.uploadArtifacts, StepName.cleanup].contains($0) }
            for name in later { await pipeline.skip(name) }
        }

        // A worker that is shutting down has seconds before launchd kills it: a stopped job's partial artifacts are
        // not worth them.
        if pipeline.stopNote != nil {
            await pipeline.skip(StepName.uploadArtifacts)
        } else {
            await uploadArtifacts(assignment, layout: layout, log: log, pipeline: &pipeline)
        }

        await pipeline.report(StepName.cleanup, .running)
        let cleanedUp = await cleanup(
            layout: layout, materializer: materializer, leftovers: leftovers, log: log.lines(StepName.cleanup))
        await pipeline.report(StepName.cleanup, cleanedUp ? .succeeded : .failed)
        await log.finalFlush()

        // Error descriptions (an App Store Connect response body, say) and post-action outputs may hold a secret.
        let result = JobResult(
            status: pipeline.status, failureReason: pipeline.reason.map(masker.mask),
            outputs: outputs.mapValues(masker.mask))
        await reportFinish(jobID: jobID, result)
        return .finished(result)
    }

    func uploadArtifacts(
        _ assignment: JobAssignment, layout: WorkspaceLayout, log: JobLog, pipeline: inout JobPipeline
    ) async {
        let jobID = assignment.job.id
        await pipeline.step(StepName.uploadArtifacts, .always) { [connection, runner] in
            let lines = log.lines(StepName.uploadArtifacts)
            // Every piece is attempted; the step fails at the end if any could not be zipped or uploaded.
            let collection = try await ArtifactCollector(runner: runner)
                .collect(layout: layout, scheme: assignment.job.action.scheme, log: lines)
            var failures = collection.failures
            var artifacts = collection.artifacts
            // The log as xcodebuild printed it, when the server's is condensed: a copy, as lines keep coming.
            let fullLog = layout.jobDirectory + "/artifacts/" + JobLog.fullLogArtifactName
            do {
                if try log.copyFullLog(to: fullLog) {
                    artifacts.append((JobLog.fullLogArtifactName, URL(fileURLWithPath: fullLog)))
                }
            } catch {
                lines("error: could not copy the full log: \(error)")
                failures.append("could not copy the full log: \(error)")
            }
            for artifact in artifacts {
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
    }

    /// The Mac's computer name (System Settings › General › Sharing), read once without a DNS lookup.
    public static let computerName: String = {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return "this Mac"
    }()

    /// "0.5.0 (a1c9b45d)": the release and the start of this binary's SHA-256, which tells apart two builds of one
    /// release.
    public static let workerVersion: String = {
        guard let hash = WorkerSelfUpdate.executableSHA256 else { return HangarVersion.current }
        return "\(HangarVersion.current) (\(hash.prefix(8)))"
    }()

    /// Best effort: a server that predates `jobs/{id}/info` answers 404, and the job runs on regardless.
    func reportInfo(jobID: UUID, _ info: JobRunInfo) async {
        do {
            try await connection.info(jobID: jobID, info)
        } catch {
            logger.info("could not report the job's worker and Xcode: \(error)", metadata: ["job": "\(jobID)"])
        }
    }

    /// Delays between attempts to report a job's result: ten minutes in all, so a server that restarts or a network
    /// that drops meanwhile does not lose a finished build. The job stays in the worker's reports while it retries,
    /// so the server does not fail it as lost.
    static let finishRetryDelays: [Duration] =
        [1, 2, 4, 8, 15].map { Duration.seconds($0) } + Array(repeating: .seconds(30), count: 19)

    func reportFinish(jobID: UUID, _ result: JobResult) async {
        await Self.reportFinish(jobID: jobID, result, connection: connection, clock: clock, logger: logger)
    }

    /// Reports the result, retrying on `clock`. A 409 means the job is already terminal there, which counts as done.
    /// A worker shutting down cuts the wait short: one last attempt, as launchd kills it two minutes after asking.
    static func reportFinish(
        jobID: UUID, _ result: JobResult, connection: any ServerConnection, clock: any Clock<Duration>, logger: Logger
    ) async {
        var delays = finishRetryDelays[...]
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
                do { try await clock.sleep(for: delay) } catch { delays = [] }
            }
        }
    }

    /// Unlocks a VM job's keychain, picks Xcode, assembles the environment, writes as-file variables and checks the
    /// App Store Connect key: the key ID and key are required, the issuer ID only for a team key, which is the only
    /// kind xcodebuild accepts. In a VM an archive needs that team key: there is no Xcode account to fall back on
    /// (the scheduler already keeps such jobs off VM Macs; this is the check for an older server).
    private func prepare(
        _ assignment: JobAssignment, layout: WorkspaceLayout, materializer: SecretsMaterializer,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> Prepared {
        let workflow = assignment.workflow
        let action = assignment.job.action
        if let preparationNote { log(preparationNote) }
        if let keychain {
            do { try await keychain.prepare(runner: runner) } catch {
                throw PreparationError.keychainNotReady(reason: String(describing: error), machine: machineName)
            }
            log("unlocked the job's keychain (\(keychain.path))")
        }
        guard let xcode = XcodeVersion.best(try await locator.installed(), requested: workflow.xcode) else {
            throw PreparationError.xcodeNotInstalled(workflow.xcode)
        }
        log("using Xcode \(xcode.version) (\(xcode.build)) at \(xcode.path)")
        await reportInfo(jobID: assignment.job.id, JobRunInfo(xcodeVersion: xcode.version, xcodeBuild: xcode.build))
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
        // TMPDIR must exist before the first hook; cleanup removes it. The root is created 0700 too: nothing else has a
        // reason to read another job's files.
        for directory in [layout.temporaryRoot, layout.temporary] {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        merged.warnings.forEach(log)
        if WorkDirectoryMigration.dropStaleCaches(inWorkspace: layout.workspace) {
            log("Xcode's package and build caches named another folder (the workspace was moved); dropped them")
        }
        try materializer.write(merged.filesToWrite)
        // Tests sign with the key when there is one, but do not need it. A VM guest never has the server's key: its
        // archive signs with the profiles Hangar provides, or the development key (`JobRunner+VM`).
        let key = assignment.appStoreConnectKey.flatMap { Self.nonEmpty($0.keyID) != nil && Self.nonEmpty($0.privateKey) != nil ? $0 : nil }
        if case .guest(let signing) = mode {
            let secretNames = Set(assignment.environment.filter(\.isSecret).map(\.name))
            return Prepared(
                environment: merged.env, xcodebuildEnvironment: merged.env.filter { !secretNames.contains($0.key) },
                developerDir: developerDir, teamKey: signing.developmentKey,
                keyFile: AppStoreConnectKeyFile(directory: layout.keyDirectory), testDestination: testDestination)
        }
        if action.kind == .archive, key == nil { throw PreparationError.appStoreConnectKeyMissing }
        let teamKey = key?.isTeamKey == true ? key : nil
        if teamKey == nil, action.kind == .archive {
            if keychain != nil { throw PreparationError.teamKeyRequired(machine: machineName) }
            log("No team API key; xcodebuild signs with the Xcode account on this Mac.")
        }
        let secretNames = Set(assignment.environment.filter(\.isSecret).map(\.name))
        return Prepared(
            environment: merged.env, xcodebuildEnvironment: merged.env.filter { !secretNames.contains($0.key) },
            developerDir: developerDir, teamKey: teamKey, keyFile: AppStoreConnectKeyFile(directory: layout.keyDirectory),
            testDestination: testDestination)
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

    /// The steps from `post-clone` through the post-actions; returns the post-actions' merged outputs, or for a VM
    /// guest's archive that got as far as `post-xcodebuild`, what its host needs to export it.
    private func build(
        _ assignment: JobAssignment, prepared: Prepared, layout: WorkspaceLayout, log: JobLog, masker: SecretMasker,
        leftovers: ProcessGroups, pipeline: inout JobPipeline
    ) async -> (outputs: [String: String], handOff: ArchiveHandOff?) {
        let workflow = assignment.workflow
        let action = assignment.job.action
        let environment = prepared.environment
        let projectDirectory = workflow.projectDirectory
        let scripts = layout.repository + (projectDirectory == "." ? "" : "/" + projectDirectory) + "/ci_scripts"
        let hooks = HookRunner(runner: runner, leftovers: leftovers)
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
            return (summary?.masked(by: masker.mask).outputs ?? [:], nil)
        }
        await pipeline.step(StepName.archive, .xcodebuild) { [self] in
            try await allowingCodesign(log: log.lines(StepName.archive)) {
                let step = ArchiveStep(runner: runner)
                try await step.resolve(
                    workflow: workflow, action: action, repository: layout.repository, layout: layout,
                    developerDir: prepared.developerDir, environment: prepared.xcodebuildEnvironment,
                    gitHubToken: environment["HANGAR_GITHUB_TOKEN"], log: log.lines(StepName.archive))
                let signing = try guestArchiveSigning(layout: layout, log: log.lines(StepName.archive))
                try await prepared.keyFile.with(prepared.teamKey) { key in
                    try await step.archive(
                        workflow: workflow, action: action, repository: layout.repository, layout: layout,
                        developerDir: prepared.developerDir, key: key, environment: prepared.xcodebuildEnvironment,
                        signing: signing, log: log.lines(StepName.archive))
                }
            }
        }
        await pipeline.step(StepName.stamp) {
            try BuildNumberStamper().stamp(
                archivePath: archivePath, buildNumber: assignment.buildNumber, log: log.lines(StepName.stamp))
        }
        if case .guest = mode {
            let handOff = await guestPostXcodebuild(
                assignment, layout: layout, log: log, pipeline: &pipeline, hooks: hooks, scripts: scripts, environment: environment)
            return ([:], handOff)
        }
        let exported = await export(assignment, prepared: prepared, layout: layout, log: log, pipeline: &pipeline)
        let additions = CIEnvironment.postXcodebuildAdditions(
            exitCode: pipeline.xcodebuildExitCode ?? 0, action: action,
            exportedAppPath: exported?.exportedArtifactPath)
        await pipeline.step(StepName.postXcodebuild, .postXcodebuild, skippedIf: absent) {
            try await hooks.run(
                .postXcodebuild, scriptsDirectory: scripts, environment: environment.merging(additions) { _, new in new },
                log: log.lines(StepName.postXcodebuild))
        }
        let outputs = await postActions(
            assignment, prepared: prepared, layout: layout, exported: exported, log: log, masker: masker, pipeline: &pipeline)
        return (outputs, nil)
    }

    /// The `export` step: `xcodebuild -exportArchive` with the team key, if any.
    func export(
        _ assignment: JobAssignment, prepared: Prepared, layout: WorkspaceLayout, log: JobLog, pipeline: inout JobPipeline
    ) async -> ExportResult? {
        let workflow = assignment.workflow
        let archivePath = layout.archive(scheme: assignment.job.action.scheme)
        guard let export = assignment.job.action.export else { preconditionFailure("the parser requires an archive's export") }
        return await pipeline.step(StepName.export, .xcodebuild) { [self] in
            try await allowingCodesign(log: log.lines(StepName.export)) {
                try await prepared.keyFile.with(prepared.teamKey) { key in
                    try await ExportStep(runner: runner).run(
                        archivePath: archivePath, method: export, destination: "export", exportPath: layout.export,
                        jobDirectory: layout.jobDirectory, teamID: workflow.teamID, developerDir: prepared.developerDir,
                        key: key, signing: .cloudManaged, environment: prepared.xcodebuildEnvironment,
                        log: log.lines(StepName.export))
                }
            }
        }
    }

    /// The post-actions, one step each; returns their merged outputs.
    func postActions(
        _ assignment: JobAssignment, prepared: Prepared, layout: WorkspaceLayout, exported: ExportResult?, log: JobLog,
        masker: SecretMasker, pipeline: inout JobPipeline
    ) async -> [String: String] {
        let workflow = assignment.workflow
        let action = assignment.job.action
        let environment = prepared.environment
        let projectDirectory = workflow.projectDirectory
        let archivePath = layout.archive(scheme: action.scheme)
        var outputs: [String: String] = [:]
        let appStoreConnect = workflow.postActions.isEmpty ? nil : appStoreConnectClient(assignment.appStoreConnectKey)
        for spec in workflow.postActions {
            let name = StepName.postAction(spec.name)
            let makeContext = { @Sendable [runner, clock, reporter = pipeline.stageReporter(name)] (key: ASCKeyArguments?) in
                PostActionContext(
                    app: assignment.app, action: action, buildNumber: assignment.buildNumber, archivePath: archivePath,
                    exportedArtifactPath: exported?.exportedArtifactPath, repository: layout.repository,
                    projectDirectory: projectDirectory, environment: environment,
                    xcodebuildEnvironment: prepared.xcodebuildEnvironment, layout: layout,
                    developerDir: prepared.developerDir, teamID: workflow.teamID, key: key,
                    appStoreConnect: appStoreConnect, runner: runner, clock: clock, log: log.lines(name),
                    reportStages: { stages in
                        await reporter(stages.map { StepStage(name: $0.name, status: $0.status, detail: $0.detail.map(masker.mask)) })
                    })
            }
            let output = await pipeline.step(name, ending: { output in
                JobPipeline.Ending(
                    status: output.warnings.isEmpty ? .succeeded : .warning,
                    detail: output.warnings.isEmpty ? nil : masker.mask(output.warnings.joined(separator: " ")),
                    stages: output.stages?.map { stage in
                        StepStage(name: stage.name, status: stage.status, detail: stage.detail.map(masker.mask))
                    })
            }) {
                try await prepared.keyFile.with(prepared.teamKey) { key in try await PostActionRegistry.make(spec).run(makeContext(key)) }
            }
            if let output {
                for warning in output.warnings { log.line(step: name, "warning: \(warning)") }
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
        await pipeline.step(StepName.test, .xcodebuild) { [self] in
            let run = try await allowingCodesign(log: log.lines(StepName.test)) {
                try await TestStep(runner: runner).run(
                    workflow: assignment.workflow, action: action, repository: layout.repository, layout: layout,
                    developerDir: prepared.developerDir, destination: destination, key: nil,
                    environment: prepared.xcodebuildEnvironment, gitHubToken: prepared.environment["HANGAR_GITHUB_TOKEN"],
                    keyFile: (prepared.keyFile, prepared.teamKey), log: log.lines(StepName.test))
            }
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

    /// Runs `body`, an xcodebuild step with `-allowProvisioningUpdates`, which may add a signing key to the default
    /// keychain. In a VM, the job keychain's partition list is then set again so codesign can use that key without a
    /// prompt; also after a failure, so a key the failed run created works for the next one. A failure to set it is a
    /// warning: the step's own result stands.
    func allowingCodesign<Value: Sendable>(
        log: @escaping @Sendable (String) -> Void, _ body: () async throws -> Value
    ) async throws -> Value {
        guard let keychain else { return try await body() }
        let result: Result<Value, any Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        if !Task.isCancelled {
            do { try await keychain.allowCodesign(runner: runner) } catch {
                log("warning: could not let codesign use new signing keys: \(error)")
            }
        }
        return try result.get()
    }

    /// A client for the assignment's key (from memory: no file). No issuer ID means an individual key. Nil when there
    /// is no key.
    func appStoreConnectClient(_ key: AppStoreConnectKey?) -> (any AppStoreConnectClient)? {
        guard let key, let keyID = Self.nonEmpty(key.keyID), let pem = Self.nonEmpty(key.privateKey) else { return nil }
        return appStoreConnectFactory(ASCCredentials(keyID: keyID, issuerID: Self.nonEmpty(key.issuerID), privateKeyPEM: pem))
    }

    static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Wipes the secrets, cleans the repository and removes the job directory. Every problem is logged and the rest
    /// still runs; returns whether all of it worked.
    func cleanup(
        layout: WorkspaceLayout, materializer: SecretsMaterializer, leftovers: ProcessGroups,
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        var succeeded = true
        func attempt(_ what: String, _ body: () async throws -> Void) async {
            do { try await body() } catch {
                log("error: could not \(what): \(error)")
                succeeded = false
            }
        }
        // First: they hold the job's secrets in their environment, and may still write to the workspace.
        let stopped = await leftovers.stopAll()
        if stopped > 0 { log("stopped what ci_scripts left running (\(stopped) process group\(stopped == 1 ? "" : "s"))") }
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
        await attempt("empty DerivedData") { try DerivedDataPruning.prune(layout.derivedData) }
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
