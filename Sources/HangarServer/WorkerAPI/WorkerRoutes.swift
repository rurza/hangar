import Foundation
import HangarCore
import Hummingbird

/// The routes worker machines call, under `/api/v1/worker`, each authenticated by the machine's token.
///
/// `GET /jobs/next` is the only response that carries variable values, and only to the machine the job is
/// assigned to. Nothing here logs request bodies or the environment.
extension HangarServerApp {
    static let defaultJobWait = 25
    static let maxJobWait = 60

    func addWorkerRoutes(to api: APIGroup) {
        let worker = api.group("worker").add(middleware: MachineAuth(machines: machines))

        worker.post("heartbeat") { request, context in
            let machine = try context.requireMachine()
            let input = try await request.decode(as: HeartbeatRequest.self, context: context)
            try machines.updateReport(id: machine.id, report: input.report, seenAt: now())
            if let updated = try machines.find(nameOrID: machine.id.uuidString) {
                events.publish(.server(.machine(updated)))
            }
            // The worker's own list covers a job it still runs after the server stopped counting it as the machine's.
            let onMachine = try builds.jobs(status: [.assigned, .running]).filter { $0.machineID == machine.id }.map(\.id)
            let cancel = cancelRequests.pending(for: Array(Set(onMachine + input.report.runningJobIDs)))
            scheduler.poke()
            return try Response.json(HeartbeatResponse(cancelJobIDs: cancel.sorted { $0.uuidString < $1.uuidString }))
        }

        worker.get("jobs/next") { request, context in
            let machine = try context.requireMachine()
            let wait = min(try request.integer("wait") ?? Self.defaultJobWait, Self.maxJobWait)
            guard let assignment = try await nextAssignment(machineID: machine.id, wait: .seconds(wait)) else {
                return Response(status: .noContent)
            }
            return try Response.json(assignment)
        }

        worker.post("jobs/:id/start") { _, context in
            let job = try workerJob(context)
            guard try builds.transitionJob(id: job.id, from: [.assigned], to: .running, at: now()) else {
                throw try stateConflict(job.id, "cannot start")
            }
            return try Response.json(publishChange(of: job))
        }

        worker.post("jobs/:id/steps") { request, context in
            let job = try running(workerJob(context))
            let update = try await request.decode(as: StepUpdate.self, context: context)
            try builds.upsertStep(jobID: job.id, update)
            let updated = try current(job.id)
            events.publish(.server(.job(updated)))
            return try Response.json(updated)
        }

        worker.post("jobs/:id/log") { request, context in
            let job = try running(workerJob(context))
            let batch = try await request.decode(as: LogBatch.self, context: context)
            guard !batch.entries.isEmpty else { return Response(status: .noContent) }
            // Stored before the event goes out: log followers read the file when the event arrives.
            try await logStore.append(jobID: job.id, batch.entries)
            events.publish(.log(jobID: job.id, batch.entries))
            return Response(status: .noContent)
        }

        // Only while the job runs: the worker uploads in its `upload-artifacts` step, before it reports the finish.
        worker.post("jobs/:id/artifacts/:name") { request, context in
            let job = try running(workerJob(context))
            let name = try context.parameters.require("name")
            // Streamed to disk chunk by chunk, so Hummingbird's upload limit (which applies to collected bodies)
            // does not cap archives and dSYMs.
            let url = try await artifactStore.write(jobID: job.id, name: name, stream: request.body)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            return try Response.json(ArtifactInfo(name: name, sizeBytes: size), status: .created)
        }

        worker.post("jobs/:id/finish") { request, context in
            let job = try workerJob(context)
            let result = try await request.decode(as: JobResult.self, context: context)
            guard result.status.isTerminal else {
                throw APIError(
                    code: "invalid_job_result",
                    message: "A job finishes as succeeded, failed or cancelled, not \(result.status.rawValue).")
            }
            guard
                try builds.transitionJob(
                    id: job.id, from: [.assigned, .running], to: result.status, at: now(),
                    failureReason: result.failureReason)
            else { throw try stateConflict(job.id, "cannot finish") }
            try builds.setOutputs(jobID: job.id, result.outputs)
            cancelRequests.clear(job.id)
            let finished = try publishChange(of: job)
            scheduler.poke()
            return try Response.json(finished)
        }
    }

    /// The oldest job assigned to the machine, or, failing that, the first one assigned within `wait` (on the
    /// injected clock); nil when none was.
    func nextAssignment(machineID: UUID, wait: Duration) async throws -> JobAssignment? {
        // Subscribed before looking, so an assignment made between the look and the wait still wakes us.
        let updates = events.subscribe()
        if let assignment = try assignment(machineID: machineID) { return assignment }
        guard wait > .zero else { return nil }
        return try await withThrowingTaskGroup(of: JobAssignment?.self) { group in
            group.addTask {
                for await event in updates {
                    guard case .server(.job(let job)) = event, job.machineID == machineID, job.status == .assigned
                    else { continue }
                    if let assignment = try assignment(machineID: machineID) { return assignment }
                }
                return nil
            }
            group.addTask { [clock] in
                try await clock.sleep(for: wait)
                return nil
            }
            // The loser is cancelled; its result or cancellation error is never asked for.
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func assignment(machineID: UUID) throws -> JobAssignment? {
        guard let job = try builds.jobs(status: [.assigned]).first(where: { $0.machineID == machineID }) else { return nil }
        guard let build = try builds.build(id: job.buildID), let app = try apps.find(slugOrID: build.appID.uuidString),
            let workflow = try builds.workflow(buildID: build.id)
        else { throw IncompleteJob(jobID: job.id) }
        return JobAssignment(
            job: job, app: app, workflow: workflow, buildNumber: build.buildNumber, commit: build.commit, ref: build.ref,
            environment: try variables.resolvedEntries(appID: app.id))
    }

    /// The `{id}` job, which must be assigned to the authenticated machine.
    private func workerJob(_ context: HangarRequestContext) throws -> Job {
        let machine = try context.requireMachine()
        let job = try job(context)
        guard job.machineID == machine.id else {
            throw APIError(
                code: "job_not_assigned_to_machine",
                message: "Job \(job.id.uuidString) is not assigned to machine '\(machine.name)'.")
        }
        return job
    }

    private func running(_ job: Job) throws -> Job {
        guard job.status == .running else {
            throw APIError(code: "job_state_conflict", message: "Job \(job.id.uuidString) is \(job.status.rawValue), not running.")
        }
        return job
    }

    /// The 409 for a guarded transition that did not happen, naming the status the job has now.
    private func stateConflict(_ jobID: UUID, _ action: String) throws -> APIError {
        let status = try builds.job(id: jobID)?.status.rawValue ?? "gone"
        return APIError(code: "job_state_conflict", message: "Job \(jobID.uuidString) is \(status) and \(action).")
    }

    private func current(_ jobID: UUID) throws -> Job {
        guard let job = try builds.job(id: jobID) else {
            throw APIError(code: "job_not_found", message: "No job '\(jobID.uuidString)'.")
        }
        return job
    }

    /// Publishes the job and its build (status refreshed from its jobs); returns the job as stored.
    private func publishChange(of job: Job) throws -> Job {
        let updated = try current(job.id)
        let build = try builds.refreshBuildStatus(buildID: job.buildID)
        events.publish(.server(.job(updated)))
        events.publish(.server(.build(build)))
        return updated
    }
}

/// A job whose build, app or stored workflow is missing; answered with 500.
struct IncompleteJob: Error, CustomStringConvertible {
    let jobID: UUID
    var description: String { "job \(jobID.uuidString) has no build, app or workflow" }
}
