import Foundation
import Hummingbird

/// The web app: static files bundled in the `Web` resource folder. `GET /assets/<file>` serves a file from
/// `Web/assets`; every other `GET` outside `/api/` gets `index.html`, whose router renders the page.
public struct WebUI: Sendable {
    /// Every UI response carries this policy: no inline scripts or styles, no requests to other origins.
    static let contentSecurityPolicy =
        "default-src 'self'; img-src 'self' https: data:; style-src 'self'; script-src 'self'; connect-src 'self'"
    static let contentTypes = [
        "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml",
        "html": "text/html; charset=utf-8",
    ]
    /// Asset paths are `<file>` or `<folder>/<file>` (the pages live in `assets/pages`).
    static let maxAssetDepth = 2

    /// The bundled `Web` folder.
    public static var root: URL { Bundle.module.url(forResource: "Web", withExtension: nil)! }

    let root: URL

    public init(root: URL = WebUI.root) { self.root = root }

    public func addRoutes(to router: Router<HangarRequestContext>) {
        router.get("/") { _, _ in try index() }
        router.get("assets/**") { _, context in
            guard let file = assetURL(context.parameters.getCatchAll()) else { throw HTTPError(.notFound) }
            return try serve(file)
        }
        router.get("**") { request, _ in
            // Unknown API paths stay JSON 404s instead of becoming the app's page.
            guard !request.uri.path.hasPrefix("/api/") else { throw HTTPError(.notFound) }
            return try index()
        }
    }

    private func index() throws -> Response { try serve(root.appendingPathComponent("index.html")) }

    /// The file under `Web/assets` the raw path components name, nil unless every decoded component is a plain
    /// name (`[A-Za-z0-9._-]`, not starting with a dot) and the result is a regular file inside the folder.
    func assetURL(_ components: [Substring]) -> URL? {
        guard (1...Self.maxAssetDepth).contains(components.count) else { return nil }
        let folder = root.appendingPathComponent("assets", isDirectory: true).resolvingSymlinksInPath()
        var file = folder
        for component in components {
            guard let name = component.removingPercentEncoding, name.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil,
                !name.hasPrefix(".")
            else { return nil }
            file.appendPathComponent(name)
        }
        file = file.resolvingSymlinksInPath()
        guard file.path.hasPrefix(folder.path + "/"),
            (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { return nil }
        return file
    }

    private func serve(_ file: URL) throws -> Response {
        guard let contentType = Self.contentTypes[file.pathExtension.lowercased()],
            let data = try? Data(contentsOf: file)
        else { throw HTTPError(.notFound) }
        return Response(
            status: .ok,
            headers: [
                .contentType: contentType, .contentLength: "\(data.count)", .cacheControl: "no-cache",
                .contentSecurityPolicy: Self.contentSecurityPolicy, .xContentTypeOptions: "nosniff",
                .init("Referrer-Policy")!: "same-origin",
            ],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

