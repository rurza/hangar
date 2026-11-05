import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird

/// The app's TestFlight groups in App Store Connect, for the workflow editor's group picker.
extension HangarServerApp {
    func addBetaGroupRoutes(to api: APIGroup) {
        api.get("apps/:id/beta-groups") { _, context in
            let app = try app(context)
            let client = try configuredAppStoreConnectClient()
            let groups = try await Self.relayingRefusal { try await client.betaGroups(appID: app.appStoreConnectAppID) }
            let sorted = groups.map { BetaGroup(id: $0.id, name: $0.name, isInternal: $0.isInternal) }
                .sorted { ($0.isInternal ? 0 : 1, $0.name.lowercased()) < ($1.isInternal ? 0 : 1, $1.name.lowercased()) }
            return try Response.json(sorted)
        }
        api.post("apps/:id/beta-groups") { request, context in
            let app = try app(context)
            let client = try configuredAppStoreConnectClient()
            let input = try await request.decode(as: CreateBetaGroupRequest.self, context: context)
            let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw APIError(code: "invalid_request", message: "Name the group.") }
            let group = try await Self.relayingRefusal {
                try await client.createBetaGroup(
                    appID: app.appStoreConnectAppID, name: name, internal: input.isInternal ?? true)
            }
            return try Response.json(BetaGroup(id: group.id, name: group.name, isInternal: group.isInternal), status: .created)
        }
    }

    private func configuredAppStoreConnectClient() throws -> any AppStoreConnectClient {
        guard let client = try appStoreConnectClient() else {
            throw APIError(code: "asc_not_configured", message: "Set the App Store Connect key in Settings first.")
        }
        return client
    }

    /// Runs `body`; App Store Connect refusing the request becomes `asc_refused` with its own words.
    private static func relayingRefusal<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ASCError {
            let detail = error.refusalDetail ?? appStoreConnectReason(error)
            throw APIError(code: "asc_refused", message: "App Store Connect: \(detail)")
        }
    }
}
