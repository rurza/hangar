import Foundation
import HangarCore
import Hummingbird

/// Request context of every Hangar route: the shared JSON coders (ISO 8601 dates with milliseconds).
public struct HangarRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage

    public init(source: ApplicationRequestContextSource) { coreContext = .init(source: source) }

    public var requestDecoder: JSONDecoder { JSONCoding.decoder }
    public var responseEncoder: JSONEncoder { JSONCoding.encoder }
}

public typealias APIGroup = RouterGroup<HangarRequestContext>

extension HangarServerApp {
    /// The public API under `/api/v1`; the worker routes mount on the same router.
    public func buildRouter() -> Router<HangarRequestContext> {
        let router = Router(context: HangarRequestContext.self)
        router.add(middleware: APIErrorMiddleware())
        let api = router.group("api/v1")
        api.get("health") { _, _ in try Response.json(HealthResponse(ok: true, version: HangarVersion.current)) }
        addAppRoutes(to: api)
        addVariableRoutes(to: api)
        addNumberRoutes(to: api)
        addBuildRoutes(to: api)
        addJobRoutes(to: api)
        addMachineRoutes(to: api)
        api.get("events") { _, _ in eventsResponse() }
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
        guard let text = uri.queryParameters.get(name) else { return nil }
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
            return try Response.json(body, status: status)
        }
    }
}
