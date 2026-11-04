import CryptoKit
import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarAppStoreConnect

struct LiveClientDecodingTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func respond(_ name: String, status: Int = 200) throws -> StubTransport.Response {
        StubTransport.Response(status: status, body: try Self.fixture(name))
    }

    private func makeClient(_ transport: StubTransport, now: @escaping @Sendable () -> Date = Date.init) -> LiveAppStoreConnectClient {
        let credentials = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
        return LiveAppStoreConnectClient(credentials: credentials, transport: transport, now: now)
    }

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func buildsFollowsNextLinkAndReadsPlatform() async throws {
        let transport = StubTransport(responses: [try respond("builds-page1"), try respond("builds-page2")])
        let builds = try await makeClient(transport).builds(appID: "app1", version: "1.0")

        #expect(builds.map(\.id) == ["b1", "b2", "b3"])
        #expect(builds.map(\.version) == ["250", "251", "1.2.3"])
        #expect(builds.map(\.platform) == ["IOS", "MAC_OS", "IOS"])
        #expect(builds.map(\.processingState) == ["VALID", "PROCESSING", "INVALID"])
        #expect(builds[0].uploadedDate == Date(timeIntervalSince1970: 1_790_874_000.123))
        #expect(builds[2].uploadedDate == nil)

        let requests = transport.requests
        let first = try #require(requests[0].url)
        let items = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(first.path == "/v1/builds")
        #expect(items.contains(URLQueryItem(name: "filter[app]", value: "app1")))
        #expect(items.contains(URLQueryItem(name: "filter[version]", value: "1.0")))
        #expect(items.contains(URLQueryItem(name: "include", value: "preReleaseVersion")))
        #expect(items.contains(URLQueryItem(name: "limit", value: "200")))
        #expect(requests[1].url?.absoluteString == "https://api.appstoreconnect.apple.com/v1/builds?cursor=AQ&limit=200")
    }

    @Test func appsDecodesAcrossPages() async throws {
        let transport = StubTransport(responses: [try respond("apps-page1"), try respond("apps-page2")])
        let apps = try await makeClient(transport).apps()

        #expect(apps == [
            ASCApp(id: "a2", name: "Zeta", bundleID: "com.acme.zeta"),
            ASCApp(id: "a1", name: "Alpha", bundleID: "com.acme.alpha"),
            ASCApp(id: "a3", name: "Mid", bundleID: "com.acme.mid"),
        ])
        let requests = transport.requests
        let first = try #require(requests[0].url)
        let items = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(first.path == "/v1/apps")
        #expect(items.contains(URLQueryItem(name: "limit", value: "200")))
        #expect(items.contains(URLQueryItem(name: "fields[apps]", value: "name,bundleId")))
        #expect(requests[1].url?.absoluteString == "https://api.appstoreconnect.apple.com/v1/apps?cursor=AQ&limit=200")
    }

    @Test func buildsOmitsVersionFilterWhenNil() async throws {
        let transport = StubTransport(responses: [try respond("builds-page2")])
        _ = try await makeClient(transport).builds(appID: "app1", version: nil)
        let url = try #require(transport.requests.first?.url)
        #expect(!url.absoluteString.contains("filter%5Bversion%5D") && !url.absoluteString.contains("filter[version]"))
    }

    @Test func xcodeCloudRunNumbersAcrossProducts() async throws {
        let transport = StubTransport(responses: [
            try respond("ci-products"), try respond("ci-build-runs-prod1-page1"),
            try respond("ci-build-runs-prod1-page2"), try respond("ci-build-runs-prod2"),
        ])
        let numbers = try await makeClient(transport).xcodeCloudRunNumbers(appID: "app1")
        #expect(numbers == [250, 251, 252])
        let requests = transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "GET"])
        #expect(requests[1].url?.path == "/v1/ciProducts/prod1/buildRuns")
        #expect(requests[3].url?.path == "/v1/ciProducts/prod2/buildRuns")
    }

    @Test func betaGroupsDecodes() async throws {
        let transport = StubTransport(responses: [try respond("beta-groups")])
        let groups = try await makeClient(transport).betaGroups(appID: "app1")
        #expect(groups == [ASCBetaGroup(id: "g1", name: "Team", isInternal: true), ASCBetaGroup(id: "g2", name: "Public", isInternal: false)])
    }

    @Test func addBuildPostsRelationship() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(status: 204)])
        try await makeClient(transport).addBuild("b1", toBetaGroup: "g1")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/betaGroups/g1/relationships/builds")
        let data = try #require(try bodyJSON(request)["data"] as? [[String: String]])
        #expect(data == [["type": "builds", "id": "b1"]])
    }

    @Test func setsAuthorizationHeader() async throws {
        let transport = StubTransport(responses: [try respond("beta-groups")])
        _ = try await makeClient(transport).betaGroups(appID: "app1")
        let header = try #require(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
        #expect(header.hasPrefix("Bearer "))
        #expect(header.dropFirst(7).split(separator: ".").count == 3)
    }

    @Test func httpErrorCarriesStatusAndBody() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(status: 409, body: "{\"errors\":[{\"code\":\"CONFLICT\"}]}")])
        await #expect(throws: ASCError.http(status: 409, body: "{\"errors\":[{\"code\":\"CONFLICT\"}]}")) {
            try await makeClient(transport).addBuild("b1", toBetaGroup: "g1")
        }
    }

    @Test func setWhatToTestPatchesExistingLocalization() async throws {
        let transport = StubTransport(responses: [try respond("beta-localizations-existing"), StubTransport.Response(status: 200, body: "{}")])
        try await makeClient(transport).setWhatToTest(buildID: "b1", locale: "en-US", text: "Try the new thing")
        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/v1/builds/b1/betaBuildLocalizations")
        #expect(requests[1].httpMethod == "PATCH")
        #expect(requests[1].url?.path == "/v1/betaBuildLocalizations/loc-en")
        let data = try #require(try bodyJSON(requests[1])["data"] as? [String: Any])
        #expect(data["type"] as? String == "betaBuildLocalizations")
        #expect(data["id"] as? String == "loc-en")
        #expect((data["attributes"] as? [String: String]) == ["whatsNew": "Try the new thing"])
    }

    @Test func setWhatToTestCreatesMissingLocalization() async throws {
        let transport = StubTransport(responses: [try respond("beta-localizations-empty"), StubTransport.Response(status: 201, body: "{}")])
        try await makeClient(transport).setWhatToTest(buildID: "b1", locale: "en-US", text: "Hi")
        let post = try #require(transport.requests.last)
        #expect(post.httpMethod == "POST")
        #expect(post.url?.path == "/v1/betaBuildLocalizations")
        let data = try #require(try bodyJSON(post)["data"] as? [String: Any])
        #expect((data["attributes"] as? [String: String]) == ["locale": "en-US", "whatsNew": "Hi"])
        let build = (((data["relationships"] as? [String: Any])?["build"] as? [String: Any])?["data"]) as? [String: String]
        #expect(build == ["type": "builds", "id": "b1"])
    }

    @Test func submitForBetaReviewPostsSubmission() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(status: 201, body: "{}")])
        try await makeClient(transport).submitForBetaReview(buildID: "b1")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/betaAppReviewSubmissions")
        let data = try #require(try bodyJSON(request)["data"] as? [String: Any])
        #expect(data["type"] as? String == "betaAppReviewSubmissions")
    }

    @Test func tokenIsCachedUntilSixtySecondsBeforeExpiry() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let transport = StubTransport(responses: Array(repeating: StubTransport.Response(body: "{\"data\":[]}"), count: 3))
        let client = makeClient(transport) { clock.withLock { $0 } }

        _ = try await client.betaGroups(appID: "a")
        // The token expires 1140 s after it was made (iat is backdated 60 s, lifetime 1200 s).
        clock.withLock { $0 = $0.addingTimeInterval(1060) }  // 80 s left: still cached
        _ = try await client.betaGroups(appID: "a")
        clock.withLock { $0 = $0.addingTimeInterval(30) }  // 50 s left: refresh
        _ = try await client.betaGroups(appID: "a")

        let tokens = transport.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(tokens[0] == tokens[1])
        #expect(tokens[1] != tokens[2])
    }

    @Test func repeatedNextLinkThrowsInsteadOfLooping() async throws {
        let page = "{\"data\":[],\"links\":{\"next\":\"https://api.appstoreconnect.apple.com/v1/betaGroups?cursor=A\"}}"
        let transport = StubTransport(responses: Array(repeating: StubTransport.Response(body: page), count: 5))
        await #expect(throws: ASCError.decoding("pagination cycle")) {
            try await makeClient(transport).betaGroups(appID: "a")
        }
        #expect(transport.requests.count == 2)
    }

    @Test func foreignHostNextLinkIsNeverRequested() async throws {
        for next in ["https://evil.example.com/v1/betaGroups?cursor=A", "http://api.appstoreconnect.apple.com/v1/betaGroups?cursor=A"] {
            let transport = StubTransport(responses: [
                StubTransport.Response(body: "{\"data\":[],\"links\":{\"next\":\"\(next)\"}}"),
                StubTransport.Response(body: "{\"data\":[]}"),
            ])
            await #expect(throws: ASCError.decoding("unexpected pagination link")) {
                try await makeClient(transport).betaGroups(appID: "a")
            }
            #expect(transport.requests.count == 1)
        }
    }

    @Test func stubTransportThrowsWhenOutOfResponses() async throws {
        await #expect(throws: StubTransport.OutOfResponses.self) {
            try await makeClient(StubTransport()).betaGroups(appID: "a")
        }
    }
}
