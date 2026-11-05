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

        // `hangar-worker check`: is this token still a machine's? Never returns the token.
        worker.get("me") { _, context in try Response.json(try context.requireMachine()) }

        worker.post("heartbeat") { request, context in
            let machine = try context.requireMachine()
            let input = try await request.decode(as: HeartbeatRequest.self, context: context)
            let now = now()
            try machines.updateReport(id: machine.id, report: input.report, seenAt: now)
            if let updated = try machines.find(nameOrID: machine.id.uuidString) {
                events.publish(.server(.machine(updated)))
            }
            let onMachine = try builds.jobs(status: [.assigned, .running]).filter { $0.machineID == machine.id }
            try failUntrackedJobs(onMachine, machine: machine, reported: Set(input.report.runningJobIDs), now: now)
            // The worker's own list covers a job it still runs after the server stopped counting it as the machine's:
            // one that ended on the server (e.g. failed as lost) or went to another machine is to stop as well.
            var cancel = Set(cancelRequests.pending(for: Array(Set(onMachine.map(\.id) + input.report.runningJobIDs))))
            for id in Set(input.report.runningJobIDs) where !onMachine.contains(where: { $0.id == id }) {
                let job = try builds.job(id: id)
                if job == nil || job?.status.isTerminal == true || job?.machineID != machine.id { cancel.insert(id) }
            }
            scheduler.poke()
            return try Response.json(HeartbeatResponse(
                cancelJobIDs: cancel.sorted { $0.uuidString < $1.uuidString },
                workerUpdate: workerUpdate(reportedSHA256: input.report.binarySHA256)))
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
            // Machine-guarded: a job reassigned since `workerJob` looked it up is not started by this machine.
            guard
                try builds.transitionJob(
                    id: job.id, from: [.assigned], to: .running, at: now(), machineID: try context.requireMachine().id)
            else {
                throw try stateConflict(job.id, "cannot start")
            }
            // By name, so the job still says where it ran after the machine is removed or re-enrolled.
            try builds.mergeRunInfo(jobID: job.id, JobRunInfo(machineName: try context.requireMachine().name))
            return try Response.json(publishChange(of: job))
        }

        // The worker build and the Xcode the job runs with, for the job's header. The machine name is the server's.
        worker.post("jobs/:id/info") { request, context in
            let job = try running(workerJob(context))
            var info = try await request.decode(as: JobRunInfo.self, context: context)
            info.machineName = nil
            try builds.mergeRunInfo(jobID: job.id, info)
            let updated = try current(job.id)
            events.publish(.server(.job(updated)))
            return try Response.json(updated)
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
                    failureReason: result.failureReason, machineID: try context.requireMachine().id)
            else { throw try stateConflict(job.id, "cannot finish") }
            try builds.setOutputs(jobID: job.id, result.outputs)
            cancelRequests.clear(job.id)
            let finished = try publishChange(of: job)
            scheduler.poke()
            return try Response.json(finished)
        }
    }

    /// A replacement for the worker when it reported its own binary and that is not the one this server hands out.
    /// A worker that reports no hash cannot apply an update, so it is not offered one.
    private func workerUpdate(reportedSHA256: String?) -> WorkerUpdate? {
        guard let reportedSHA256, !reportedSHA256.isEmpty,
            let current = WorkerBinaryDigest.current(at: configuration.workerBinaryPath),
            current != reportedSHA256.lowercased()
        else { return nil }
        return WorkerUpdate(sha256: current)
    }

    /// Fails the machine's running jobs its heartbeat no longer lists once they have run longer than the grace: the
    /// worker restarted mid-job, or the job's finish never arrived. Without this they would stay running, and keep
    /// the machine's slot and the app's in-flight build, for as long as the machine keeps reporting.
    private func failUntrackedJobs(_ jobs: [Job], machine: Machine, reported: Set<UUID>, now: Date) throws {
        for job in jobs where job.status == .running && !reported.contains(job.id) {
            let reason = Self.lostJobReason(job, machineName: machine.name, at: now)
            guard let startedAt = job.startedAt, now.timeIntervalSince(startedAt) > configuration.untrackedJobGrace,
                try builds.transitionJob(
                    id: job.id, from: [.running], to: .failed, at: now, failureReason: reason, machineID: machine.id)
            else { continue }
            // The step it was in ends there, instead of running on forever on the build page.
            if let step = job.steps.last(where: { $0.status == .running }) {
                try builds.upsertStep(jobID: job.id, StepUpdate(
                    name: step.name, status: .failed, at: now, detail: "The worker on \(machine.name) lost this job"))
            }
            cancelRequests.clear(job.id)
            _ = try publishChange(of: job)
        }
    }

    /// Why a running job the machine's heartbeat no longer lists failed: which Mac, when, and what was running.
    /// "The worker on rurzomac-mini no longer had this job at 11:09:52, 4 min into archive: it restarted or was
    /// stopped. Rebuild to run it again."
    static func lostJobReason(_ job: Job, machineName: String, at now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        var text = "The worker on \(machineName) no longer had this job at \(formatter.string(from: now))"
        if let step = job.steps.last(where: { $0.status == .running }) {
            text += step.startedAt.map { ", \(Self.elapsed(now.timeIntervalSince($0))) into \(step.name)" } ?? ", during \(step.name)"
        } else if let startedAt = job.startedAt {
            text += ", \(Self.elapsed(now.timeIntervalSince(startedAt))) after it started"
        }
        return text + ": it restarted or was stopped. Rebuild to run it again."
    }

    /// "35 s", "4 min", "1 h 5 min".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
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
            job: job, app: app, workflow: workflow.forJob(running: job.action), workflowName: build.workflow, buildNumber: build.buildNumber, commit: build.commit, ref: build.ref,
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
