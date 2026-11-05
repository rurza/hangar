import Clocks
import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

private struct StaticSource: KnownNumberSource {
    var name = "app-store-connect"
    var number: Int? = 305
    func highestNumber(for app: App) async throws -> Int? { number }
}

private struct FailingSource: KnownNumberSource {
    struct Down: Error {}
    var name = "xcode-cloud"
    func highestNumber(for app: App) async throws -> Int? { throw Down() }
}

/// Scripted App Store Connect client that records the credentials it was built with.
private struct RecordingASC: AppStoreConnectClient {
    var credentials: ASCCredentials
    func builds(appID: String, version: String?) async throws -> [ASCBuild] {
        [ASCBuild(id: "b", version: "310", processingState: "VALID", platform: "IOS", uploadedDate: nil)]
    }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [12] }
    func apps() async throws -> [ASCApp] { [] }
    func appIconURL(appID: String) async throws -> String? { "https://is1-ssl.mzstatic.com/icon/\(appID)/512x512bb.png" }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func submitForBetaReview(buildID: String) async throws {}
}

/// A server on a temporary data directory and an in-memory database.
struct APIFixture {
    let directory: URL
    let host = FakeSourceHost()
    let server: HangarServerApp

    init(
        sources: [any KnownNumberSource]? = [StaticSource()], clock: any Clock<Duration> = ContinuousClock(),
        appStoreConnectFactory: @escaping @Sendable (ASCCredentials) -> any AppStoreConnectClient = {
            RecordingASC(credentials: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init, boundHost: String = "127.0.0.1", allowedHosts: [String] = [],
        iconTransport: any HTTPTransport = StubTransport(), workerBinaryPath: String? = nil, port: Int = 8787,
        githubTransport: any HTTPTransport = StubTransport()
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-api-\(UUID().uuidString)")
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        server = try HangarServerApp(
            configuration: ServerConfiguration(
                host: boundHost, port: port, dataDirectory: directory.path, allowedHosts: allowedHosts,
                workerBinaryPath: workerBinaryPath), database: database,
            appStoreConnectFactory: appStoreConnectFactory, sourceHost: host, clock: clock,
            numberSources: sources.map { sources in { @Sendable in sources } }, iconTransport: iconTransport, githubTransport: githubTransport,
            now: now)
    }

    func test(_ body: @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        try await server.build().test(.router, body)
    }

    @discardableResult
    func createApp(name: String = "Legilo") throws -> App {
        try server.apps.create(
            CreateAppRequest(name: name, repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42"))
    }

    /// Waits until an SSE handler has subscribed to the event bus.
    func waitForSubscriber() async throws {
        while server.events.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// What every client sends with a JSON body; the cross-site guard refuses a body without it.
let jsonHeaders: HTTPFields = [.contentType: "application/json"]

func body(_ value: some Encodable) throws -> ByteBuffer { ByteBuffer(bytes: try JSONCoding.encoder.encode(value)) }

func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
    try JSONCoding.decoder.decode(type, from: Data(response.body.readableBytesView))
}

/// `(event, data)` pairs of an SSE body; comment lines are skipped.
func frames(_ response: TestResponse) -> [(event: String, data: String)] {
    String(buffer: response.body).components(separatedBy: "\n\n").compactMap { block in
        var event: String?
        var data: String?
        for line in block.split(separator: "\n") {
            if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
            if line.hasPrefix("data: ") { data = String(line.dropFirst(6)) }
        }
        guard let event, let data else { return nil }
        return (event, data)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PublicAPITests {
    @Test func appsCRUD() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            let request = CreateAppRequest(
                name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42")
            let created = try await client.execute(uri: "/api/v1/apps", method: .post, headers: jsonHeaders, body: try body(request)) {
                #expect($0.status == .created)
                return try decode(App.self, $0)
            }
            #expect(created.slug == "legilo")
            try await client.execute(uri: "/api/v1/apps", method: .post, headers: jsonHeaders, body: try body(request)) { response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "app_exists")
            }
            try await client.execute(uri: "/api/v1/apps", method: .get) { response throws in
                #expect(try decode([App].self, response) == [created])
            }
            for key in ["legilo", created.id.uuidString] {
                try await client.execute(uri: "/api/v1/apps/\(key)", method: .get) { response throws in
                    #expect(try decode(App.self, response) == created)
                }
            }
            try await client.execute(uri: "/api/v1/apps/legilo", method: .delete) { response in #expect(response.status == .noContent) }
            try await client.execute(uri: "/api/v1/apps/legilo", method: .get) { response in #expect(response.status == .notFound) }
        }
    }

    @Test func createdAppWithoutIconGetsOneInTheBackground() async throws {
        let fixture = try APIFixture()
        for (name, value) in [("HANGAR_ASC_KEY_ID", "KEY"), ("HANGAR_ASC_KEY_PATH", "PEM")] {
            try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
        }
        try await fixture.test { client in
            let request = CreateAppRequest(
                name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42")
            let created = try await client.execute(uri: "/api/v1/apps", method: .post, headers: jsonHeaders, body: try body(request)) {
                #expect($0.status == .created)
                return try decode(App.self, $0)
            }
            #expect(created.iconURL == nil)  // the response does not wait for the icon
            await fixture.server.appIconBackfill.waitForIdle()
            try await client.execute(uri: "/api/v1/apps/\(created.id)", method: .get) { response throws in
                #expect(try decode(App.self, response).iconURL == "https://is1-ssl.mzstatic.com/icon/42/512x512bb.png")
            }
        }
    }

    @Test func iconURLMustBeHTTPS() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            for icon in ["http://example.com/icon.png", "javascript:alert(1)", "https://", "/icon.png"] {
                let request = CreateAppRequest(
                    name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42", iconURL: icon)
                try await client.execute(uri: "/api/v1/apps", method: .post, headers: jsonHeaders, body: try body(request)) { response throws in
                    #expect(response.status == .badRequest)
                    #expect(try decode(APIError.self, response).code == "invalid_input")
                }
            }
            try await client.execute(uri: "/api/v1/apps", method: .get) { response throws in
                #expect(try decode([App].self, response).isEmpty)
            }
        }
    }

    @Test func givenIconIsKeptAndListingBackfillsMissingOnes() async throws {
        let fixture = try APIFixture()
        for (name, value) in [("HANGAR_ASC_KEY_ID", "KEY"), ("HANGAR_ASC_KEY_PATH", "PEM")] {
            try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
        }
        let own = "https://example.com/own.png"
        _ = try fixture.server.apps.create(CreateAppRequest(
            name: "Atlas", repoURL: "https://github.com/acme/atlas.git", appStoreConnectAppID: "7", iconURL: own))
        try fixture.createApp()  // "42", no icon
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps", method: .get) { response in #expect(response.status == .ok) }
            await fixture.server.appIconBackfill.waitForIdle()
            try await client.execute(uri: "/api/v1/apps", method: .get) { response throws in
                #expect(try decode([App].self, response).map(\.iconURL) == [own, "https://is1-ssl.mzstatic.com/icon/42/512x512bb.png"])
            }
        }
    }

    @Test func unknownAppIs404WithCode() async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: "/api/v1/apps/nope", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "app_not_found")
            }
            try await client.execute(uri: "/api/v1/nope", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "not_found")
            }
            try await client.execute(uri: "/api/v1/apps/nope/numbers", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "app_not_found")
            }
        }
    }

    @Test func malformedBodyIs400() async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: "/api/v1/apps", method: .post, headers: jsonHeaders, body: ByteBuffer(string: "{nope")) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "invalid_request")
            }
        }
    }

    @Test func variablesNeverReturnValues() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        let secret = "s3cr3t-Value-9f8e7d"
        try await fixture.test { client in
            let input = VariableInput(value: secret, isSecret: true)
            for uri in ["/api/v1/apps/legilo/variables/API_TOKEN", "/api/v1/variables/GLOBAL_TOKEN"] {
                try await client.execute(uri: uri, method: .put, headers: jsonHeaders, body: try body(input)) { response throws in
                    #expect(response.status == .noContent)
                    #expect(response.body.readableBytes == 0)
                }
            }
            for uri in ["/api/v1/apps/legilo/variables", "/api/v1/variables"] {
                try await client.execute(uri: uri, method: .get) { response throws in
                    #expect(response.status == .ok)
                    let raw = String(buffer: response.body)
                    #expect(!raw.contains(secret))
                    #expect(!raw.contains("\"value\""))
                    #expect(try decode([VariableSummary].self, response).count == 1)
                }
            }
            try await client.execute(uri: "/api/v1/apps/legilo/variables/bad-name", method: .put, headers: jsonHeaders, body: try body(input)) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "invalid_variable_name")
                #expect(!String(buffer: response.body).contains(secret))
            }
            try await client.execute(uri: "/api/v1/apps/legilo/variables/API_TOKEN", method: .delete) { response throws in
                #expect(response.status == .noContent)
            }
            try await client.execute(uri: "/api/v1/apps/legilo/variables", method: .get) { response throws in
                #expect(try decode([VariableSummary].self, response).isEmpty)
            }
        }
    }

    @Test func deployReturns202WithJobs() async throws {
        let fixture = try APIFixture()
        let app = try fixture.createApp()
        try await fixture.test { client in
            let request = DeployRequest(app: "legilo", workflow: "testflight", ref: "main")
            let build = try await client.execute(uri: "/api/v1/builds", method: .post, headers: jsonHeaders, body: try body(request)) {
                #expect($0.status == .accepted)
                return try decode(Build.self, $0)
            }
            #expect(build.buildNumber == 306)
            #expect(build.jobs.map(\.action.scheme) == ["Legilo", "LegiloMobile"])
            try await client.execute(uri: "/api/v1/builds?app=\(app.id.uuidString)&limit=1000", method: .get) { response throws in
                #expect(try decode([Build].self, response) == [build])
            }
            try await client.execute(uri: "/api/v1/builds/\(build.id.uuidString)", method: .get) { response throws in
                #expect(try decode(Build.self, response) == build)
            }
            try await client.execute(uri: "/api/v1/jobs/\(build.jobs[0].id.uuidString)", method: .get) { response throws in
                #expect(try decode(Job.self, response) == build.jobs[0])
            }
            try await client.execute(uri: "/api/v1/builds/\(build.id.uuidString)/cancel", method: .post) { response throws in
                #expect(try decode(Build.self, response).status == .cancelled)
            }
            try await client.execute(uri: "/api/v1/builds/\(UUID().uuidString)", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "build_not_found")
            }
        }
    }

    @Test func deployErrorsMapToStatusCodes() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        fixture.host.state.withLock { $0.unknownRefs = ["ghost"] }
        try await fixture.test { client in
            let cases: [(DeployRequest, HTTPResponse.Status, String)] = [
                (DeployRequest(app: "legilo", workflow: "testflight", ref: "ghost"), .notFound, "ref_not_found"),
                (DeployRequest(app: "legilo", workflow: "nightly", ref: "main"), .notFound, "workflow_not_found"),
                (DeployRequest(app: "nope", workflow: "testflight", ref: "main"), .notFound, "app_not_found"),
            ]
            for (request, status, code) in cases {
                try await client.execute(uri: "/api/v1/builds", method: .post, headers: jsonHeaders, body: try body(request)) { response throws in
                    #expect(response.status == status)
                    #expect(try decode(APIError.self, response).code == code)
                }
            }
            fixture.host.state.withLock { $0.files = [:] }
            let request = DeployRequest(app: "legilo", workflow: "testflight", ref: "main")
            try await client.execute(uri: "/api/v1/builds", method: .post, headers: jsonHeaders, body: try body(request)) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "workflow_file_missing")
            }
        }
    }

    @Test func workflowsAtRef() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/workflows?ref=main", method: .get) { response throws in
                #expect(response.status == .ok)
                struct Payload: Decodable { var commit: String; var workflows: WorkflowFile; var source: WorkflowSource }
                let payload = try decode(Payload.self, response)
                #expect(payload.commit == "0123456789abcdef0123456789abcdef01234567")
                #expect(payload.workflows.workflows.keys.sorted() == ["beta", "ci", "testflight"])
                #expect(payload.source == .repository)
            }
        }
    }

    @Test func numbersEndpointSurfacesSourceErrors() async throws {
        let fixture = try APIFixture(sources: [StaticSource(), FailingSource()])
        try fixture.createApp()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/numbers", method: .get) { response throws in
                #expect(response.status == .badGateway)
                let error = try decode(APIError.self, response)
                #expect(error.code == "build_number_source_unavailable")
                #expect(error.message.contains("xcode-cloud"))
            }
        }
    }

    @Test func bumpBelowNextIs409() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/numbers/next", method: .put, headers: jsonHeaders, body: try body(BumpNumberRequest(next: 100))) { response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "bump_not_higher")
            }
            try await client.execute(uri: "/api/v1/apps/legilo/numbers/next", method: .put, headers: jsonHeaders, body: try body(BumpNumberRequest(next: 400))) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(NumbersReport.self, response).next == 400)
            }
        }
    }

    @Test func numbersUseAppStoreConnectGlobalsReadPerRequest() async throws {
        let seen = Mutex<[String]>([])
        let fixture = try APIFixture(sources: nil) { credentials in
            seen.withLock { $0.append(credentials.keyID + "/" + (credentials.issuerID ?? "-") + "/" + credentials.privateKeyPEM) }
            return RecordingASC(credentials: credentials)
        }
        try fixture.createApp()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/numbers", method: .get) { response throws in
                #expect(response.status == .badGateway)
                #expect(try decode(APIError.self, response).code == "app_store_connect_not_configured")
            }
            for (name, value) in [("HANGAR_ASC_KEY_ID", "KEY"), ("HANGAR_ASC_ISSUER_ID", "ISSUER"), ("HANGAR_ASC_KEY_PATH", "PEM")] {
                try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
            }
            try await client.execute(uri: "/api/v1/apps/legilo/numbers", method: .get) { response throws in
                #expect(response.status == .ok)
                let report = try decode(NumbersReport.self, response)
                #expect(report.next == 311)
                #expect(report.highestAppStoreConnect == 310)
                #expect(report.lastXcodeCloudRun == 12)
            }
        }
        #expect(seen.withLock { $0 } == ["KEY/ISSUER/PEM"])
    }

    @Test func numbersWorkWithIndividualKey() async throws {
        let issuers = Mutex<[String?]>([])
        let fixture = try APIFixture(sources: nil) { credentials in
            issuers.withLock { $0.append(credentials.issuerID) }
            return RecordingASC(credentials: credentials)
        }
        try fixture.createApp()
        for (name, value) in [("HANGAR_ASC_KEY_ID", "KEY"), ("HANGAR_ASC_KEY_PATH", "PEM")] {
            try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
        }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/numbers", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(NumbersReport.self, response).next == 311)
            }
        }
        #expect(issuers.withLock { $0 } == [nil])
    }

    @Test func machinesNeverListTokens() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            let created = try await client.execute(
                uri: "/api/v1/machines", method: .post, headers: jsonHeaders, body: try body(CreateMachineRequest(name: "studio"))
            ) {
                #expect($0.status == .created)
                return try decode(CreateMachineResponse.self, $0)
            }
            #expect(!created.token.isEmpty)
            try await client.execute(uri: "/api/v1/machines", method: .post, headers: jsonHeaders, body: try body(CreateMachineRequest(name: "studio"))) { response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "machine_exists")
            }
            try await client.execute(uri: "/api/v1/machines", method: .get) { response throws in
                #expect(!String(buffer: response.body).contains(created.token))
                #expect(try decode([Machine].self, response) == [created.machine])
            }
            try await client.execute(uri: "/api/v1/machines/studio", method: .delete) { response in #expect(response.status == .noContent) }
            try await client.execute(uri: "/api/v1/machines/studio", method: .delete) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "machine_not_found")
            }
        }
    }

    @Test func healthReportsVersion() async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: "/api/v1/health", method: .get) { response throws in
                struct Health: Decodable, Equatable { var ok: Bool; var version: String }
                #expect(try decode(Health.self, response) == Health(ok: true, version: HangarVersion.current))
            }
        }
    }
}
