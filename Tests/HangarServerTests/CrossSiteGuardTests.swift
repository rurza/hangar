import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// The cross-site request guard on the public `/api/v1` routes. The router test client sends Host `localhost`.
@Suite struct CrossSiteGuardTests {
    static let deploy = DeployRequest(app: "legilo", workflow: "testflight", ref: "main")

    @Test func crossSiteTextPlainDeployIsRefusedAndQueuesNothing() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        let attempts: [(HTTPFields, HTTPResponse.Status, String)] = [
            // A no-cors fetch from another site: the browser sends Sec-Fetch-Site and Origin.
            ([.contentType: "text/plain", CrossSiteGuard.secFetchSite: "cross-site", .origin: "https://evil.example"],
             .forbidden, "cross_site_request"),
            ([.contentType: "text/plain", .origin: "https://evil.example"], .forbidden, "cross_site_request"),
            ([.contentType: "text/plain", CrossSiteGuard.secFetchSite: "same-site"], .forbidden, "cross_site_request"),
            // An old browser that sends neither header still cannot pass a text/plain body.
            ([.contentType: "text/plain"], .unsupportedMediaType, "unsupported_media_type"),
            ([:], .unsupportedMediaType, "unsupported_media_type"),
            ([.contentType: "application/x-www-form-urlencoded"], .unsupportedMediaType, "unsupported_media_type"),
        ]
        try await fixture.test { client in
            for (headers, status, code) in attempts {
                try await client.execute(uri: "/api/v1/builds", method: .post, headers: headers, body: try body(Self.deploy)) {
                    response throws in
                    #expect(response.status == status)
                    #expect(try decode(APIError.self, response).code == code)
                }
            }
        }
        #expect(try fixture.server.builds.builds(appID: nil, limit: 100).isEmpty)
    }

    @Test func cancelWithAForeignOriginIsRefused() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        let build = try await fixture.server.buildService.deploy(Self.deploy)
        try await fixture.test { client in
            for origin in ["https://evil.example", "http://localhost:9999", "null"] {
                try await client.execute(
                    uri: "/api/v1/builds/\(build.id.uuidString)/cancel", method: .post, headers: [.origin: origin]
                ) { response throws in
                    #expect(response.status == .forbidden)
                    #expect(try decode(APIError.self, response).code == "cross_site_request")
                }
            }
        }
        #expect(try fixture.server.builds.build(id: build.id)?.status != .cancelled)
    }

    @Test func sameOriginJSONAndBodilessRequestsPass() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            let browser: HTTPFields = [
                .contentType: "application/json; charset=utf-8", .origin: "http://localhost",
                CrossSiteGuard.secFetchSite: "same-origin",
            ]
            let build = try await client.execute(uri: "/api/v1/builds", method: .post, headers: browser, body: try body(Self.deploy)) {
                #expect($0.status == .accepted)
                return try decode(Build.self, $0)
            }
            // A bodiless cancel from the same page needs no Content-Type.
            try await client.execute(
                uri: "/api/v1/builds/\(build.id.uuidString)/cancel", method: .post,
                headers: [.origin: "http://localhost", CrossSiteGuard.secFetchSite: "same-origin"]
            ) { response throws in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/api/v1/variables/GONE", method: .delete, headers: [CrossSiteGuard.secFetchSite: "none"]) {
                #expect($0.status == .noContent)
            }
        }
    }

    @Test func cliStyleRequestPasses() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/builds", method: .post, headers: [.contentType: "application/json", .accept: "application/json"],
                body: try body(Self.deploy)
            ) { response in
                #expect(response.status == .accepted)
            }
        }
    }

    @Test func workerRoutesAreNotChecked() async throws {
        let fixture = try APIFixture()
        let (_, token) = try fixture.server.machines.create(name: "studio")
        let report = MachineReport(
            macOSVersion: "26.1", xcodes: [], chip: "Apple M4", performanceCores: 4, memoryGB: 16, freeDiskGB: 100,
            onACPower: true, tools: [:], canSignWithoutPrompt: true, runningJobIDs: [])
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/worker/heartbeat", method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "text/plain", .origin: "https://evil.example"],
                body: try body(HeartbeatRequest(report: report))
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func getRequestsAreNotChecked() async throws {
        try await APIFixture().test { client in
            try await client.execute(
                uri: "/api/v1/health", method: .get,
                headers: [.origin: "https://evil.example", CrossSiteGuard.secFetchSite: "cross-site"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test(arguments: [
        ("http://localhost", "localhost", true), ("http://localhost:8787", "localhost:8787", true),
        ("http://LOCALHOST:80", "localhost", true), ("https://box.tail1.ts.net", "box.tail1.ts.net:443", true),
        ("http://[::1]:8787", "[::1]:8787", true), ("http://localhost:8787", "localhost", false),
        ("http://evil.example", "localhost", false), ("null", "localhost", false),
        ("http://100.71.242.42:8787", "100.71.242.42:8787", true),
    ])
    func originMatching(origin: String, authority: String, matches: Bool) {
        #expect(CrossSiteGuard.origin(origin, matches: authority) == matches)
    }

    @Test func jsonMediaTypes() {
        #expect(CrossSiteGuard.isJSON("application/json"))
        #expect(CrossSiteGuard.isJSON("Application/JSON; charset=utf-8"))
        #expect(!CrossSiteGuard.isJSON("text/plain"))
        #expect(!CrossSiteGuard.isJSON("application/json-seq"))
        #expect(!CrossSiteGuard.isJSON(nil))
    }
}
