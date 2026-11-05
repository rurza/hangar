import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

private struct AppsASC: AppStoreConnectClient {
    var apps: [ASCApp]
    var icons: [String: String] = [:]
    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { apps }
    func appIconURL(appID: String) async throws -> String? { icons[appID] }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "new", name: name, isInternal: isInternal)
    }
    func submitForBetaReview(buildID: String) async throws {}
}

/// Answers the iTunes lookup by the `id` query item: the artwork for known IDs, no results otherwise.
private struct LookupTransport: HTTPTransport {
    var artwork: [String: String]
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        let body = artwork[id].map { #"{"resultCount":1,"results":[{"artworkUrl512":"\#($0)"}]}"# }
            ?? #"{"resultCount":0,"results":[]}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
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
                #expect(status.appStoreConnect?.kind == .team)
                #expect(raw.contains(#""kind":"team""#))
                #expect(status.githubTokenSet)
            }
        }
    }

    @Test func individualKeyIsConfigured() async throws {
        let fixture = try APIFixture()
        for (name, value) in [("HANGAR_ASC_KEY_ID", "INDIVIDUAL1"), ("HANGAR_ASC_KEY_PATH", privateKey)] {
            try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
        }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                let raw = String(buffer: response.body)
                #expect(raw.contains(#""kind":"individual""#))
                #expect(!raw.contains("PRIVATE KEY"))
                let status = try #require(try decode(SettingsStatus.self, response).appStoreConnect)
                #expect(status.keyID == "INDIVIDUAL1")
                #expect(status.issuerID == nil)
                #expect(status.kind == .individual)
            }
        }
    }

    @Test func settingsNeedsKeyIDAndKey() async throws {
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

    @Test func ascAppsCarryIcons() async throws {
        let apps = [
            ASCApp(id: "42", name: "Legilo", bundleID: "com.acme.legilo"),
            ASCApp(id: "7", name: "Atlas", bundleID: "com.acme.atlas"),
            ASCApp(id: "9", name: "Zeta", bundleID: "com.acme.zeta"),
        ]
        let icon = "https://is1-ssl.mzstatic.com/icon/42/512x512bb.png"
        let artwork = "https://is1-ssl.mzstatic.com/artwork/9/512x512bb.jpg"
        // "7": no build icon, two empty lookups; "9": the iTunes artwork. Lookups run concurrently, so answer by URL.
        let transport = LookupTransport(artwork: ["9": artwork])
        let fixture = try APIFixture(
            appStoreConnectFactory: { _ in AppsASC(apps: apps, icons: ["42": icon]) }, iconTransport: transport)
        try configureASC(fixture)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/asc/apps", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode([ASCAppSummary].self, response).map(\.iconURL) == [nil, icon, artwork])
            }
        }
    }

    @Test func ascAppsWorkWithIndividualKey() async throws {
        let issuers = Mutex<[String?]>([])
        let fixture = try APIFixture(appStoreConnectFactory: { credentials in
            issuers.withLock { $0.append(credentials.issuerID) }
            return AppsASC(apps: [ASCApp(id: "7", name: "Atlas", bundleID: "com.acme.atlas")])
        })
        for (name, value) in [("HANGAR_ASC_KEY_ID", "INDIVIDUAL1"), ("HANGAR_ASC_ISSUER_ID", ""), ("HANGAR_ASC_KEY_PATH", privateKey)] {
            try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
        }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/asc/apps", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode([ASCAppSummary].self, response).map(\.id) == ["7"])
            }
        }
        #expect(issuers.withLock { $0 } == [nil])
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
