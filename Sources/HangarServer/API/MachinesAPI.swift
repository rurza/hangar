import Foundation
import HangarCore
import Hummingbird

/// A machine's token is returned once, by `POST /machines`; `Machine` itself never carries it.
extension HangarServerApp {
    func addMachineRoutes(to api: APIGroup) {
        api.get("machines") { _, _ in try Response.json(machines.all()) }
        api.post("machines") { request, context in
            let input = try await request.decode(as: CreateMachineRequest.self, context: context)
            guard !input.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw APIError(code: "invalid_name", message: "A machine needs a name.")
            }
            guard input.maxConcurrentJobs >= 1 else {
                throw APIError(code: "invalid_request", message: "maxConcurrentJobs must be at least 1.")
            }
            let (machine, token) = try machines.create(name: input.name, maxConcurrentJobs: input.maxConcurrentJobs)
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
    }
}
