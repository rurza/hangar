import Foundation
import HangarCore
import Hummingbird

extension HangarServerApp {
    /// `POST /api/v1/worker/jobs/{id}/provisioning`: what a VM archive's guest signs with (`JobProvisioning`). Only the
    /// machine token of the VM Mac the archive is assigned to may ask, while the job is assigned or running; a job
    /// token never can. The answer holds development profiles and, only when a profile is missing, the optional
    /// development key: never the server's own App Store Connect key.
    func addProvisioningRoute(to worker: RouterGroup<HangarRequestContext>) {
        worker.post("jobs/:id/provisioning") { request, context in
            try context.requireMachineToken()
            let machine = try context.requireMachine()
            let job = try job(context)
            guard job.machineID == machine.id else {
                throw APIError(
                    code: "job_not_assigned_to_machine",
                    message: "Job \(job.id.uuidString) is not assigned to machine '\(machine.name)'.")
            }
            guard job.status == .assigned || job.status == .running else {
                throw APIError(
                    code: "job_state_conflict", message: "Job \(job.id.uuidString) is \(job.status.rawValue) and gets no profiles.")
            }
            guard job.action.kind == .archive, machine.report?.vm != nil else {
                throw APIError(code: "not_a_vm_archive", message: "Only a VM Mac's archive gets development profiles.")
            }
            let input = try await request.decode(as: JobProvisioningRequest.self, context: context)
            guard let build = try builds.build(id: job.buildID), let app = try apps.find(slugOrID: build.appID.uuidString)
            else { throw IncompleteJob(jobID: job.id) }
            let result = await profiles.provision(
                app: app, platform: job.action.platform, useServerIdentity: input.useServerIdentity)
            return try Response.json(result)
        }
    }
}
