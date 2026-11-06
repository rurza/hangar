import Foundation
import HangarCore
import Hummingbird

extension HangarServerApp {
    func addSettingsRoutes(to api: APIGroup) {
        api.get("settings") { _, _ in
            // Only the key ID, the issuer ID (if any) and the key's kind leave the server; the key contents and the
            // token stay in the store.
            return try Response.json(
                SettingsStatus(
                    version: HangarVersion.current,
                    appStoreConnect: try ascKeys.status(.main),
                    githubTokenSet: try variables.value(global: "HANGAR_GITHUB_TOKEN") != nil,
                    workerInstallAvailable: InstallRoutes.workerBinary(at: configuration.workerBinaryPath) != nil,
                    github: try await githubStatus(), developmentKey: try ascKeys.status(.development)))
        }
        api.get("asc/apps") { _, _ in
            guard let client = try appStoreConnectClient() else {
                throw APIError(code: "asc_not_configured", message: "Set the App Store Connect key in Settings first.")
            }
            let registered = Set(try apps.all().map(\.appStoreConnectAppID))
            let ascApps = try await client.apps()
            let icons = await appIcons.iconURLs(ascAppIDs: ascApps.map(\.id), client: client)
            let summaries = ascApps
                .map {
                    ASCAppSummary(
                        id: $0.id, name: $0.name, bundleID: $0.bundleID, registered: registered.contains($0.id),
                        iconURL: icons[$0.id])
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return try Response.json(summaries)
        }
    }
}
