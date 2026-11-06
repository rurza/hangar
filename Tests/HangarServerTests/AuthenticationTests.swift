import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

final class Counter: Sendable {
    let count = Mutex(0)
}

/// Who may call the public API: the owner's tailnet devices, API tokens, and nobody else (security review C2).
@Suite(.timeLimit(.minutes(1))) struct AuthenticationTests {
    private static let owner = TailnetPeer(loginName: "owner@github", nodeName: "phone.tail1234.ts.net", tagged: false)
    private static let friend = TailnetPeer(loginName: "friend@github", nodeName: "laptop.tail1234.ts.net", tagged: false)
    private static let taggedBox = TailnetPeer(loginName: "tagged-devices", nodeName: "ci.tail1234.ts.net", tagged: true)

    private static func access(
        peers: [String: TailnetPeer] = ["100.101.1.1": owner, "100.101.1.2": friend, "100.101.1.3": taggedBox],
        node: TailnetPeer? = TailnetPeer(loginName: "owner@github", nodeName: "server.tail1234.ts.net", tagged: false),
        now: @escaping @Sendable () -> Date = Date.init, ownUsersPorts: Set<Int> = [],
        checks: Counter = Counter()
    ) throws -> (OwnerAccess, FakeTailnet, ServerSettingsRepository) {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        let tailnet = FakeTailnet(peers: peers, node: node)
        let settings = ServerSettingsRepository(database: database)
        let access = OwnerAccess(
            tailnet: tailnet, settings: settings, now: now, isThisMac: { $0 == Self.thisMac },
            isOwnUsersConnection: { port in
                checks.count.withLock { $0 += 1 }
                return ownUsersPorts.contains(port)
            })
        return (access, tailnet, settings)
    }

    /// The server Mac's own tailnet address in these tests.
    private static let thisMac = "100.101.1.9"
    private static let serverNode = TailnetPeer(loginName: "owner@github", nodeName: "server.tail1234.ts.net", tagged: false)

    // MARK: - The owner check

    @Test func theServerNodesLoginIsTheOwnerByDefault() async throws {
        let (access, _, _) = try Self.access()
        #expect(await access.owner(peer: "100.101.1.1", port: 50000) == "owner@github")
        #expect(await access.owner(peer: "100.101.1.2", port: 50000) == nil)
        #expect(await access.allowedLogins() == ["owner@github"])
    }

    @Test func taggedDevicesAndUnknownAddressesAreNeverTheOwner() async throws {
        let (access, _, _) = try Self.access()
        #expect(await access.owner(peer: "100.101.1.3", port: 50000) == nil)
        #expect(await access.owner(peer: "100.101.9.9", port: 50000) == nil)
        #expect(await access.owner(peer: nil, port: 50000) == nil)
    }

    @Test func loopbackAndLANAddressesAreNotEvenLookedUp() async throws {
        // Host-executor builds and local agents connect from loopback: Tailscale cannot vouch for them.
        let (access, tailnet, _) = try Self.access(peers: ["127.0.0.1": Self.owner, "192.168.1.5": Self.owner, "::1": Self.owner])
        for address in ["127.0.0.1", "::1", "192.168.1.5", "unknown", "::ffff:127.0.0.1"] {
            #expect(await access.owner(peer: address, port: 50000) == nil)
        }
        #expect(tailnet.whoisCount == 0)
    }

    @Test func tailscaleIPv6AndMappedAddressesAreLookedUp() async throws {
        let (access, _, _) = try Self.access(peers: ["fd7a:115c:a1e0::1": Self.owner, "100.64.0.7": Self.owner])
        #expect(await access.owner(peer: "fd7a:115c:a1e0::1", port: 50000) == "owner@github")
        #expect(await access.owner(peer: "::ffff:100.64.0.7", port: 50000) == "owner@github")
        #expect(OwnerAccess.isTailnetAddress("100.128.0.1") == false)
        #expect(OwnerAccess.isTailnetAddress("100.63.255.255") == false)
    }

    /// whois names the device: on the server Mac a build as `hangar` would resolve to the owner's login too. Only a
    /// connection whose client end belongs to the server's own user counts.
    @Test func aConnectionFromTheServerMacCountsOnlyFromTheServersUser() async throws {
        let checks = Counter()
        let (access, _, _) = try Self.access(
            peers: [Self.thisMac: Self.serverNode], ownUsersPorts: [50001], checks: checks)
        #expect(await access.owner(peer: Self.thisMac, port: 50001) == "owner@github")
        #expect(await access.owner(peer: Self.thisMac, port: 50002) == nil)
        #expect(await access.owner(peer: Self.thisMac, port: nil) == nil)
        // A keep-alive connection is checked once; another device is never checked.
        _ = await access.owner(peer: Self.thisMac, port: 50001)
        _ = await access.owner(peer: "100.101.1.1", port: 50003)
        #expect(checks.count.withLock { $0 } == 2)
    }

    @Test func theRealCheckFindsThisProcesssUsersSocketsOnly() throws {
        // This process is excluded, and no process holds a connection to port 1 from port 1.
        #expect(!LocalConnection.isOwnUsers(clientPort: 1, serverPort: 1))
        #expect(!LocalConnection.isOwnUsers(clientPort: 0, serverPort: 8787))
    }

    @Test func aTaggedServerNodeHasNoDefaultOwner() async throws {
        let (access, _, _) = try Self.access(node: Self.taggedBox)
        #expect(await access.allowedLogins().isEmpty)
        #expect(await access.owner(peer: "100.101.1.1", port: 50000) == nil)
    }

    @Test func configuredLoginsReplaceTheDefault() async throws {
        let (access, _, settings) = try Self.access()
        try access.setConfiguredLogins(["Friend@GitHub", " friend@github "])
        let stored = try settings.value(OwnerAccess.settingKey)
        #expect(stored == #"["Friend@GitHub"]"#)
        #expect(await access.owner(peer: "100.101.1.2", port: 50000) == "friend@github")
        #expect(await access.owner(peer: "100.101.1.1", port: 50000) == nil)
        try access.setConfiguredLogins([])
        #expect(await access.owner(peer: "100.101.1.1", port: 50000) == "owner@github")
        #expect(throws: APIError.self) { try access.setConfiguredLogins(["two words"]) }
    }

    @Test func whoisAnswersAreCachedBriefly() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let (access, tailnet, _) = try Self.access(now: { clock.withLock { $0 } })
        _ = await access.owner(peer: "100.101.1.1", port: 50000)
        _ = await access.owner(peer: "100.101.1.1", port: 50000)
        _ = await access.owner(peer: "100.101.9.9", port: 50000)
        _ = await access.owner(peer: "100.101.9.9", port: 50000)
        #expect(tailnet.whoisCount == 2)
        #expect(tailnet.selfNodeCount == 1)
        clock.withLock { $0 += OwnerAccess.unknownTTL + 1 }
        _ = await access.owner(peer: "100.101.1.1", port: 50000)
        _ = await access.owner(peer: "100.101.9.9", port: 50000)
        #expect(tailnet.whoisCount == 3)
        clock.withLock { $0 += OwnerAccess.knownTTL }
        _ = await access.owner(peer: "100.101.1.1", port: 50000)
        #expect(tailnet.whoisCount == 4)
    }

    @Test func whoisAndStatusJSONAreRead() {
        let whois = """
            {"Node":{"Name":"phone.tail1234.ts.net.","Tags":null},"UserProfile":{"ID":1,"LoginName":"owner@github"}}
            """
        #expect(TailscaleCLI.parseWhois(whois) == TailnetPeer(loginName: "owner@github", nodeName: "phone.tail1234.ts.net", tagged: false))
        let tagged = #"{"Node":{"Name":"ci.x.ts.net.","Tags":["tag:ci"]},"UserProfile":{"LoginName":"tagged-devices"}}"#
        #expect(TailscaleCLI.parseWhois(tagged)?.tagged == true)
        #expect(TailscaleCLI.parseWhois("peer not found") == nil)
        let status = """
            {"Self":{"DNSName":"server.tail1234.ts.net.","UserID":72318256769457},
             "User":{"72318256769457":{"LoginName":"owner@github"},"5":{"LoginName":"other@github"}}}
            """
        #expect(TailscaleCLI.parseStatus(status) == TailnetPeer(loginName: "owner@github", nodeName: "server.tail1234.ts.net", tagged: false))
    }

    @Test func theCLIAsksTheDaemonWithWhoisJSON() async {
        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments.first == "whois" }, lines: [#"{"Node":{"Name":"a.ts.net."},"UserProfile":{"LoginName":"o@github"}}"#])
        let cli = TailscaleCLI(runner: runner, fileExists: { $0 == "/opt/homebrew/bin/tailscale" })
        #expect(await cli.whois("100.101.1.1")?.loginName == "o@github")
        #expect(runner.commands.map(\.arguments) == [["whois", "--json", "100.101.1.1"]])
        #expect(runner.commands[0].executable == "/opt/homebrew/bin/tailscale")
    }

    // MARK: - The routes

    @Test func noTokenAndNoOwnerDeviceIsRefused() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        try await fixture.test { client in
            for (method, uri) in [
                (HTTPRequest.Method.get, "/api/v1/apps"), (.get, "/api/v1/settings"), (.get, "/api/v1/events"),
                (.get, "/api/v1/machines"), (.post, "/api/v1/machines/pairings"), (.get, "/api/v1/signing"),
                (.get, "/api/v1/variables"), (.get, "/api/v1/api-tokens"),
            ] {
                try await client.execute(uri: uri, method: method) { response in
                    #expect(response.status == .unauthorized, "\(method) \(uri)")
                    let error = try decode(APIError.self, response)
                    #expect(error.code == "authentication_required")
                }
            }
        }
    }

    @Test func anUnauthenticatedCallerCannotMintAMachineToken() async throws {
        // The C2 chain started here: POST /machines, then a `vm` heartbeat to receive the identity.
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/machines", method: .post, headers: jsonHeaders, body: try body(CreateMachineRequest(name: "evil"))
            ) { response in #expect(response.status == .unauthorized) }
        }
        let machines = try fixture.server.machines.all()
        #expect(machines.isEmpty)
    }

    @Test func healthEnrollAndTheUIStayOpen() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/health", method: .get) { #expect($0.status == .ok) }
            // A wrong code reaches the pairing check, not the authentication.
            let response = try await EnrollAPITests.enroll(client, code: "AAAA-BBBB", name: "new-mac")
            let error = try decode(APIError.self, response)
            #expect(error.code == "invalid_pairing_code")
            try await client.execute(uri: "/", method: .get) { #expect($0.status == .ok) }
            // The worker routes answer to their machine token, not to the owner check.
            try await client.execute(uri: "/api/v1/worker/me", method: .get) { response in
                #expect(response.status == .unauthorized)
                let error = try decode(APIError.self, response)
                #expect(error.code != "authentication_required")
            }
        }
    }

    @Test func aPairingCodeMadeByTheOwnerEnrollsAMacWithoutAnyOtherCredential() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        let pairing = fixture.server.pairings.create()
        try await fixture.test { client in
            let response = try await EnrollAPITests.enroll(client, code: pairing.code, name: "new-mac")
            #expect(response.status == .created)
        }
    }

    @Test func aRelayedRequestIsNeverTheOwners() async throws {
        // `tailscale serve` or another proxy on this Mac connects from loopback for every peer.
        let fixture = try APIFixture(ownerCheck: FixedOwner("owner@github"))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps", method: .get, headers: [HTTPFields.Element.Name("X-Forwarded-For")!: "1.2.3.4"]) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test func scopedTokensWorkWithoutTheOwnerAndStayInScope() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        let (_, read) = try fixture.server.apiTokens.create(name: "agent", scope: .read)
        let headers: HTTPFields = [.authorization: "Bearer \(read)", .contentType: "application/json"]
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps", method: .get, headers: headers) { #expect($0.status == .ok) }
            try await client.execute(uri: "/api/v1/machines/pairings", method: .post, headers: headers) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/api/v1/access", method: .get, headers: headers) { #expect($0.status == .forbidden) }
        }
    }

    @Test func anOwnerTokenCanDoWhatTheOwnerCan() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        let (_, secret) = try fixture.server.apiTokens.create(name: "my-cli", scope: .owner)
        let headers: HTTPFields = [.authorization: "Bearer \(secret)", .contentType: "application/json"]
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/machines", method: .post, headers: headers, body: try body(CreateMachineRequest(name: "mini"))
            ) { #expect($0.status == .created) }
            try await client.execute(
                uri: "/api/v1/variables/FOO", method: .put, headers: headers,
                body: try body(VariableInput(value: "bar", isSecret: true))
            ) { #expect($0.status == .noContent || $0.status == .ok) }
            try await client.execute(uri: "/api/v1/access", method: .get, headers: headers) { response in
                let status = try decode(AccessStatus.self, response)
                #expect(status.viewerToken == "my-cli" && status.viewerLogin == nil)
            }
        }
    }

    @Test func noRequestMintsAnOwnerToken() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/api-tokens", method: .post, headers: jsonHeaders,
                body: try body(CreateAPITokenRequest(name: "root", scope: .owner))
            ) { response in
                #expect(response.status == .badRequest)
                let error = try decode(APIError.self, response)
                #expect(error.code == "invalid_scope")
            }
        }
        let tokens = try fixture.server.apiTokens.all()
        #expect(tokens.isEmpty)
    }

    // MARK: - /access

    @Test func accessShowsTheViewerAndTheDefaultOwner() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner("owner@github"))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/access", method: .get) { response in
                let status = try decode(AccessStatus.self, response)
                #expect(status == AccessStatus(
                    viewerLogin: "owner@github", viewerToken: nil, allowedLogins: ["owner@github"], configured: false,
                    serverNodeLogin: "owner@github", serverNodeTagged: false))
            }
        }
    }

    @Test func theOwnerCannotLockTheirOwnDeviceOut() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner("owner@github"))
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/access", method: .put, headers: jsonHeaders, body: try body(AccessUpdate(allowedLogins: ["friend@github"]))
            ) { response in
                #expect(response.status == .conflict)
                let error = try decode(APIError.self, response)
                #expect(error.code == "access_lockout")
            }
            try await client.execute(
                uri: "/api/v1/access", method: .put, headers: jsonHeaders,
                body: try body(AccessUpdate(allowedLogins: ["owner@github", "friend@github"]))
            ) { response in
                #expect(response.status == .ok)
                let status = try decode(AccessStatus.self, response)
                #expect(status.allowedLogins == ["owner@github", "friend@github"])
            }
        }
        #expect(fixture.server.owners.configuredLogins() == ["owner@github", "friend@github"])
    }

    /// Every `/api/v1` route has a decision: open, owner only, or the scope a token needs. A new route fails here
    /// until it is added, so a GET cannot become `read` (or a POST open) by accident.
    @Test func everyRouteHasAnExplicitDecision() throws {
        let fixture = try APIFixture()
        let decisions = fixture.server.buildRouter(webRoot: nil).routes
            .map { (method: $0.method, path: $0.path.description.replacing(/\{(\w+)\}/) { ":" + $0.1 }) }
            .filter { $0.path.hasPrefix("/api/v1/") && !$0.path.hasPrefix("/api/v1/worker/") }
            .map { route -> String in
                let relative = String(route.path.dropFirst("/api/v1/".count))
                let decision = Authentication.isOpen(method: route.method, path: relative)
                    ? "open" : APITokenPolicy.required(method: route.method, path: relative)?.rawValue ?? "owner"
                return "\(route.method) \(relative) \(decision)"
            }
            .sorted()
        #expect(decisions == Self.expectedDecisions)
    }

    static let expectedDecisions = """
        DELETE api-tokens/:id owner
        DELETE apps/:id configure
        DELETE apps/:id/global-secrets/:name owner
        DELETE apps/:id/variable-groups/:group owner
        DELETE apps/:id/variables/:name owner
        DELETE apps/:id/workflow-file configure
        DELETE machines/:id owner
        DELETE machines/:id/vm-builds owner
        DELETE settings/development-key owner
        DELETE signing owner
        DELETE variable-groups/:group owner
        DELETE variable-groups/:group/variables/:name owner
        DELETE variables/:name owner
        GET access owner
        GET api-tokens owner
        GET api-tokens/current read
        GET apps read
        GET apps/:id read
        GET apps/:id/beta-groups read
        GET apps/:id/branches read
        GET apps/:id/deploy-check read
        GET apps/:id/environment read
        GET apps/:id/global-secrets read
        GET apps/:id/numbers read
        GET apps/:id/variable-groups read
        GET apps/:id/variables read
        GET apps/:id/workflow-file read
        GET apps/:id/workflow-source read
        GET apps/:id/workflow-suggestion read
        GET apps/:id/workflows read
        GET asc/apps read
        GET builds read
        GET builds/:id read
        GET events read
        GET github/repos read
        GET github/repos/:owner/:repo/icon read
        GET github/repos/:owner/:repo/inspect read
        GET health open
        GET jobs/:id read
        GET jobs/:id/artifacts read
        GET jobs/:id/artifacts/:name read
        GET jobs/:id/log read
        GET machines read
        GET settings read
        GET setup read
        GET setup/asc-keys owner
        GET setup/github owner
        GET setup/local-worker owner
        GET signing read
        GET variable-groups read
        GET variable-groups/:group read
        GET variable-groups/:group/variables read
        GET variables read
        PATCH apps/:id/variables/:name owner
        PATCH variable-groups/:group owner
        POST api-tokens owner
        POST apps owner
        POST apps/:id/beta-groups configure
        POST builds deploy
        POST builds/:id/cancel deploy
        POST enroll open
        POST machines owner
        POST machines/:id/pause owner
        POST machines/:id/resume owner
        POST machines/:id/vm-builds owner
        POST machines/pairings owner
        POST settings/asc-key owner
        POST settings/development-key owner
        POST settings/github-token owner
        POST setup/asc-keys/use owner
        POST setup/github/use-gh owner
        POST setup/local-worker owner
        POST signing/certificate owner
        POST signing/import owner
        POST variable-groups owner
        PUT access owner
        PUT apps/:id/global-secrets/:name owner
        PUT apps/:id/numbers/next configure
        PUT apps/:id/variable-groups/:group owner
        PUT apps/:id/variables/:name owner
        PUT apps/:id/workflow-file configure
        PUT variable-groups/:group/variables/:name owner
        PUT variables/:name owner
        """.split(separator: "\n").map(String.init)
}
