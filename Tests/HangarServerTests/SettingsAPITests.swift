import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

private struct AppsASC: AppStoreConnectClient {
    var apps: [ASCApp]
    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { apps }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func submitForBetaReview(buildID: String) async throws {}
}

private let privateKey = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49\n-----END PRIVATE KEY-----\n"
private let gitHubToken = "ghp_supersecrettokenvalue"

@Suite(.timeLimit(.minutes(1))) struct SettingsAPITests {
    private func configureASC(_ fixture: APIFixture) throws {
        for (name, value) in [
            ("HANGAR_ASC_KEY_ID", "KEY123"), ("HANGAR_ASC_ISSUER_ID", "issuer-uuid"), ("HANGAR_ASC_KEY_PATH", privateKey),
        ] {
            try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
        }
    }

    @Test func settingsReportsNothingConfigured() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                #expect(response.status == .ok)
                let status = try decode(SettingsStatus.self, response)
                #expect(status == SettingsStatus(version: HangarVersion.current, appStoreConnect: nil, githubTokenSet: false))
            }
        }
    }

    @Test func settingsShowsKeyIDsButNeverTheKey() async throws {
        let fixture = try APIFixture()
        try configureASC(fixture)
        try fixture.server.variables.set(
            scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: gitHubToken, isSecret: true))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                let raw = String(buffer: response.body)
                #expect(raw.contains("KEY123") && raw.contains("issuer-uuid"))
                #expect(!raw.contains("PRIVATE KEY"))
                #expect(!raw.contains(gitHubToken))
                let status = try decode(SettingsStatus.self, response)
                #expect(status.appStoreConnect == ASCKeyStatus(keyID: "KEY123", issuerID: "issuer-uuid"))
                #expect(status.githubTokenSet)
            }
        }
    }

    @Test func settingsNeedsAllThreeASCVariables() async throws {
        let fixture = try APIFixture()
        try fixture.server.variables.set(
            scope: .global, name: "HANGAR_ASC_KEY_ID", input: VariableInput(value: "KEY123", isSecret: false))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                #expect(try decode(SettingsStatus.self, response).appStoreConnect == nil)
            }
        }
    }

    @Test func ascAppsMarksRegistered() async throws {
        let apps = [
            ASCApp(id: "42", name: "legilo", bundleID: "com.acme.legilo"),
            ASCApp(id: "7", name: "Atlas", bundleID: "com.acme.atlas"),
        ]
        let fixture = try APIFixture(appStoreConnectFactory: { _ in AppsASC(apps: apps) })
        try configureASC(fixture)
        try fixture.createApp()  // appStoreConnectAppID "42"
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/asc/apps", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode([ASCAppSummary].self, response) == [
                    ASCAppSummary(id: "7", name: "Atlas", bundleID: "com.acme.atlas", registered: false),
                    ASCAppSummary(id: "42", name: "legilo", bundleID: "com.acme.legilo", registered: true),
                ])
            }
        }
    }

    @Test func ascAppsWithoutKeyIs409() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/asc/apps", method: .get) { response throws in
                #expect(response.status == .conflict)
                let error = try decode(APIError.self, response)
                #expect(error.code == "asc_not_configured")
                #expect(error.message == "Set the App Store Connect key in Settings first.")
            }
        }
    }
}
