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
        #expect(server.tools.count == 24)
        #expect(Set(server.tools.map(\.name)).isSuperset(of: [
            "list_apps", "inspect_repo", "add_app", "get_workflows", "set_workflow", "list_branches", "deploy_check",
            "start_build", "get_build", "get_build_log", "list_artifacts", "list_machines", "list_testflight_groups", "list_variables",
        ]))
    }
}
