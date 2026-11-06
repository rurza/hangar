import Foundation
import HangarCore
import Hummingbird

/// Who counts as the owner. Owner only (`APITokenPolicy` has no scope for `access`).
extension HangarServerApp {
    func addAccessRoutes(to api: APIGroup) {
        api.get("access") { _, context in try Response.json(await accessStatus(context)) }
        api.put("access") { request, context in
            let input = try await request.decode(as: AccessUpdate.self, context: context)
            let logins = try OwnerAccess.validate(input.allowedLogins)
            // A change made from a tailnet device must keep that device in, or the owner would lock themselves out
            // of the browser; an owner token (the server Mac) may set anything.
            if let login = context.ownerLogin, !logins.isEmpty,
                !logins.contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame })
            {
                throw APIError(
                    code: "access_lockout",
                    message: "Keep your own login (\(login)) in the list, or you lose access from this device.")
            }
            if let login = context.ownerLogin, logins.isEmpty,
                !(await owners.defaultLogins()).contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame })
            {
                throw APIError(
                    code: "access_lockout",
                    message: "The default owner is the server node's login, which is not yours (\(login)); keep a list instead.")
            }
            try owners.setConfiguredLogins(logins)
            context.logger.info("owner logins set to \(logins.isEmpty ? "the server node's login" : logins.joined(separator: ", "))")
            return try Response.json(await accessStatus(context))
        }
    }

    func accessStatus(_ context: HangarRequestContext) async throws -> AccessStatus {
        let node = await owners.serverNode()
        let configured = owners.configuredLogins()
        let defaults = await owners.defaultLogins()
        return AccessStatus(
            viewerLogin: context.ownerLogin, viewerToken: context.apiToken?.name,
            allowedLogins: configured ?? defaults, configured: configured != nil,
            serverNodeLogin: node?.tagged == true ? nil : node?.loginName, serverNodeTagged: node?.tagged ?? false)
    }
}
