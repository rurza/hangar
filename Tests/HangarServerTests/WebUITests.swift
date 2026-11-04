import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

@Suite struct WebUITests {
    static let csp =
        "default-src 'self'; img-src 'self' https: data:; style-src 'self'; script-src 'self'; connect-src 'self'"

    @Test func rootServesIndex() async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(response.headers[.contentSecurityPolicy] == Self.csp)
                #expect(String(buffer: response.body).contains(#"<div id="app">"#))
            }
        }
    }

    @Test(arguments: ["/apps/legilo", "/builds/x", "/apps/legilo/workflow", "/settings"])
    func deepLinkServesIndex(path: String) async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: path, method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(String(buffer: response.body).contains(#"<div id="app">"#))
            }
        }
    }

    @Test(arguments: [
        ("/assets/app.js", "text/javascript; charset=utf-8"),
        ("/assets/styles.css", "text/css; charset=utf-8"),
        ("/assets/icon.svg", "image/svg+xml"),
    ])
    func assetServedWithType(path: String, type: String) async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: path, method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == type)
                #expect(response.headers[.cacheControl] == "no-cache")
                #expect(response.body.readableBytes > 0)
            }
        }
    }

    @Test func cspHeaderOnAssets() async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: "/assets/ui.js", method: .get) { response in
                #expect(response.headers[.contentSecurityPolicy] == Self.csp)
                #expect(response.headers[.xContentTypeOptions] == "nosniff")
                #expect(response.headers[.init("Referrer-Policy")!] == "same-origin")
            }
        }
    }

    @Test(arguments: [
        "/assets/..%2Fhangar.sqlite", "/assets/%2e%2e/master.key", "/assets/.hidden", "/assets/%2e%2e%2f%2e%2e%2fPackage.swift",
        "/assets/..", "/assets/missing.js", "/assets/", "/assets/app.js%00.css", "/assets/a/b/c.js",
    ])
    func traversalIs404(path: String) async throws {
        try await APIFixture().test { client in
            try await client.execute(uri: path, method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// Modules under `assets/pages/` (one folder deep) are served; every segment is checked the same way.
    @Test func nestedAssetServed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets/pages"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<div id=\"app\"></div>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("export {}".utf8).write(to: root.appendingPathComponent("assets/pages/apps.js"))
        try Data("x".utf8).write(to: root.appendingPathComponent("secret.js"))

        let router = Router(context: HangarRequestContext.self)
        WebUI(root: root).addRoutes(to: router)
        try await Application(router: router).test(.router) { client in
            try await client.execute(uri: "/assets/pages/apps.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/javascript; charset=utf-8")
            }
            for path in ["/assets/pages", "/assets/pages/..%2F..%2Fsecret.js", "/assets/%2E%2E/secret.js"] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .notFound, "\(path)")
                }
            }
        }
    }

    @Test func unknownAPIPathStaysJSON404() async throws {
        try await APIFixture().test { client in
            for path in ["/api/v1/nope", "/api/v1/apps/x/nope/deeper", "/api/other"] {
                try await client.execute(uri: path, method: .get) { response throws in
                    #expect(response.status == .notFound, "\(path)")
                    #expect(response.headers[.contentType] == "application/json; charset=utf-8")
                    #expect(try decode(APIError.self, response).code == "not_found")
                }
            }
            try await client.execute(uri: "/api/v1/health", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func htmlHasNoInlineScript() throws {
        let html = try String(contentsOf: WebUI.root.appendingPathComponent("index.html"), encoding: .utf8)
        let scripts = html.ranges(of: /<script\b[^>]*>/).map { String(html[$0]) }
        #expect(!scripts.isEmpty)
        for tag in scripts { #expect(tag.contains("src="), "\(tag)") }
        #expect(!html.contains("style="))
        #expect(!html.contains("<style"))
        #expect(!html.contains(/\son[a-z]+\s*=/))
    }
}
