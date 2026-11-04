import Foundation
import HangarCore
import Hummingbird

/// Stops other web sites from changing anything through a visitor's browser. The JSON decoder ignores
/// Content-Type, so without this a "simple" cross-site request (`text/plain` fetch, `<form enctype="text/plain">`)
/// would reach the state-changing routes.
///
/// Every method but GET, HEAD and OPTIONS is checked: `Sec-Fetch-Site` other than `same-origin`/`none`, or an
/// `Origin` whose host and port differ from the request's Host, is 403 `cross_site_request`; a body that is not
/// `application/json` is 415 `unsupported_media_type`. The CLI sends neither header and passes. The worker routes,
/// which authenticate with a machine token, are not checked.
struct CrossSiteGuard: RouterMiddleware {
    typealias Context = HangarRequestContext

    static let workerPrefix = "/api/v1/worker/"
    static let safeMethods: Set<HTTPRequest.Method> = [.get, .head, .options]

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard !Self.safeMethods.contains(request.method), !request.uri.path.hasPrefix(Self.workerPrefix) else {
            return try await next(request, context)
        }
        if let site = request.headers[Self.secFetchSite], !["same-origin", "none"].contains(site.lowercased()) {
            throw Self.crossSite
        }
        if let origin = request.headers[.origin], !Self.origin(origin, matches: request.authority) {
            throw Self.crossSite
        }
        if Self.hasBody(request), !Self.isJSON(request.headers[.contentType]) {
            throw APIError(code: "unsupported_media_type", message: "Send the request body as application/json.")
        }
        return try await next(request, context)
    }

    static let secFetchSite = HTTPFields.Element.Name("Sec-Fetch-Site")!
    static let crossSite = APIError(code: "cross_site_request", message: "Requests from other sites are not allowed.")

    /// True when the `Origin` header names the same host and port as the request's Host. `null` and unparsable
    /// origins never match. Ports default by the origin's scheme.
    static func origin(_ origin: String, matches authority: String?) -> Bool {
        guard let authority, let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
            let originHost = url.host?.lowercased()
        else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        let originPort = url.port ?? defaultPort
        guard let request = HostName.split(authority) else { return false }
        return HostName.normalize(originHost) == request.host && originPort == (request.port ?? defaultPort)
    }

    /// A body is announced by a non-zero Content-Length or by chunked transfer encoding.
    static func hasBody(_ request: Request) -> Bool {
        if let length = request.headers[.contentLength] { return Int(length) != 0 }
        return request.headers[.transferEncoding] != nil
    }

    /// `application/json`, parameters such as `charset` ignored.
    static func isJSON(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first ?? ""
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }
}
