import Foundation
import HangarCore
import Hummingbird
import NIOCore

/// Request context of every Hangar route: the shared JSON coders (ISO 8601 dates with milliseconds).
public struct HangarRequestContext: RemoteAddressRequestContext {
    public var coreContext: CoreRequestContextStorage
    /// The authenticated worker machine; set by `MachineAuth` on the worker routes, nil on the public ones.
    public var machine: Machine?
    /// The job a job token is limited to (set by `MachineAuth` with the token's machine); nil for a machine token.
    public var jobScope: UUID?
    /// The API token of the request, set by `Authentication`; nil for the owner's devices and the worker routes.
    public var apiToken: APIToken?
    /// The owner's Tailscale login when `Authentication` let the request in as the owner's device; nil otherwise.
    public var ownerLogin: String?
    /// The connected peer; the pairing rate limit counts failures per address.
    public let remoteAddress: SocketAddress?
    /// Set by `ProxyMark` when the request carries a reverse proxy's forwarding headers: the socket peer is then
    /// the proxy, not the browser, so it never counts as this Mac.
    public var relayedByProxy = false

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress
    }

    /// The peer's IP address, without the port; "unknown" when there is none (the router test client).
    var peer: String { remoteAddress?.ipAddress ?? "unknown" }

    public var requestDecoder: JSONDecoder { JSONCoding.decoder }
    public var responseEncoder: JSONEncoder { JSONCoding.encoder }
}

public typealias APIGroup = RouterGroup<HangarRequestContext>

extension HangarServerApp {
    /// The public API under `/api/v1`; the worker routes and the web app (from `webRoot`) mount on the same router.
    public func buildRouter(webRoot: URL? = WebUI.root) -> Router<HangarRequestContext> {
        let router = Router(context: HangarRequestContext.self)
        router.add(middleware: APIErrorMiddleware())
        // Every route, the UI's included: a DNS-rebinding page arrives under a Host that is not this server's.
        router.add(middleware: HostCheck(policy: configuration.hostPolicy))
        router.add(middleware: ProxyMark())
        // The cross-site guard skips the worker routes, which a machine token authenticates.
        // Authentication runs after it: neither a token nor the owner's device makes a cross-site request acceptable.
        let api = router.group("api/v1").add(middleware: CrossSiteGuard())
            .add(middleware: Authentication(tokens: apiTokens, owners: ownerCheck, now: now))
        api.get("health") { _, _ in try Response.json(HealthResponse(ok: true, version: HangarVersion.current)) }
        addAppRoutes(to: api)
        addVariableRoutes(to: api)
        addSettingsRoutes(to: api)
        addSigningRoutes(to: api)
        addSetupRoutes(to: api)
        addWorkflowFileRoutes(to: api)
        addDeployCheckRoutes(to: api)
        addNumberRoutes(to: api)
        addBuildRoutes(to: api)
        addJobRoutes(to: api)
        addMachineRoutes(to: api)
        addGitHubRoutes(to: api)
        addBetaGroupRoutes(to: api)
        addAPITokenRoutes(to: api)
        addAccessRoutes(to: api)
        addWorkerRoutes(to: api)
        api.get("events") { _, _ in eventsResponse() }
        // The worker install script and binary: outside /api/v1, GETs only, so no cross-site guard; Host-checked.
        InstallRoutes(workerBinaryPath: configuration.workerBinaryPath).addRoutes(to: router)
        WebUI(root: webRoot).addRoutes(to: router)
        return router
    }

    /// The `{id}` app of the path, by slug or UUID.
    func app(_ context: HangarRequestContext) throws -> App {
        let key = try context.parameters.require("id")
        guard let app = try apps.find(slugOrID: key) else {
            throw APIError(code: "app_not_found", message: "No app '\(key)'.")
        }
        return app
    }
}

extension Response {
    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONCoding.encoder.encode(value)
        return Response(
            status: status, headers: [.contentType: "application/json; charset=utf-8", .contentLength: "\(data.count)"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

extension Request {
    /// The integer query parameter, nil when absent; 400 when it is not a non-negative integer.
    func integer(_ name: String) throws -> Int? {
        guard let text = query.get(name) else { return nil }
        guard let value = Int(text), value >= 0 else {
            throw APIError(code: "invalid_request", message: "'\(name)' must be a non-negative integer.")
        }
        return value
    }
}

/// Turns every error a route throws into `{ "code", "message" }` with the matching status.
struct APIErrorMiddleware: RouterMiddleware {
    typealias Context = HangarRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            let (status, body) = APIErrorMapping.map(error)
            if status == .internalServerError {
                context.logger.error("\(request.method) \(request.uri.path) failed: \(error)")
            }
            var response = try Response.json(body, status: status)
            if case SourceHostError.rateLimited(let reset?) = error {
                response.headers[.retryAfter] = "\(max(1, Int(reset.timeIntervalSinceNow.rounded(.up))))"
            }
            return response
        }
    }
}
