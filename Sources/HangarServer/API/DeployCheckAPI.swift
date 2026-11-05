import Foundation
import HangarCore
import Hummingbird

/// `GET /apps/{id}/deploy-check`: the scheduler's verdict on a deploy before it is made, so the Deploy sheet never
/// spends a build number on a build no machine can run. Reads the workflow as a deploy does and judges every action
/// with `Scheduler.ineligibility` against the machines as a tick sees them (online by the server's clock). Busy and
/// low disk pass with time: they are warnings, not blockers.
extension HangarServerApp {
    func addDeployCheckRoutes(to api: APIGroup) {
        api.get("apps/:id/deploy-check") { request, context in
            let app = try app(context)
            let query = request.uri.queryParameters
            let name = query.get("workflow").map { String($0) } ?? ""
            let ref = query.get("ref").flatMap { $0.isEmpty ? nil : String($0) } ?? "HEAD"
            var pinned: Machine?
            if let key = query.get("machine"), !key.isEmpty {
                guard let machine = try machines.find(nameOrID: String(key)) else { throw DeployError.machineNotFound(String(key)) }
                pinned = machine
            }
            // With `commit` (the one `/workflows` resolved for the sheet), GitHub is not asked to resolve the ref, and the
            // repository's file comes from the per-commit cache: a sheet checking every 15 s costs no GitHub calls.
            let file: WorkflowFile
            if let commit = query.get("commit"), !commit.isEmpty {
                guard (7...40).contains(commit.count), commit.allSatisfy(\.isHexDigit) else {
                    throw APIError(code: "invalid_request", message: "'commit' must be a commit SHA.")
                }
                file = try await withAppToken(app) { _ in try await buildService.workflowFile(app: app, commit: String(commit), cached: true).file }
            } else {
                file = try await withAppToken(app) { _ in try await buildService.workflows(app: app, ref: ref).file }
            }
            guard let workflow = file.workflows[name] else {
                throw DeployError.workflowNotFound(name: name, available: file.workflows.keys.sorted())
            }
            return try Response.json(try deployCheck(workflow: workflow, pinned: pinned))
        }
    }

    /// Reasons that pass with time: the job waits in the queue.
    static func passingReasons(_ reason: Ineligibility) -> Bool {
        switch reason {
        case .busy, .lowDisk: true
        default: false
        }
    }

    func deployCheck(workflow: Workflow, pinned: Machine?) throws -> DeployCheck {
        let now = now()
        let running = try SchedulerLoop.runningCounts(builds)
        let all = try machines.all().sorted { $0.name < $1.name }
        let snapshots = (pinned.map { machine in all.filter { $0.id == machine.id } } ?? all)
            .map { SchedulerLoop.snapshot($0, runningJobs: running[$0.id] ?? 0, now: now) }
        var blocking: [DeployCheckAction] = []
        var warnings: [DeployCheckAction] = []
        var problems: [UUID: [String]] = [:]
        var waits: [UUID: [String]] = [:]
        func add(_ reason: String, to list: inout [UUID: [String]], _ id: UUID) {
            if !(list[id] ?? []).contains(reason) { list[id, default: []].append(reason) }
        }
        for action in workflow.actions {
            let job = SchedulerLoop.queuedJob(
                id: UUID(), buildID: UUID(), createdAt: now, action: action, workflow: workflow, pinned: pinned?.id)
            var reasons: [String: [String]] = [:]
            var runnable = false
            var free = false
            for machine in snapshots {
                let found = Scheduler.ineligibility(of: job, on: machine, minFreeDiskGB: configuration.minFreeDiskGB)
                if found.isEmpty { free = true }
                if found.allSatisfy(Self.passingReasons) { runnable = true }
                if !found.isEmpty { reasons[machine.name] = found.map(\.description) }
                for reason in found {
                    if Self.passingReasons(reason) { add(reason.description, to: &waits, machine.id) }
                    else { add(reason.description, to: &problems, machine.id) }
                }
            }
            let entry = DeployCheckAction(action: Self.label(action), reasons: reasons)
            if !runnable { blocking.append(entry) } else if !free { warnings.append(entry) }
        }
        return DeployCheck(
            canDeploy: blocking.isEmpty, blocking: blocking, warnings: warnings,
            machines: snapshots.map {
                DeployCheckMachine(
                    id: $0.id.uuidString, name: $0.name, online: $0.isOnline, problems: problems[$0.id] ?? [],
                    waits: waits[$0.id] ?? [])
            })
    }

    /// "Archive – macOS · Legilo", as the web UI labels an action.
    static func label(_ action: WorkflowAction) -> String { "\(action.kindLabel) · \(action.scheme)" }
}
