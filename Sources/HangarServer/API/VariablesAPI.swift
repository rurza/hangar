import Foundation
import HangarCore
import Hummingbird

/// Variables are write-only: listing returns `VariableSummary`, which has no value. An app variable is named by its
/// name and the workflows it is limited to: the `workflow` query parameter, once per workflow (none: the one for
/// all workflows). Groups are named by id or name.
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
        api.patch("apps/:id/variables/:name") { request, context in
            let app = try app(context)
            let update = try await request.decode(as: VariableUpdate.self, context: context)
            try variables.update(
                appID: app.id, name: context.parameters.require("name"), workflows: request.query.all("workflow"),
                with: update)
            return Response(status: .noContent)
        }
        api.delete("apps/:id/variables/:name") { request, context in
            try variables.delete(
                scope: .app(app(context).id), name: context.parameters.require("name"), workflows: request.query.all("workflow"))
            return Response(status: .noContent)
        }
        api.get("apps/:id/environment") { request, context in
            let workflow = request.query.get("workflow").flatMap { $0.isEmpty ? nil : $0 }
            return try Response.json(variables.effective(appID: app(context).id, workflow: workflow))
        }

        api.get("variable-groups") { _, _ in try Response.json(variables.groups()) }
        api.post("variable-groups") { request, context in
            let input = try await request.decode(as: VariableGroupRequest.self, context: context)
            return try Response.json(variables.createGroup(name: input.name), status: .created)
        }
        api.get("variable-groups/:group") { _, context in
            try Response.json(variables.requireGroup(groupKey(context)))
        }
        api.patch("variable-groups/:group") { request, context in
            let input = try await request.decode(as: VariableGroupRequest.self, context: context)
            return try Response.json(variables.renameGroup(groupKey(context), to: input.name))
        }
        api.delete("variable-groups/:group") { _, context in
            try variables.deleteGroup(groupKey(context))
            return Response(status: .noContent)
        }
        api.get("variable-groups/:group/variables") { _, context in
            try Response.json(variables.requireGroup(groupKey(context)).variables)
        }
        api.put("variable-groups/:group/variables/:name") { request, context in
            let group = try variables.requireGroup(groupKey(context))
            return try await setVariable(scope: .group(group.id), request: request, context: context)
        }
        api.delete("variable-groups/:group/variables/:name") { _, context in
            let group = try variables.requireGroup(groupKey(context))
            try variables.delete(scope: .group(group.id), name: context.parameters.require("name"))
            return Response(status: .noContent)
        }

        api.get("apps/:id/variable-groups") { _, context in try Response.json(variables.links(appID: app(context).id)) }
        api.put("apps/:id/variable-groups/:group") { request, context in
            let app = try app(context)
            let input = try await request.decode(as: LinkVariableGroupRequest.self, context: context)
            try variables.link(appID: app.id, group: groupKey(context), workflows: input.workflows)
            return Response(status: .noContent)
        }
        api.delete("apps/:id/variable-groups/:group") { _, context in
            try variables.unlink(appID: app(context).id, group: groupKey(context))
            return Response(status: .noContent)
        }

        // Global secrets are opt-in per app; plain globals reach every app. No values, and no API token may change
        // which app gets a secret.
        api.get("apps/:id/global-secrets") { _, context in
            let app = try app(context)
            return try Response.json(
                AppGlobalSecrets(secrets: try variables.globalSecrets(appID: app.id), gitHubToken: try gitHubTokenSource(app)))
        }
        api.put("apps/:id/global-secrets/:name") { _, context in
            try variables.grantGlobalSecret(appID: app(context).id, name: context.parameters.require("name"))
            return Response(status: .noContent)
        }
        api.delete("apps/:id/global-secrets/:name") { _, context in
            try variables.revokeGlobalSecret(appID: app(context).id, name: context.parameters.require("name"))
            return Response(status: .noContent)
        }
    }

    /// Where the app's jobs get `HANGAR_GITHUB_TOKEN`: its own variable wins over the one in Settings.
    func gitHubTokenSource(_ app: App) throws -> GitHubTokenSource {
        if try variables.summaries(scope: .app(app.id)).contains(where: { $0.name == BuildService.tokenVariable }) { return .app }
        return try variables.value(global: BuildService.tokenVariable).map { $0.isEmpty ? .none : .global } ?? .none
    }

    /// The `{group}` segment, percent-decoded: a group's name may hold spaces, which Hummingbird leaves encoded.
    private func groupKey(_ context: HangarRequestContext) throws -> String {
        let raw = try context.parameters.require("group")
        return raw.removingPercentEncoding ?? raw
    }

    private func setVariable(scope: VariableScope, request: Request, context: HangarRequestContext) async throws -> Response {
        let name = try context.parameters.require("name")
        let input = try await request.decode(as: VariableInput.self, context: context)
        try variables.set(scope: scope, name: name, input: input)
        return Response(status: .noContent)
    }
}
