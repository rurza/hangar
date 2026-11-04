import Foundation
import HangarCore
import Hummingbird

/// Variables are write-only: listing returns `VariableSummary`, which has no value.
extension HangarServerApp {
    func addVariableRoutes(to api: APIGroup) {
        api.get("variables") { _, _ in try Response.json(variables.summaries(scope: .global)) }
        api.put("variables/:name") { request, context in
            try await setVariable(scope: .global, request: request, context: context)
        }
        api.delete("variables/:name") { _, context in
            try variables.delete(scope: .global, name: context.parameters.require("name"))
            return Response(status: .noContent)
        }
        api.get("apps/:id/variables") { _, context in try Response.json(variables.summaries(scope: .app(app(context).id))) }
        api.put("apps/:id/variables/:name") { request, context in
            try await setVariable(scope: .app(app(context).id), request: request, context: context)
        }
        api.delete("apps/:id/variables/:name") { _, context in
            try variables.delete(scope: .app(app(context).id), name: context.parameters.require("name"))
            return Response(status: .noContent)
        }
    }

    private func setVariable(scope: VariableScope, request: Request, context: HangarRequestContext) async throws -> Response {
        let name = try context.parameters.require("name")
        let input = try await request.decode(as: VariableInput.self, context: context)
        try variables.set(scope: scope, name: name, input: input)
        return Response(status: .noContent)
    }
}
