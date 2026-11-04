import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

@Suite struct HostPolicyTests {
    static let tailscaleIP = "100.71.242.42"

    @Test(arguments: [
        "100.71.242.42", "100.71.242.42:8787", "100.71.242.42:1",
        "studio", "Studio:8787", "studio.tail1234.ts.net", "studio.tail1234.ts.net.:8787", "other-mac.tailabc.ts.net",
        "ci.example.com:8787",
    ])
    func allowsTheBoundHostThisMacsNamesAndTailnetNames(authority: String) {
        let policy = HostPolicy(boundHost: Self.tailscaleIP, extraNames: ["studio", "ci.example.com"])
        #expect(policy.allows(authority: authority))
    }

    @Test(arguments: [
        "evil.example", "evil.example:8787", "localhost", "localhost:8787", "127.0.0.1:8787", "[::1]:8787",
        "100.71.242.43:8787", "ts.net.evil.example", "studio.local", "", "100.71.242.42:x",
    ])
    func refusesOtherNamesAndLoopbackWhenBoundToTailscale(authority: String) {
        let policy = HostPolicy(boundHost: Self.tailscaleIP, extraNames: ["studio", "ci.example.com"])
        #expect(!policy.allows(authority: authority))
    }

    @Test func refusesAMissingHost() {
        #expect(!HostPolicy(boundHost: "127.0.0.1").allows(authority: nil))
    }

    @Test(arguments: ["127.0.0.1", "localhost", "::1", "0.0.0.0"])
    func allowsLoopbackNamesWhenBoundToLoopbackOrEverything(bound: String) {
        let policy = HostPolicy(boundHost: bound)
        for authority in ["localhost:8787", "127.0.0.1:8787", "[::1]:8787", "LOCALHOST"] {
            #expect(policy.allows(authority: authority))
        }
        #expect(!policy.allows(authority: "evil.example:8787"))
    }

    @Test func descriptionListsTheNamesAndTheTailnetRule() {
        let policy = HostPolicy(boundHost: Self.tailscaleIP, extraNames: ["Studio", "studio.", " "])
        #expect(policy.description == "100.71.242.42, studio, *.ts.net")
    }

    @Test func detectsTheShortHostNameLocalHostNameAndMagicDNSName() async {
        let runner = RecordingProcessRunner()
        runner.script({ $0.executable == "/usr/sbin/scutil" }, lines: ["Adams-Mac-Studio"])
        runner.script(
            { $0.executable == "/opt/homebrew/bin/tailscale" && $0.arguments == ["status", "--json"] },
            lines: [#"{"Self": {"DNSName": "adams-mac-studio.tail1234.ts.net.", "HostName": "x"}, "Peer": {}}"#])
        let names = await HostPolicy.detectLocalNames(
            runner: runner, hostName: "studio.local", fileExists: { $0 == "/opt/homebrew/bin/tailscale" })
        #expect(names == ["studio", "adams-mac-studio", "adams-mac-studio.tail1234.ts.net"])
        #expect(runner.commands.first?.arguments == ["--get", "LocalHostName"])
    }

    @Test func detectionLeavesOutWhatItCannotFind() async {
        let runner = RecordingProcessRunner()
        runner.script({ _ in true }, lines: ["not running"], exitCode: 1)
        let names = await HostPolicy.detectLocalNames(runner: runner, hostName: "", fileExists: { _ in false })
        #expect(names.isEmpty)
    }

    /// The router test client sends Host `localhost`.
    @Test func refusesEveryRouteUnderAForeignHost() async throws {
        let fixture = try APIFixture(boundHost: Self.tailscaleIP)
        try await fixture.test { client in
            for (uri, method) in [
                ("/api/v1/health", HTTPRequest.Method.get), ("/", .get), ("/assets/app.js", .get),
                ("/api/v1/worker/heartbeat", .post), ("/api/v1/apps", .post),
            ] {
                try await client.execute(uri: uri, method: method) { response throws in
                    #expect(response.status == .misdirectedRequest)
                    #expect(try decode(APIError.self, response).code == "host_not_allowed")
                }
            }
        }
    }

    @Test func answersAnAllowedHost() async throws {
        let fixture = try APIFixture(boundHost: Self.tailscaleIP, allowedHosts: ["localhost"])
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/health", method: .get) { #expect($0.status == .ok) }
        }
    }
}
