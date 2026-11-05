import Foundation
import HangarCore
import Hummingbird

/// Settings › Signing: the server's one Apple Development identity. `GET` shows what it says about itself, never
/// the `.p12` or its password. Creating, importing and removing it take the owner (the web UI or the CLI): no API
/// token may (`APITokenPolicy` has no scope for them), so neither may an agent through `hangar mcp`.
extension HangarServerApp {
    func addSigningRoutes(to api: APIGroup) {
        api.get("signing") { _, _ in
            try Response.json(try signing.status())
        }
        // Create, or Renew within 30 days of expiry: the only route that asks App Store Connect for a certificate.
        api.post("signing/certificate") { _, _ in
            try Response.json(try await signing.create(), status: .created)
        }
        api.post("signing/import") { request, context in
            let input = try await request.decode(as: ImportSigningIdentityRequest.self, context: context)
            return try Response.json(try await signing.importIdentity(p12: input.p12, password: input.password), status: .created)
        }
        // Deletes the stored copy only; the certificate is not revoked.
        api.delete("signing") { _, _ in
            try Response.json(try await signing.remove())
        }
    }
}
