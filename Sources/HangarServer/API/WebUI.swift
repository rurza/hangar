import Foundation
import Hummingbird
import Logging

/// The web app: static files bundled in the `Web` resource folder. `GET /assets/<file>` serves a file from
/// `Web/assets`; every other `GET` outside `/api/` gets `index.html`, whose router renders the page.
public struct WebUI: Sendable {
    /// Every UI response carries this policy: no inline scripts or styles, no requests to other origins, and no
    /// framing by any page (another site could otherwise overlay the UI and trick a click on Delete or Add Mac).
    /// Images only from this server and Apple's CDN, where every app icon comes from: an `iconURL` on another host
    /// would otherwise ping it each time the UI is viewed (security review L10).
    static let contentSecurityPolicy =
        "default-src 'self'; img-src 'self' https://*.mzstatic.com data:; style-src 'self'; script-src 'self'; connect-src 'self'; "
        + "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    /// `frame-ancestors` for browsers that predate it.
    static let frameOptions = HTTPFields.Element.Name("X-Frame-Options")!
    static let contentTypes = [
        "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml",
        "html": "text/html; charset=utf-8",
    ]
    /// Asset paths are `<file>` or `<folder>/<file>` (the pages live in `assets/pages`).
    static let maxAssetDepth = 2

    /// The SwiftPM resource bundle that holds `Web`; install-server.sh copies it next to the binary.
    static let bundleName = "Hangar_HangarServer.bundle"
    static let logger = Logger(label: "app.hangar.server.web")

    /// The bundled `Web` folder, nil when the resource bundle is not installed. Found without `Bundle.module`,
    /// whose accessor calls `fatalError` when the bundle is missing.
    public static let root: URL? = locateRoot()

    /// Looks for the bundle next to the executable (symlinks resolved), in the main bundle's resources, and next
    /// to the bundle holding this code (the test runner's case).
    static func locateRoot() -> URL? {
        let directories = [
            Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent(),
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
        ]
        for case let directory? in directories {
            let bundle = directory.appendingPathComponent(bundleName, isDirectory: true)
            // macOS bundles keep resources in Contents/Resources; SwiftPM on Linux puts them at the top.
            for web in [bundle.appendingPathComponent("Contents/Resources/Web"), bundle.appendingPathComponent("Web")]
            where FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path) {
                return web
            }
        }
        return nil
    }

    private final class BundleFinder {}

    let root: URL?

    /// `root` nil serves 503 "web UI not installed" on the UI paths; the API is unaffected.
    public init(root: URL? = WebUI.root) { self.root = root }

    public func addRoutes(to router: Router<HangarRequestContext>) {
        if root == nil {
            Self.logger.warning(
                "web UI not installed: \(Self.bundleName) is not next to the executable; the API still works")
        }
        router.get("/") { _, _ in try index() }
        router.get("assets/**") { _, context in
            guard let root else { return Self.notInstalled() }
            guard let file = assetURL(context.parameters.getCatchAll(), root: root) else { throw HTTPError(.notFound) }
            return try serve(file)
        }
        router.get("**") { request, _ in
            // Unknown API paths stay JSON 404s instead of becoming the app's page.
            guard !request.uri.path.hasPrefix("/api/") else { throw HTTPError(.notFound) }
            return try index()
        }
    }

    /// The page every UI path gets when the resource bundle is missing.
    static func notInstalled() -> Response {
        let html = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Hangar</title></head><body>
            <h1>Web UI not installed</h1><p>The server cannot find \(bundleName). Run scripts/server/install-server.sh \
            again to install it next to hangar-server. The API under /api/v1 works without it.</p></body></html>

            """
        return Response(
            status: .serviceUnavailable,
            headers: [
                .contentType: "text/html; charset=utf-8", .cacheControl: "no-cache",
                .contentSecurityPolicy: contentSecurityPolicy, .xContentTypeOptions: "nosniff", frameOptions: "DENY",
            ],
            body: ResponseBody(byteBuffer: ByteBuffer(string: html)))
    }

    private func index() throws -> Response {
        guard let root else { return Self.notInstalled() }
        return try serve(root.appendingPathComponent("index.html"))
    }

    /// The file under `Web/assets` the raw path components name, nil unless every decoded component is a plain
    /// name (`[A-Za-z0-9._-]`, not starting with a dot) and the result is a regular file inside the folder.
    func assetURL(_ components: [Substring], root: URL) -> URL? {
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
                .init("Referrer-Policy")!: "same-origin", Self.frameOptions: "DENY",
            ],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

