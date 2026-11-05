import Foundation
import HangarCore
import Hummingbird

/// Creating, listing and revoking API tokens. A request made with an API token may only ask which token it is:
/// a token can never mint, list or revoke tokens (`APITokenPolicy`).
extension HangarServerApp {
    func addAPITokenRoutes(to api: APIGroup) {
        api.get("api-tokens") { _, _ in try Response.json(apiTokens.all()) }
        api.get("api-tokens/current") { _, context in
            guard let token = context.apiToken else {
                throw APIError(code: "not_found", message: "This request carries no API token.")
            }
            return try Response.json(token)
        }
        api.post("api-tokens") { request, context in
            let input = try await request.decode(as: CreateAPITokenRequest.self, context: context)
            let (token, secret) = try apiTokens.create(name: input.name, scope: input.scope, now: now())
            return try Response.json(CreateAPITokenResponse(token: token, secret: secret), status: .created)
        }
        api.delete("api-tokens/:id") { _, context in
            let key = try context.parameters.require("id")
            guard let token = try apiTokens.find(nameOrID: key) else {
                throw APIError(code: "token_not_found", message: "No API token '\(key)'.")
            }
            try apiTokens.delete(id: token.id)
            return Response(status: .noContent)
        }
    }
}
