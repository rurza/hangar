import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import NIOCore

/// The repository picker and what Hangar reads from a repository before and after an app is added. GETs only, so
/// the cross-site guard leaves them to the Host check. Tokens go to GitHub in a header and nowhere else.
extension HangarServerApp {
    func addGitHubRoutes(to api: APIGroup) {
        api.get("github/repos") { _, _ in
            guard let token = try globalGitHubToken() else {
                throw APIError(code: "github_not_configured", message: "Set a GitHub token in Settings first.")
            }
            return try Response.json(try await githubRepositories.repositories(token: token))
        }
        api.get("github/repos/:owner/:repo/inspect") { request, context in
            let repoURL = try repositoryURL(context)
            var inspection = try await repositoryDetector.inspection(
                repoURL: repoURL, ref: request.query.get("ref"), token: try globalGitHubToken())
            inspection = try await matchAppStoreConnect(inspection)
            return try Response.json(inspection)
        }
        api.get("github/repos/:owner/:repo/icon") { request, context in
            let repoURL = try repositoryURL(context)
            let (commit, path) = try Self.imageQuery(request)
            let image = try await repositoryDetector.image(repoURL: repoURL, commit: commit, path: path, token: try globalGitHubToken())
            return Self.imageResponse(image)
        }
        api.get("apps/:id/workflow-suggestion") { request, context in
            let app = try app(context)
            // The bundle ID the Add App sheet picked, else the app's from App Store Connect.
            let picked = request.query.get("bundleID").flatMap { $0.isEmpty ? nil : [String($0)] }
            let bundleIDs: [String]? = if let picked { picked } else { await bundleIDs(of: app) }
            let suggestion = try await withAppToken(app) { token in
                try await repositoryDetector.suggestion(
                    repoURL: app.repoURL, ref: request.query.get("ref"), token: token,
                    machines: try machines.all(), bundleIDs: bundleIDs)
            }
            return try Response.json(suggestion)
        }
        api.get("apps/:id/repo-icon") { request, context in
            let app = try app(context)
            let ref = request.query.get("ref") ?? ""
            let bundleIDs = await bundleIDs(of: app)
            let image = try await withAppToken(app) { token in
                try await repositoryDetector.icon(
                    key: "\(app.id)|\(app.repoURL)|\(ref)", repoURL: app.repoURL, ref: ref, token: token, bundleIDs: bundleIDs)
            }
            return Self.imageResponse(image)
        }
    }

    /// The global `HANGAR_GITHUB_TOKEN`, nil when unset or empty.
    func globalGitHubToken() throws -> String? {
        try variables.value(global: BuildService.tokenVariable).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The token builds of `app` use: its own `HANGAR_GITHUB_TOKEN`, else the global one.
    func appGitHubToken(_ app: App) throws -> String? {
        try variables.resolvedEntries(appID: app.id, workflow: nil).first { $0.name == BuildService.tokenVariable }?.value
    }

    /// The app's bundle ID from App Store Connect (`GET /v1/apps/{id}`), nil without a key or when App Store
    /// Connect cannot be asked: detection then works without it.
    private func bundleIDs(of app: App) async -> [String]? {
        guard let client = try? appStoreConnectClient(),
            let found = try? await client.app(id: app.appStoreConnectAppID)
        else { return nil }
        return [found.bundleID]
    }

    /// Runs `body` with the token the app's builds use. GitHub refusing it is reported against the token that was
    /// used: the app's own `HANGAR_GITHUB_TOKEN` or the global one.
    func withAppToken<T>(_ app: App, _ body: (String?) async throws -> T) async throws -> T {
        do {
            return try await body(try appGitHubToken(app))
        } catch SourceHostError.http(status: 401, _) {
            let own = try variables.summaries(scope: .app(app.id)).contains { $0.name == BuildService.tokenVariable }
            throw APIError(
                code: "github_unauthorized",
                message: own
                    ? "GitHub rejected \(app.name)'s own GitHub token (its HANGAR_GITHUB_TOKEN variable). Set a new one on the app's page."
                    : "GitHub refused the token. Set a new one in Settings.")
        }
    }

    /// `https://github.com/{owner}/{repo}` from the path, refused unless both are plain GitHub names.
    private func repositoryURL(_ context: HangarRequestContext) throws -> String {
        let url = "https://github.com/\(try context.parameters.require("owner"))/\(try context.parameters.require("repo"))"
        _ = try GitHubSourceHost.parse(url)
        return url
    }

    /// Each detected app with its App Store Connect app, when a key is configured. A failure there becomes a note:
    /// the repository's apps are still worth showing.
    private func matchAppStoreConnect(_ inspection: RepositoryInspection) async throws -> RepositoryInspection {
        var inspection = inspection
        guard let client = try appStoreConnectClient() else { return inspection }
        let bundleIDs = Array(Set(inspection.apps.flatMap(\.bundleIDs))).sorted()
        guard !bundleIDs.isEmpty else { return inspection }
        let found: [ASCApp]
        do {
            found = try await client.apps(bundleIDs: bundleIDs)
        } catch {
            inspection.appStoreConnectUnavailable = true
            inspection.appStoreConnectError = Self.appStoreConnectReason(error)
            inspection.notes.append("App Store Connect could not be asked for these apps (\(inspection.appStoreConnectError!)), so they are not matched yet.")
            return inspection
        }
        let registered = Set(try apps.all().map(\.appStoreConnectAppID))
        let icons = await appIcons.iconURLs(ascAppIDs: found.map(\.id), client: client)
        let summaries = found.map {
            ASCAppSummary(
                id: $0.id, name: $0.name, bundleID: $0.bundleID, registered: registered.contains($0.id), iconURL: icons[$0.id])
        }
        inspection.apps = WorkflowDetector.matchAppStoreConnect(inspection.apps, ascApps: summaries)
        return inspection
    }

    /// A short reason App Store Connect failed, without its response text.
    static func appStoreConnectReason(_ error: any Error) -> String {
        switch error {
        case ASCError.http(let status, _) where status == 401 || status == 403: "it refused the key (HTTP \(status))"
        case ASCError.http(let status, _): "it answered HTTP \(status)"
        case ASCError.invalidPrivateKey: "the key in Settings is not a valid .p8 key"
        case is URLError: "it could not be reached"
        default: "it sent a response Hangar cannot read"
        }
    }

    /// `commit` (a SHA) and `path` (an image inside an `.appiconset`) of an icon request.
    static func imageQuery(_ request: Request) throws -> (commit: String, path: String) {
        let commit = request.query.get("commit") ?? ""
        guard commit.count >= 7, commit.count <= 40, commit.allSatisfy(\.isHexDigit) else {
            throw APIError(code: "invalid_request", message: "'commit' must be a commit SHA.")
        }
        let path = request.query.get("path") ?? ""
        let lowered = path.lowercased()
        guard path.contains(".appiconset/"), [".png", ".jpg", ".jpeg"].contains(where: lowered.hasSuffix),
            GitHubSourceHost.escapePath(path) != nil
        else {
            throw APIError(code: "invalid_path", message: "Only images inside an .appiconset are served.")
        }
        return (commit, path)
    }

    static func imageResponse(_ image: RepositoryDetector.Image) -> Response {
        Response(
            status: .ok,
            headers: [
                .contentType: image.contentType, .contentLength: "\(image.data.count)", .cacheControl: "private, max-age=3600",
                .init("X-Content-Type-Options")!: "nosniff",
            ],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: image.data)))
    }
}
