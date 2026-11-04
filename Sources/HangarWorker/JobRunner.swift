import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging

/// Runs one assigned job end to end in the order the spec fixes:
/// `checkout` → `post-clone` → `pre-xcodebuild` → `archive` → `stamp` → `export` → `post-xcodebuild` →
/// `post-action:<name>`… → `upload-artifacts` → `cleanup`.
///
/// The job's environment is prepared inside the `checkout` step, before any git command: Xcode is picked, the CI
/// environment merged with the job's variables, as-file variables written, and the App Store Connect key checked.
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
    private let clock: any Clock<Duration>
    private let appStoreConnectFactory: AppStoreConnectFactory
    private let logger = Logger(label: "app.hangar.worker.job")

    public init(
        connection: any ServerConnection, runner: any ProcessRunner, locator: XcodeLocator, dataDirectory: String,
        clock: any Clock<Duration> = ContinuousClock(),
        appStoreConnectFactory: @escaping AppStoreConnectFactory = {
            LiveAppStoreConnectClient(credentials: $0, transport: URLSessionTransport())
        }
    ) {
        self.connection = connection
        self.runner = runner
        self.locator = locator
        self.dataDirectory = dataDirectory
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
        var key: ASCKeyArguments
    }

    public func run(_ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool) async -> JobResult {
        let jobID = assignment.job.id
        let layout = WorkspaceLayout(dataDirectory: dataDirectory, appSlug: assignment.app.slug, jobID: jobID)
        let masker = SecretMasker(secrets: assignment.environment.filter { $0.isSecret || $0.asFile }.map(\.value))
        let log = JobLog(jobID: jobID, masker: masker, connection: connection, clock: clock)
        let materializer = SecretsMaterializer(directory: layout.secrets)

        do {
            try await connection.start(jobID: jobID)
        } catch {
            logger.error("could not start job: \(error)", metadata: ["job": "\(jobID)"])
            let result = JobResult(status: .failed, failureReason: masker.mask("start: \(error)"))
            try? await connection.finish(jobID: jobID, result)
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
            outputs = await build(assignment, prepared: prepared, layout: layout, log: log, pipeline: &pipeline)
        } else {
            let later = [StepName.postClone, StepName.preXcodebuild, StepName.archive, StepName.stamp, StepName.export,
                         StepName.postXcodebuild] + assignment.workflow.postActions.map { StepName.postAction($0.name) }
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
        do {
            try await connection.finish(jobID: jobID, result)
        } catch {
            logger.error("could not report the job's result: \(error)", metadata: ["job": "\(jobID)"])
        }
        return result
    }

    /// Picks Xcode, assembles the environment, writes as-file variables and checks the App Store Connect key.
    private func prepare(
        _ assignment: JobAssignment, layout: WorkspaceLayout, materializer: SecretsMaterializer,
        log: @Sendable (String) -> Void
    ) async throws -> Prepared {
        let workflow = assignment.workflow
        let action = assignment.job.action
        guard let xcode = XcodeVersion.best(try await locator.installed(), requested: workflow.xcode) else {
            throw PreparationError.xcodeNotInstalled(workflow.xcode)
        }
        log("using Xcode \(xcode.version) (\(xcode.build)) at \(xcode.path)")
        let developerDir = xcode.path + "/Contents/Developer"
        let paths = CIEnvironment.Paths(
            repository: layout.repository, projectFile: layout.repository + "/" + workflow.projectOrWorkspacePath,
            derivedData: layout.derivedData, archive: layout.archive(scheme: action.scheme),
            resultBundle: layout.resultBundle, workspace: layout.jobDirectory)
        let ci = CIEnvironment.make(
            app: assignment.app, workflow: assignment.workflowName, action: action, buildNumber: assignment.buildNumber,
            jobID: assignment.job.id, buildID: assignment.job.buildID, commit: assignment.commit, ref: assignment.ref,
            teamID: workflow.teamID, paths: paths, developerDir: developerDir, basePATH: Self.basePATH)
        let merged = CIEnvironment.merge(ci: ci, entries: assignment.environment, secretsDirectory: layout.secrets)
        merged.warnings.forEach(log)
        try materializer.write(merged.filesToWrite)
        guard let key = ASCKeyArguments(environment: merged.env) else { throw PreparationError.appStoreConnectKeyMissing }
        let secretNames = Set(assignment.environment.filter(\.isSecret).map(\.name))
        return Prepared(
            environment: merged.env, xcodebuildEnvironment: merged.env.filter { !secretNames.contains($0.key) },
            developerDir: developerDir, key: key)
    }

    /// The steps from `post-clone` through the post-actions; returns the post-actions' merged outputs.
    private func build(
        _ assignment: JobAssignment, prepared: Prepared, layout: WorkspaceLayout, log: JobLog,
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
        await pipeline.step(StepName.archive, .xcodebuild) { [runner] in
            try await ArchiveStep(runner: runner).run(
                workflow: workflow, action: action, repository: layout.repository, layout: layout,
                developerDir: prepared.developerDir, key: prepared.key, environment: prepared.xcodebuildEnvironment,
                log: log.lines(StepName.archive))
        }
        await pipeline.step(StepName.stamp) {
            try BuildNumberStamper().stamp(
                archivePath: archivePath, buildNumber: assignment.buildNumber, log: log.lines(StepName.stamp))
        }
        let exported = await pipeline.step(StepName.export, .xcodebuild) { [runner] in
            try await ExportStep(runner: runner).run(
                archivePath: archivePath, method: action.export, destination: "export", exportPath: layout.export,
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

    /// Credentials from the reserved variables; the private key is read from the file `HANGAR_ASC_KEY_PATH` names,
    /// which `prepare` wrote. Nil when any piece is missing.
    private func appStoreConnectClient(_ environment: [String: String]) -> (any AppStoreConnectClient)? {
        guard let keyID = environment["HANGAR_ASC_KEY_ID"], let issuerID = environment["HANGAR_ASC_ISSUER_ID"],
            let keyPath = environment["HANGAR_ASC_KEY_PATH"],
            let pem = try? String(contentsOfFile: keyPath, encoding: .utf8)
        else { return nil }
        return appStoreConnectFactory(ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem))
    }

    /// Wipes the secrets, cleans the repository and removes the job directory. Every problem is logged and the rest
    /// still runs; returns whether all of it worked.
    private func cleanup(layout: WorkspaceLayout, materializer: SecretsMaterializer, log: @Sendable (String) -> Void) async -> Bool {
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
        await attempt("remove the job directory") {
            try SafeRemoval.removeItem(atPath: layout.jobDirectory, within: dataDirectory + "/jobs")
        }
        return succeeded
    }
}
