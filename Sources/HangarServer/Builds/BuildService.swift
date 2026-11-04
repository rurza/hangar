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
    let numbers: BuildNumberService
    let sourceHost: any SourceHost
    let events: EventBus
    let scheduler: SchedulerLoop
    let cancelRequests: CancelRequests

    public init(
        apps: AppRepository, builds: BuildRepository, machines: MachineRepository, variables: VariableRepository,
        numbers: BuildNumberService, sourceHost: any SourceHost, events: EventBus, scheduler: SchedulerLoop,
        cancelRequests: CancelRequests
    ) {
        self.apps = apps
        self.builds = builds
        self.machines = machines
        self.variables = variables
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
        let (commit, file) = try await workflows(app: app, ref: request.ref)
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

    /// Queued jobs are cancelled right away; assigned and running ones are asked to stop via the worker heartbeat.
    public func cancel(buildID: UUID) async throws -> Build {
        guard let build = try builds.build(id: buildID) else { throw DeployError.buildNotFound(buildID) }
        guard !build.jobs.allSatisfy({ $0.status.isTerminal }) else { return build }
        let now = Date()
        var toStop: [UUID] = []
        for job in build.jobs where !job.status.isTerminal {
            if job.status == .queued, try builds.transitionJob(id: job.id, from: [.queued], to: .cancelled, at: now) { continue }
            // Assigned or running, or assigned between our read and the guarded update.
            if let current = try builds.job(id: job.id), current.status == .assigned || current.status == .running {
                toStop.append(job.id)
            }
        }
        cancelRequests.request(toStop)
        let refreshed = try builds.refreshBuildStatus(buildID: buildID)
        events.publish(.server(.build(refreshed)))
        return refreshed
    }

    /// The parsed `.hangar.yml` at the commit `ref` resolves to.
    public func workflows(app: App, ref: String) async throws -> (commit: String, file: WorkflowFile) {
        let token = try variables.resolvedEntries(appID: app.id).first { $0.name == Self.tokenVariable }?.value
        let commit: String
        do { commit = try await sourceHost.resolveCommit(repoURL: app.repoURL, ref: ref, token: token) } catch SourceHostError.refNotFound {
            throw DeployError.refNotFound(ref)
        }
        guard let text = try await sourceHost.readFile(repoURL: app.repoURL, commit: commit, path: WorkflowFile.path, token: token)
        else { throw DeployError.workflowFileMissing(commit: commit) }
        do { return (commit, try WorkflowFileParser.parse(text)) } catch {
            throw DeployError.workflowFile(error)
        }
    }
}
