import Foundation
import HangarClient
import HangarCore
import Testing

@testable import hangar

private typealias H = CLIHarness

@Suite struct TokensCommandTests {
    static let token = APIToken(id: UUID(), name: "claude", scope: .deploy, prefix: "hgr_AbCd", createdAt: H.t0)

    @Test func createPrintsTheSecretOnce() async throws {
        let secret = "hgr_" + String(repeating: "s", count: 43)
        let harness = H(responses: [try H.json(CreateAPITokenResponse(token: Self.token, secret: secret), status: 201)])
        let result = await harness.run(["tokens", "create", "claude", "--scope", "deploy"])
        #expect(result.exitCode == 0)
        #expect(try result.bodies(CreateAPITokenRequest.self) == [CreateAPITokenRequest(name: "claude", scope: .deploy)])
        #expect(result.out.contains("Token: \(secret)"))
        #expect(result.requests.first?.url?.path == "/api/v1/api-tokens")
    }

    @Test func listNeverShowsSecrets() async throws {
        let harness = H(responses: [try H.json([Self.token])])
        let result = await harness.run(["tokens", "list"])
        #expect(result.exitCode == 0)
        #expect(result.out.contains("claude") && result.out.contains("deploy") && result.out.contains("hgr_AbCd…"))
        #expect(result.out.contains("never"))
    }

    @Test func revokeDeletesByName() async throws {
        let harness = H(responses: [StubTransport.Response(status: 204)])
        let result = await harness.run(["tokens", "revoke", "claude"])
        #expect(result.exitCode == 0)
        #expect(result.requests.first?.httpMethod == "DELETE")
        #expect(result.requests.first?.url?.path == "/api/v1/api-tokens/claude")
    }

    @Test func unknownScopeIsRefused() async {
        let result = await H().run(["tokens", "create", "x", "--scope", "admin"])
        #expect(result.exitCode != 0)
        #expect(result.requests.isEmpty)
    }

    @Test func mcpNeedsAnAPITokenInTheEnvironment() async {
        let missing = await H().run(["mcp"])
        #expect(missing.exitCode == 1)
        #expect(missing.err.contains("HANGAR_API_TOKEN"))
        let wrong = await H(environment: ["HANGAR_API_TOKEN": "machine-token"]).run(["mcp"])
        #expect(wrong.exitCode == 1)
        #expect(wrong.err.contains("start with hgr_"))
    }

    @Test func mcpServerOffersEveryTool() {
        let server = MCP.server(api: HangarAPI(baseURL: URL(string: "http://mini:8787")!, transport: StubTransport()))
        #expect(server.tools.count == 23)
        #expect(Set(server.tools.map(\.name)).isSuperset(of: [
            "list_apps", "inspect_repo", "get_workflows", "set_workflow", "list_branches", "deploy_check",
            "start_build", "get_build", "get_build_log", "list_artifacts", "list_machines", "list_testflight_groups", "list_variables",
        ]))
    }
}

/// Where the CLI and `hangar mcp` find the token they send (`APITokenSource`).
@Suite struct APITokenSourceTests {
    static let secret = "hgr_" + String(repeating: "a", count: 43)
    static let other = "hgr_" + String(repeating: "b", count: 43)

    @Test func theEnvironmentThenTheNamedFileThenTheDefaultFile() throws {
        let files = ["/f/token": Self.other + "\n", "/home/.config/hangar/token": Self.secret]
        let read: (String) -> String? = { files[$0] }
        #expect(try APITokenSource.resolve(environment: ["HANGAR_API_TOKEN": " \(Self.secret) "], readFile: read) == Self.secret)
        #expect(try APITokenSource.resolve(environment: ["HANGAR_API_TOKEN_FILE": "/f/token"], readFile: read) == Self.other)
        #expect(try APITokenSource.resolve(environment: ["HOME": "/home"], readFile: read) == Self.secret)
        #expect(try APITokenSource.resolve(environment: ["HOME": "/nobody"], readFile: read) == nil)
        #expect(try APITokenSource.resolve(environment: ["HOME": "/home"], includeDefaultFile: false, readFile: read) == nil)
        #expect(APITokenSource.defaultFile(environment: ["XDG_CONFIG_HOME": "/xdg", "HOME": "/home"]) == "/xdg/hangar/token")
    }

    @Test func badValuesAreErrorsNotSilentlyIgnored() {
        #expect(throws: APITokenSource.Problem.malformed(source: "HANGAR_API_TOKEN")) {
            try APITokenSource.resolve(environment: ["HANGAR_API_TOKEN": "machine-token"], readFile: { _ in nil })
        }
        #expect(throws: APITokenSource.Problem.unreadable(path: "/missing")) {
            try APITokenSource.resolve(environment: ["HANGAR_API_TOKEN_FILE": "/missing"], readFile: { _ in nil })
        }
    }

    @Test func theCLISendsTheTokenFromTheConfigFile() async throws {
        var harness = H(responses: [try H.json([App]())])
        harness.environment = ["HOME": "/home"]
        harness.files = ["/home/.config/hangar/token": Self.secret + "\n"]
        let result = await harness.run(["apps", "list"])
        #expect(result.exitCode == 0)
        #expect(result.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.secret)")
    }

    @Test func withoutATokenTheCLISendsNoneAndExplainsA401() async throws {
        let refused = APIError(code: "authentication_required", message: "Hangar answers only its owner's tailnet devices.")
        var harness = H(responses: [try H.json(refused, status: 401)])
        harness.environment = ["HOME": "/home"]
        let result = await harness.run(["apps", "list"])
        #expect(result.exitCode == 1)
        #expect(result.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.err.contains("authentication_required") && result.err.contains("~/.config/hangar/token"))
    }

    @Test func mcpNeverUsesTheOwnersDefaultFileAndRefusesOwnerTokens() async throws {
        var bare = H()
        bare.environment = ["HOME": "/home"]
        bare.files = ["/home/.config/hangar/token": Self.secret]
        let missing = await bare.run(["mcp"])
        #expect(missing.exitCode == 1 && missing.err.contains("HANGAR_API_TOKEN_FILE"))

        let owner = APIToken(id: UUID(), name: "my-cli", scope: .owner, prefix: "hgr_aaaa", createdAt: H.t0)
        var harness = H(responses: [try H.json(owner)])
        harness.environment = ["HANGAR_API_TOKEN_FILE": "/t"]
        harness.files = ["/t": Self.secret]
        let refused = await harness.run(["mcp"])
        #expect(refused.exitCode == 1 && refused.err.contains("owner token"))
        #expect(refused.requests.first?.url?.path == "/api/v1/api-tokens/current")
    }
}

@Suite struct MachineVMBuildsCommandTests {
    @Test func allowAndStopVMBuilds() async throws {
        let machine = Machine(id: UUID(), name: "macbook", createdAt: H.t0, vmBuilds: true)
        let allow = await H(responses: [try H.json(machine)]).run(["machines", "allow-vm", "macbook"])
        #expect(allow.exitCode == 0 && allow.out.contains("Allowed VM builds on macbook"))
        #expect(allow.requests.first?.httpMethod == "POST")
        #expect(allow.requests.first?.url?.path == "/api/v1/machines/macbook/vm-builds")
        var stopped = machine
        stopped.vmBuilds = false
        let stop = await H(responses: [try H.json(stopped)]).run(["machines", "stop-vm", "macbook"])
        #expect(stop.exitCode == 0 && stop.requests.first?.httpMethod == "DELETE")
    }
}
