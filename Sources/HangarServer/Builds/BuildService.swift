import Foundation
import HangarCore

public enum DeployError: Error, Equatable, Sendable {
    case appNotFound(String)
    case machineNotFound(String)
    case refNotFound(String)
    case workflowFileMissing(commit: String)
    case workflowFile(WorkflowFileError)
    case workflowNotFound(name: String, available: [String])
    case approvalNotSupported(postAction: String)
    case numbering(BuildNumberError)
    case buildNotFound(UUID)
}

/// Creates builds from `.hangar.yml` at the resolved commit and cancels them. `hangar deploy` and the web UI end up here.
public struct BuildService: Sendable {
    static let tokenVariable = "HANGAR_GITHUB_TOKEN"

    let apps: AppRepository
    let builds: BuildRepository
    let machines: MachineRepository
    let variables: VariableRepository
    let workflowFiles: WorkflowFileRepository
    let numbers: BuildNumberService
    let sourceHost: any SourceHost
    let events: EventBus
    let scheduler: SchedulerLoop
    let cancelRequests: CancelRequests
    /// Repository workflow files parsed per commit (stored workflows are read from the database every time).
    let repositoryFiles: WorkflowFileCache

    public init(
        apps: AppRepository, builds: BuildRepository, machines: MachineRepository, variables: VariableRepository,
        workflowFiles: WorkflowFileRepository, numbers: BuildNumberService, sourceHost: any SourceHost, events: EventBus, scheduler: SchedulerLoop,
        cancelRequests: CancelRequests, repositoryFiles: WorkflowFileCache = WorkflowFileCache()
    ) {
        self.repositoryFiles = repositoryFiles
        self.apps = apps
        self.builds = builds
        self.machines = machines
        self.variables = variables
        self.workflowFiles = workflowFiles
        self.numbers = numbers
        self.sourceHost = sourceHost
        self.events = events
        self.scheduler = scheduler
        self.cancelRequests = cancelRequests
    }

    /// Nothing is reserved until the workflow file is parsed, the workflow picked and the approval gate passed.
    public func deploy(_ request: DeployRequest) async throws -> Build {
        guard let app = try apps.find(slugOrID: request.app) else { throw DeployError.appNotFound(request.app) }
        var pinned: Machine?
        if let name = request.machine {
            guard let machine = try machines.find(nameOrID: name) else { throw DeployError.machineNotFound(name) }
            pinned = machine
        }
        let (commit, file, _) = try await workflows(app: app, ref: request.ref)
        guard let workflow = file.workflows[request.workflow] else {
            throw DeployError.workflowNotFound(name: request.workflow, available: file.workflows.keys.sorted())
        }
        // Phase 2 adds the approval step; until then a gated post-action cannot run.
        if let gated = workflow.postActions.first(where: \.requiresApproval) {
            throw DeployError.approvalNotSupported(postAction: gated.name)
        }

        let buildID = UUID()
        let number: Int
        do { number = try await numbers.reserve(app: app, buildID: buildID) } catch let error as BuildNumberError {
            throw DeployError.numbering(error)
        }
        // Stored with millisecond precision; rounding here keeps the returned build equal to the stored one.
        let now = dbDate(dbTime(Date()))
        let build = Build(
            id: buildID, appID: app.id, workflow: request.workflow, ref: request.ref, commit: commit,
            buildNumber: number, status: .queued, pinnedMachineID: pinned?.id, createdAt: now,
            jobs: workflow.actions.map { Job(id: UUID(), buildID: buildID, action: $0, status: .queued, createdAt: now) })
        try builds.insert(build, workflow: workflow)
        events.publish(.server(.build(build)))
        scheduler.poke()
        return build
    }

    /// Queued and assigned-but-not-started jobs are cancelled right away (an assigned job's machine is refused when it
    /// tries to start it); running ones are asked to stop via the worker heartbeat.
    public func cancel(buildID: UUID) async throws -> Build {
        guard let build = try builds.build(id: buildID) else { throw DeployError.buildNotFound(buildID) }
        guard !build.jobs.allSatisfy({ $0.status.isTerminal }) else { return build }
        let now = Date()
        var toStop: [UUID] = []
        var cancelled = false
        for job in build.jobs where !job.status.isTerminal {
            // Guarded and machine-agnostic: a job that started meanwhile is left to the worker.
            if try builds.transitionJob(id: job.id, from: [.queued, .assigned], to: .cancelled, at: now) {
                if let updated = try builds.job(id: job.id) { events.publish(.server(.job(updated))) }
                cancelled = true
                continue
            }
            if let current = try builds.job(id: job.id), current.status == .running { toStop.append(job.id) }
        }
        cancelRequests.request(toStop)
        let refreshed = try builds.refreshBuildStatus(buildID: buildID)
        events.publish(.server(.build(refreshed)))
        // A cancelled assignment frees its machine's slot.
        if cancelled { scheduler.poke() }
        return refreshed
    }

    /// The workflow file for the commit `ref` resolves to: the one defined in Hangar if there is one, otherwise
    /// `.hangar.yml` at that commit. The commit is resolved either way, so a build always records one.
    public func workflows(app: App, ref: String) async throws -> (commit: String, file: WorkflowFile, source: WorkflowSource) {
        let commit: String
        do { commit = try await sourceHost.resolveCommit(repoURL: app.repoURL, ref: ref, token: try token(app)) } catch SourceHostError.refNotFound {
            throw DeployError.refNotFound(ref)
        }
        let (file, source) = try await workflowFile(app: app, commit: commit)
        return (commit, file, source)
    }

    /// The workflow file builds of `commit` use: the one defined in Hangar if there is one, otherwise `.hangar.yml` at
    /// that commit. With `cached` (the deploy dry run, asked every few seconds) the repository's file is kept per
    /// commit, which never changes; a deploy itself always reads it.
    public func workflowFile(app: App, commit: String, cached: Bool = false) async throws -> (file: WorkflowFile, source: WorkflowSource) {
        if let stored = try workflowFiles.get(appID: app.id) { return (try Self.parse(stored.yaml), .hangar) }
        let token = try token(app)
        let read = {
            guard let text = try await sourceHost.readFile(
                repoURL: app.repoURL, commit: commit, path: WorkflowFile.path, token: token)
            else { throw DeployError.workflowFileMissing(commit: commit) }
            return try Self.parse(text)
        }
        let file = cached ? try await repositoryFiles.file(appID: app.id, commit: commit, load: read) : try await read()
        return (file, .repository)
    }

    private func token(_ app: App) throws -> String? {
        try variables.resolvedEntries(appID: app.id, workflow: nil).first { $0.name == Self.tokenVariable }?.value
    }

    private static func parse(_ text: String) throws -> WorkflowFile {
        do { return try WorkflowFileParser.parse(text) } catch { throw DeployError.workflowFile(error) }
    }
}
