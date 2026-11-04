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
                repoURL: repoURL, ref: request.uri.queryParameters.get("ref"), token: try globalGitHubToken())
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
            let suggestion = try await repositoryDetector.suggestion(
                repoURL: app.repoURL, ref: request.uri.queryParameters.get("ref"), token: try appGitHubToken(app),
                machines: try machines.all(), bundleIDs: await bundleIDs(of: app))
            return try Response.json(suggestion)
        }
        api.get("apps/:id/repo-icon") { request, context in
            let app = try app(context)
            let ref = request.uri.queryParameters.get("ref") ?? ""
            let image = try await repositoryDetector.icon(
                key: "\(app.id)|\(app.repoURL)|\(ref)", repoURL: app.repoURL, ref: ref, token: try appGitHubToken(app),
                bundleIDs: await bundleIDs(of: app))
            return Self.imageResponse(image)
        }
    }

    /// The global `HANGAR_GITHUB_TOKEN`, nil when unset or empty.
    func globalGitHubToken() throws -> String? {
        try variables.value(global: BuildService.tokenVariable).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The token builds of `app` use: its own `HANGAR_GITHUB_TOKEN`, else the global one.
    func appGitHubToken(_ app: App) throws -> String? {
        try variables.resolvedEntries(appID: app.id).first { $0.name == BuildService.tokenVariable }?.value
    }

    /// The app's bundle ID from App Store Connect, nil without a key or when App Store Connect cannot be asked:
    /// detection then works without it.
    private func bundleIDs(of app: App) async -> [String]? {
        guard let client = try? appStoreConnectClient(),
            let found = try? await client.apps().first(where: { $0.id == app.appStoreConnectAppID })
        else { return nil }
        return [found.bundleID]
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
            inspection.notes.append("App Store Connect could not be asked for these apps, so they are not matched yet.")
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

    /// `commit` (a SHA) and `path` (an image inside an `.appiconset`) of an icon request.
    static func imageQuery(_ request: Request) throws -> (commit: String, path: String) {
        let commit = request.uri.queryParameters.get("commit") ?? ""
        guard commit.count >= 7, commit.count <= 40, commit.allSatisfy(\.isHexDigit) else {
            throw APIError(code: "invalid_request", message: "'commit' must be a commit SHA.")
        }
        let path = request.uri.queryParameters.get("path") ?? ""
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
