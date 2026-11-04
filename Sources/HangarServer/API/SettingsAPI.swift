import Foundation
import HangarCore
import Hummingbird

extension HangarServerApp {
    func addSettingsRoutes(to api: APIGroup) {
        api.get("settings") { _, _ in
            // Only the key ID and issuer ID leave the server; the key contents and the token stay in the store.
            let credentials = try Self.appStoreConnectCredentials(variables: variables)
            return try Response.json(
                SettingsStatus(
                    version: HangarVersion.current,
                    appStoreConnect: credentials.map { ASCKeyStatus(keyID: $0.keyID, issuerID: $0.issuerID) },
                    githubTokenSet: try variables.value(global: "HANGAR_GITHUB_TOKEN") != nil))
        }
        api.get("asc/apps") { _, _ in
            guard let client = try appStoreConnectClient() else {
                throw APIError(code: "asc_not_configured", message: "Set the App Store Connect key in Settings first.")
            }
            let registered = Set(try apps.all().map(\.appStoreConnectAppID))
            let summaries = try await client.apps()
                .map { ASCAppSummary(id: $0.id, name: $0.name, bundleID: $0.bundleID, registered: registered.contains($0.id)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return try Response.json(summaries)
        }
    }
}
