import Clocks
import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

private let projectYML = """
    name: Legilo
    settings:
      base:
        DEVELOPMENT_TEAM: YL78V8PY6H
    targets:
      Legilo:
        type: application
        platform: macOS
        sources: [Legilo]
      LegiloMobile:
        type: application
        platform: iOS
        sources: [LegiloMobile]
    schemes:
      Legilo:
        build:
          targets:
            Legilo: all
      LegiloMobile:
        build:
          targets:
            LegiloMobile: all
    """

private let iconSet = """
    {"images": [
      {"filename": "icon_16x16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
      {"filename": "icon_512x512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512"}
    ]}
    """

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
private let iconPath = "Legilo/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"

private func legiloRepo(_ host: FakeSourceHost) {
    host.state.withLock { state in
        state.tree = RepositoryTree(paths: [
            "project.yml", "ci_scripts", "ci_scripts/ci_post_clone.sh", "Legilo", "Legilo/Assets.xcassets",
            "Legilo/Assets.xcassets/AppIcon.appiconset", "Legilo/Assets.xcassets/AppIcon.appiconset/Contents.json",
            "Legilo/Assets.xcassets/AppIcon.appiconset/icon_16x16.png", iconPath,
        ])
        state.files["project.yml"] = projectYML
        state.files["ci_scripts/ci_post_clone.sh"] = "#!/bin/sh\nxcodegen generate\n"
        state.files["Legilo/Assets.xcassets/AppIcon.appiconset/Contents.json"] = iconSet
        state.data[iconPath] = png
    }
}

@Suite(.timeLimit(.minutes(1))) struct WorkflowSuggestionAPITests {
    @Test func suggestsFromTheRepository() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        legiloRepo(fixture.host)
        try fixture.server.variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp-x", isSecret: true))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/workflow-suggestion", method: .get) { response throws in
                #expect(response.status == .ok)
                let suggestion = try decode(WorkflowSuggestion.self, response)
                #expect(suggestion.commit == "0123456789abcdef0123456789abcdef01234567")
                #expect(try WorkflowFileParser.parse(suggestion.yaml) == suggestion.workflows)
                let workflow = try #require(suggestion.workflows.workflows["release"])
                #expect(workflow.project == "Legilo.xcodeproj")
                #expect(workflow.actions.map(\.platform) == [.macOS, .iOS])
                #expect(suggestion.icon == DetectedIcon(path: iconPath, kind: .appiconset))
                #expect(!suggestion.notes.isEmpty)
            }
        }
        let state = fixture.host.state.withLock { $0 }
        // The default branch, with the app's token, and only a few requests.
        #expect(state.refs == ["HEAD"])
        #expect(state.tokens.allSatisfy { $0 == "ghp-x" })
        #expect(state.tokens.count <= 10)
    }

    @Test func usesTheGivenRef() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        legiloRepo(fixture.host)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/workflow-suggestion?ref=develop", method: .get) { #expect($0.status == .ok) }
        }
        #expect(fixture.host.state.withLock { $0.refs } == ["develop"])
    }

    @Test func noProjectIs422() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        fixture.host.state.withLock { $0.tree = RepositoryTree(paths: ["README.md", "Pods/Pods.xcodeproj"]) }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/workflow-suggestion", method: .get) { response throws in
                #expect(response.status == .unprocessableContent)
                #expect(try decode(APIError.self, response).code == "no_project_found")
            }
        }
    }

    @Test func slowRepositoryTimesOut() async throws {
        let fixture = try APIFixture(clock: ImmediateClock())
        try fixture.createApp()
        legiloRepo(fixture.host)
        fixture.host.state.withLock { $0.delay = .seconds(5) }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/workflow-suggestion", method: .get) { response throws in
                #expect(response.status == .gatewayTimeout)
                #expect(try decode(APIError.self, response).code == "detection_timeout")
            }
        }
    }

    @Test func unknownApp() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/nope/workflow-suggestion", method: .get) { #expect($0.status == .notFound) }
        }
    }

    @Test func repoIconServesTheImageAndCachesIt() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        legiloRepo(fixture.host)
        try await fixture.test { client in
            for _ in 0..<2 {
                try await client.execute(uri: "/api/v1/apps/legilo/repo-icon", method: .get) { response throws in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "image/png")
                    #expect(Data(response.body.readableBytesView) == png)
                }
            }
        }
        #expect(fixture.host.state.withLock { $0.reads.filter { $0 == iconPath }.count } == 1)
    }

    @Test func repoIconNotFoundForIconComposer() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        fixture.host.state.withLock { state in
            state.tree = RepositoryTree(paths: [
                "App.xcodeproj", "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme", "App/AppIcon.icon",
                "App/AppIcon.icon/icon.json", "App/AppIcon.icon/Assets/Layer.png",
            ])
        }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/repo-icon", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "icon_not_found")
            }
        }
    }

    @Test func repoIconRefusesWhatIsNotAnImage() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        legiloRepo(fixture.host)
        fixture.host.state.withLock { $0.data[iconPath] = Data("<html>".utf8) }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/repo-icon", method: .get) { #expect($0.status == .notFound) }
        }
    }

    // MARK: Inspecting a repository before adding it

    private struct BundleASC: AppStoreConnectClient {
        var apps: [ASCApp]
        func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
        func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
        func apps() async throws -> [ASCApp] { apps }
        func apps(bundleIDs: [String]) async throws -> [ASCApp] { apps.filter { bundleIDs.contains($0.bundleID) } }
        func appIconURL(appID: String) async throws -> String? { nil }
        func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
        func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
        func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
        func submitForBetaReview(buildID: String) async throws {}
    }

    private func inspectFixture(asc: [ASCApp]?) throws -> APIFixture {
        let fixture = try APIFixture(appStoreConnectFactory: { _ in BundleASC(apps: asc ?? []) })
        legiloRepo(fixture.host)
        fixture.host.state.withLock { state in
            state.files["project.yml"] = """
                name: Legilo
                targets:
                  Legilo:
                    type: application
                    platform: macOS
                    sources: [Legilo]
                    settings:
                      PRODUCT_BUNDLE_IDENTIFIER: software.micropixels.legilo
                  LegiloMobile:
                    type: application
                    platform: iOS
                    sources: [LegiloMobile]
                    settings:
                      PRODUCT_BUNDLE_IDENTIFIER: software.micropixels.legilo
                schemes:
                  Legilo:
                    build:
                      targets:
                        Legilo: all
                  LegiloMobile:
                    build:
                      targets:
                        LegiloMobile: all
                """
        }
        try fixture.server.variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp-global", isSecret: true))
        if asc != nil {
            for (name, value) in [("HANGAR_ASC_KEY_ID", "KEY"), ("HANGAR_ASC_ISSUER_ID", "issuer"), ("HANGAR_ASC_KEY_PATH", "pem")] {
                try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
            }
        }
        return fixture
    }

    @Test func inspectFindsTheAppAndItsAppStoreConnectApp() async throws {
        let fixture = try inspectFixture(asc: [ASCApp(id: "42", name: "Legilo Reader", bundleID: "software.micropixels.legilo")])
        try fixture.createApp()  // App Store Connect ID 42: already in Hangar
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/github/repos/rurza/Legilo/inspect", method: .get) { response throws in
                #expect(response.status == .ok)
                let inspection = try decode(RepositoryInspection.self, response)
                #expect(inspection.commit == "0123456789abcdef0123456789abcdef01234567")
                #expect(inspection.projects == ["Legilo.xcodeproj"])
                let app = try #require(inspection.apps.first)
                #expect(inspection.apps.count == 1)
                #expect(app.name == "Legilo Reader")
                #expect(app.bundleIDs == ["software.micropixels.legilo"])
                #expect(app.platforms == [.macOS, .iOS])
                #expect(app.appStoreConnect?.id == "42")
                #expect(app.appStoreConnect?.registered == true)
                #expect(app.icon == DetectedIcon(path: iconPath, kind: .appiconset))
            }
        }
        let state = fixture.host.state.withLock { $0 }
        #expect(state.repoURLs == ["https://github.com/rurza/Legilo"])
        #expect(state.refs == ["HEAD"])
        #expect(state.tokens.allSatisfy { $0 == "ghp-global" })
    }

    @Test func inspectWithoutAppStoreConnect() async throws {
        let fixture = try inspectFixture(asc: nil)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/github/repos/rurza/Legilo/inspect?ref=main", method: .get) { response throws in
                #expect(response.status == .ok)
                let inspection = try decode(RepositoryInspection.self, response)
                #expect(inspection.apps.map(\.name) == ["Legilo"])
                #expect(inspection.apps.first?.appStoreConnect == nil)
            }
        }
        #expect(fixture.host.state.withLock { $0.refs } == ["main"])
    }

    @Test func inspectOfAMissingRepository() async throws {
        let fixture = try inspectFixture(asc: nil)
        fixture.host.state.withLock { $0.unknownRefs = ["HEAD"] }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/github/repos/rurza/Nope/inspect", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "repository_not_found")
            }
            try await client.execute(uri: "/api/v1/github/repos/rurza/Nope/inspect?ref=HEAD", method: .get) { response throws in
                #expect(try decode(APIError.self, response).code == "ref_not_found")
            }
        }
    }

    @Test func inspectRefusesBadNames() async throws {
        let fixture = try inspectFixture(asc: nil)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/github/repos/rurza/..%2Fx/inspect", method: .get) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "unsupported_repository")
            }
        }
    }

    @Test func repositoryIconServesAnAppIconSetImage() async throws {
        let fixture = try inspectFixture(asc: nil)
        let query = "path=\(iconPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&commit=0123456789abcdef0123456789abcdef01234567"
        try await fixture.test { client in
            for _ in 0..<2 {
                try await client.execute(uri: "/api/v1/github/repos/rurza/Legilo/icon?\(query)", method: .get) { response throws in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "image/png")
                    #expect(Data(response.body.readableBytesView) == png)
                }
            }
            // Only images inside an .appiconset are served.
            try await client.execute(uri: "/api/v1/github/repos/rurza/Legilo/icon?path=project.yml&commit=abc", method: .get) { response throws in
                #expect(response.status == .badRequest)
            }
        }
        #expect(fixture.host.state.withLock { $0.reads.filter { $0 == iconPath }.count } == 1)
    }
}
