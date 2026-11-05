import Foundation
import HangarCore
import Hummingbird

/// A machine's token is returned once, by `POST /machines` or `POST /enroll`; `Machine` itself never carries it.
extension HangarServerApp {
    func addMachineRoutes(to api: APIGroup) {
        api.get("machines") { _, _ in try Response.json(machines.all()) }
        api.post("machines") { request, context in
            let input = try await request.decode(as: CreateMachineRequest.self, context: context)
            let (machine, token) = try createMachine(name: input.name, maxConcurrentJobs: input.maxConcurrentJobs)
            return try Response.json(CreateMachineResponse(machine: machine, token: token), status: .created)
        }
        // A one-time code the new Mac's install script enrolls with; the web UI's Add Mac sheet shows it.
        api.post("machines/pairings") { _, _ in try Response.json(pairings.create(), status: .created) }
        // The install script's call (curl, no Origin): the code stands in for the UI. A refused name keeps the code.
        api.post("enroll") { request, context in
            let input = try await request.decode(as: EnrollRequest.self, context: context)
            let maxConcurrentJobs = input.maxConcurrentJobs ?? 1
            try validateMachine(name: input.name, maxConcurrentJobs: maxConcurrentJobs)
            let (machine, token) = try pairings.redeem(input.code, from: context.peer) {
                try createMachine(name: input.name, maxConcurrentJobs: maxConcurrentJobs)
            }
            events.publish(.server(.machine(machine)))
            return try Response.json(CreateMachineResponse(machine: machine, token: token), status: .created)
        }
        api.delete("machines/:id") { _, context in
            let key = try context.parameters.require("id")
            guard let machine = try machines.find(nameOrID: key) else {
                throw APIError(code: "machine_not_found", message: "No machine '\(key)'.")
            }
            try machines.delete(id: machine.id)
            return Response(status: .noContent)
        }
        // Pause: the scheduler gives the machine no new jobs; a running one finishes, and the worker keeps reporting.
        api.post("machines/:id/pause") { _, context in try setPaused(context, true) }
        api.post("machines/:id/resume") { _, context in try setPaused(context, false) }
    }

    private func setPaused(_ context: HangarRequestContext, _ paused: Bool) throws -> Response {
        let key = try context.parameters.require("id")
        guard let found = try machines.find(nameOrID: key), let machine = try machines.setPaused(id: found.id, paused)
        else { throw APIError(code: "machine_not_found", message: "No machine '\(key)'.") }
        events.publish(.server(.machine(machine)))
        // Resumed: queued jobs may go to it now rather than at the next tick; paused: queue notes say why they wait.
        scheduler.poke()
        return try Response.json(machine)
    }

    func validateMachine(name: String, maxConcurrentJobs: Int) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw APIError(code: "invalid_name", message: "A machine needs a name.")
        }
        guard maxConcurrentJobs >= 1 else {
            throw APIError(code: "invalid_request", message: "maxConcurrentJobs must be at least 1.")
        }
    }

    func createMachine(name: String, maxConcurrentJobs: Int) throws -> (Machine, token: String) {
        try validateMachine(name: name, maxConcurrentJobs: maxConcurrentJobs)
        return try machines.create(name: name, maxConcurrentJobs: maxConcurrentJobs)
    }
}
