import Foundation
import HTTPTypes
import HangarClient
import HangarCore
import HangarMCP
import Hummingbird

/// `/mcp`: Hangar's agent tools over MCP's Streamable HTTP transport, the same ones `hangar mcp` serves on stdio, so
/// an agent needs only this URL and an API token, not the CLI.
///
/// Each POST carries one JSON-RPC message and an API token (`Authorization: Bearer hgr_…`). The tools call this
/// server's API with that token, so its scope decides what the agent may do, exactly as for `hangar mcp`; an owner
/// token is refused, as there. The API is reached under the name the agent used, which the Host check has already
/// matched to this server, so the links the tools give out carry that name too. The answer is one JSON response; a
/// notification gets 202. There is no session and no server-sent stream: a GET or DELETE is 405, as the transport
/// allows.
extension HangarServerApp {
    static let mcpBodyLimit = 1 << 20

    func addMCPRoutes(to router: Router<HangarRequestContext>) {
        let mcp = router.group("mcp").add(middleware: CrossSiteGuard())
        mcp.post { request, context in try await mcpResponse(request, context: context) }
        mcp.get { _, _ in Self.mcpMethodNotAllowed() }
        mcp.delete { _, _ in Self.mcpMethodNotAllowed() }
    }

    private func mcpResponse(_ request: Request, context: HangarRequestContext) async throws -> Response {
        guard let secret = Authentication.bearerAPIToken(request),
            let token = try apiTokens.authenticate(secret: secret, now: now())
        else {
            return Self.mcpRefusal(
                .unauthorized, "Send an API token: Authorization: Bearer hgr_… (Settings › Agent Access in the web UI).",
                headers: [.wwwAuthenticate: #"Bearer realm="hangar""#])
        }
        guard token.scope != .owner else {
            return Self.mcpRefusal(
                .forbidden, "'\(token.name)' is an owner token; give an agent a read, deploy or configure token instead.")
        }
        let buffer = try await request.body.collect(upTo: Self.mcpBodyLimit)
        let message = String(buffer: buffer)
        let host = request.head.authority ?? "\(configuration.host):\(configuration.port)"
        guard let base = URL(string: "http://\(host)") else {
            return Self.mcpRefusal(.badRequest, "The request's host name is not usable.")
        }
        let server = HangarTools.server(api: HangarAPI(baseURL: base, transport: mcpTransport, token: secret))
        guard let reply = await server.handle(message) else { return Response(status: .accepted) }
        return Response(
            status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(string: reply)))
    }

    private static func mcpRefusal(_ status: HTTPResponse.Status, _ message: String, headers: HTTPFields = [:]) -> Response {
        var headers = headers
        headers[.contentType] = "application/json"
        let body = #"{"error":{"code":"mcp_refused","message":"# + Self.jsonEscaped(message) + #""}}"#
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: body)))
    }

    private static func mcpMethodNotAllowed() -> Response {
        Response(status: .methodNotAllowed, headers: [.allow: "POST"])
    }

    private static func jsonEscaped(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}
