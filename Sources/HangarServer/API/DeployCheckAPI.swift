import Foundation
import HangarCore
import Hummingbird

/// `GET /apps/{id}/deploy-check`: the scheduler's verdict on a deploy before it is made, so the Deploy sheet never
/// spends a build number on a build no machine can run. Reads the workflow as a deploy does and judges every action
/// with `Scheduler.ineligibility` against the machines as a tick sees them (online by the server's clock). Busy, low
/// disk and a paused machine pass with time: they are warnings, not blockers.
extension HangarServerApp {
    func addDeployCheckRoutes(to api: APIGroup) {
        api.get("apps/:id/deploy-check") { request, context in
            let app = try app(context)
            let query = request.query
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
            let resolved: String
            if let commit = query.get("commit"), !commit.isEmpty {
                guard (7...40).contains(commit.count), commit.allSatisfy(\.isHexDigit) else {
                    throw APIError(code: "invalid_request", message: "'commit' must be a commit SHA.")
                }
                resolved = String(commit)
                file = try await withAppToken(app) { _ in try await buildService.workflowFile(app: app, commit: resolved, cached: true).file }
            } else {
                (resolved, file) = try await withAppToken(app) { _ in
                    let found = try await buildService.workflows(app: app, ref: ref)
                    return (found.commit, found.file)
                }
            }
            guard let workflow = file.workflows[name] else {
                throw DeployError.workflowNotFound(name: name, available: file.workflows.keys.sorted())
            }
            let entries = try variables.resolvedEntries(appID: app.id, workflow: name)
            var check = try deployCheck(workflow: workflow, pinned: pinned, teamKey: try ascKeys.key(.main)?.isTeamKey ?? false)
            let own = try variables.summaries(scope: .app(app.id))
            let links = try variables.links(appID: app.id)
            check.notices = await preflight.notices(
                app: app, workflow: workflow, commit: resolved,
                token: entries.first { $0.name == BuildService.tokenVariable }?.value,
                definedNames: Set(entries.map(\.name)), onlyFor: Self.restrictedNames(own, links),
                appStoreConnect: { try appStoreConnectClient() })
            check.notices += Self.unknownWorkflowNotices(own, links, workflows: Set(file.workflows.keys))
            return try Response.json(check)
        }
    }

    /// Each name the app sets only for some workflows (its own variables and its groups' through limited links), with
    /// those workflows.
    static func restrictedNames(_ own: [VariableSummary], _ links: [AppVariableGroupLink]) -> [String: [String]] {
        var names: [String: Set<String>] = [:]
        for variable in own where !variable.workflows.isEmpty { names[variable.name, default: []].formUnion(variable.workflows) }
        for link in links where !link.workflows.isEmpty {
            for variable in link.variables { names[variable.name, default: []].formUnion(link.workflows) }
        }
        return names.mapValues { $0.sorted() }
    }

    /// A restriction naming a workflow the file does not have (renamed or removed) gives that value to no build of
    /// it: `unknown-workflow-names`, one notice per variable or link.
    static func unknownWorkflowNotices(
        _ own: [VariableSummary], _ links: [AppVariableGroupLink], workflows: Set<String>
    ) -> [DeployCheckNotice] {
        /// "“Beta”, but no workflow is called that" or "“Beta” and “Old”, but no workflow is called “Old”".
        func describe(_ limited: [String]) -> (none: Bool, text: String)? {
            let missing = limited.filter { !workflows.contains($0) }
            guard !missing.isEmpty else { return nil }
            let all = missing.count == limited.count
            let called = all ? (limited.count == 1 ? "that" : "any of these") : Self.listText(missing.map { "“\($0)”" }, or: true)
            return (all, "\(Self.listText(limited.map { "“\($0)”" })), but no workflow is called \(called)")
        }
        var notices: [DeployCheckNotice] = []
        for variable in own {
            guard let found = describe(variable.workflows) else { continue }
            let none = found.none
            notices.append(DeployCheckNotice(
                code: "unknown-workflow-names",
                message: "\(variable.name) is limited to \(found.text)\(none ? ": no build gets this value" : ""). Edit it under the app’s Environment."))
        }
        for link in links {
            guard let found = describe(link.workflows) else { continue }
            let none = found.none
            notices.append(DeployCheckNotice(
                code: "unknown-workflow-names",
                message: "The group “\(link.name)” is linked for \(found.text)\(none ? ": no build gets its variables" : ""). Edit the link under the app’s Environment."))
        }
        return notices
    }

    static func listText(_ items: [String], or: Bool = false) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items.last!
    }

    /// Reasons that pass with time: the job waits in the queue.
    static func passingReasons(_ reason: Ineligibility) -> Bool {
        switch reason {
        case .busy, .lowDisk, .paused: true
        default: false
        }
    }

    func deployCheck(workflow: Workflow, pinned: Machine?, teamKey: Bool = true) throws -> DeployCheck {
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
        let signingProblem = signing.jobProblem()
        for action in workflow.actions {
            let job = SchedulerLoop.queuedJob(
                id: UUID(), buildID: UUID(), createdAt: now, action: action, workflow: workflow, pinned: pinned?.id,
                teamKey: teamKey, signingProblem: signingProblem)
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
                    waits: waits[$0.id] ?? [], paused: $0.paused)
            })
    }

    /// "Archive – macOS · Legilo", as the web UI labels an action.
    static func label(_ action: WorkflowAction) -> String { "\(action.kindLabel) · \(action.scheme)" }
}
