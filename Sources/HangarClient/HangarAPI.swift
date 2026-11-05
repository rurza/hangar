import Foundation
import HangarCore

public enum HangarAPIError: Error, CustomStringConvertible {
    /// A non-2xx answer. A body that is not an `APIError` becomes code `http_<status>`.
    case server(APIError, status: Int)
    /// The request never got an HTTP answer, or a stream was cut off.
    case transport(any Error)
    /// A 2xx answer (or stream frame) whose body is not the expected JSON.
    case invalidResponse(any Error)

    public var description: String {
        switch self {
        case .server(let error, _): "\(error.message) (\(error.code))"
        case .transport(let error): "\(error)"
        case .invalidResponse(let error): "unreadable response: \(error)"
        }
    }
}

/// Typed client for the public routes in `docs/api.md` (not the worker routes).
public struct HangarAPI: Sendable {
    /// Opens a streaming GET and returns its body as lines, blank lines kept. A seam for tests.
    public typealias LineStreamOpener = @Sendable (URLRequest) -> AsyncThrowingStream<String, any Error>

    public let baseURL: URL
    private let transport: any HTTPTransport
    let openLines: LineStreamOpener
    /// An API token (`hgr_…`) sent as `Authorization: Bearer` on every request; nil sends none.
    private let token: String?

    /// `baseURL` is the server's root, such as `http://mac-mini:8787`.
    public init(baseURL: URL, transport: any HTTPTransport, token: String? = nil, openLines: LineStreamOpener? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.token = token
        self.openLines = openLines ?? Self.liveLines
    }

    // MARK: - Apps

    public func health() async throws -> HealthResponse { try await get("health") }
    public func apps() async throws -> [App] { try await get("apps") }
    public func app(_ app: String) async throws -> App { try await get("apps/\(segment(app))") }
    public func createApp(_ request: CreateAppRequest) async throws -> App { try await send("POST", "apps", body: request) }
    public func deleteApp(_ app: String) async throws { try await sendEmpty("DELETE", "apps/\(segment(app))") }

    // MARK: - Variables (`app` nil means global scope)

    public func variables(app: String? = nil) async throws -> [VariableSummary] {
        try await get(variablesPath(app))
    }

    /// `input.workflows` limits an app variable to those workflows; empty means all of them.
    public func setVariable(_ name: String, _ input: VariableInput, app: String? = nil) async throws {
        try await sendEmpty("PUT", "\(variablesPath(app))/\(segment(name))", body: input)
    }

    /// Deletes the app variable limited to exactly `workflows` (empty: the one for all workflows).
    public func deleteVariable(_ name: String, app: String? = nil, workflows: [String] = []) async throws {
        _ = try await perform(request("DELETE", "\(variablesPath(app))/\(segment(name))", items: Self.workflowItems(workflows)))
    }

    /// Changes the app variable limited to exactly `workflows`.
    public func updateVariable(_ name: String, app: String, workflows: [String] = [], _ update: VariableUpdate) async throws {
        var request = request("PATCH", "\(variablesPath(app))/\(segment(name))", items: Self.workflowItems(workflows))
        request.httpBody = try JSONCoding.encoder.encode(update)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    /// What a job of `workflow` gets (names and sources, no values).
    public func environment(app: String, workflow: String?) async throws -> [EffectiveVariable] {
        try await get("apps/\(segment(app))/environment", query: ["workflow": workflow])
    }

    private func variablesPath(_ app: String?) -> String {
        app.map { "apps/\(segment($0))/variables" } ?? "variables"
    }

    private static func workflowItems(_ workflows: [String]) -> [URLQueryItem] {
        workflows.map { URLQueryItem(name: "workflow", value: $0) }
    }

    // MARK: - Variable groups (`group` is an id or a name)

    public func variableGroups() async throws -> [VariableGroup] { try await get("variable-groups") }
    public func variableGroup(_ group: String) async throws -> VariableGroup { try await get("variable-groups/\(segment(group))") }

    public func createVariableGroup(name: String) async throws -> VariableGroup {
        try await send("POST", "variable-groups", body: VariableGroupRequest(name: name))
    }

    public func renameVariableGroup(_ group: String, to name: String) async throws -> VariableGroup {
        try await send("PATCH", "variable-groups/\(segment(group))", body: VariableGroupRequest(name: name))
    }

    public func deleteVariableGroup(_ group: String) async throws {
        try await sendEmpty("DELETE", "variable-groups/\(segment(group))")
    }

    public func setGroupVariable(_ name: String, _ input: VariableInput, group: String) async throws {
        try await sendEmpty("PUT", "variable-groups/\(segment(group))/variables/\(segment(name))", body: input)
    }

    public func deleteGroupVariable(_ name: String, group: String) async throws {
        try await sendEmpty("DELETE", "variable-groups/\(segment(group))/variables/\(segment(name))")
    }

    /// The groups the app links, in precedence order.
    public func variableGroupLinks(app: String) async throws -> [AppVariableGroupLink] {
        try await get("apps/\(segment(app))/variable-groups")
    }

    /// Links the group for `workflows` (empty: all), or changes the link's workflows.
    public func linkVariableGroup(_ group: String, app: String, workflows: [String] = []) async throws {
        try await sendEmpty(
            "PUT", "apps/\(segment(app))/variable-groups/\(segment(group))", body: LinkVariableGroupRequest(workflows: workflows))
    }

    public func unlinkVariableGroup(_ group: String, app: String) async throws {
        try await sendEmpty("DELETE", "apps/\(segment(app))/variable-groups/\(segment(group))")
    }

    // MARK: - Numbers and workflows

    public func numbers(app: String) async throws -> NumbersReport { try await get("apps/\(segment(app))/numbers") }

    public func bumpNumber(app: String, next: Int) async throws -> NumbersReport {
        try await send("PUT", "apps/\(segment(app))/numbers/next", body: BumpNumberRequest(next: next))
    }

    public func workflowFile(app: String) async throws -> StoredWorkflowFile {
        try await get("apps/\(segment(app))/workflow-file")
    }

    public func setWorkflowFile(app: String, yaml: String) async throws -> StoredWorkflowFile {
        try await send("PUT", "apps/\(segment(app))/workflow-file", body: PutWorkflowFileRequest(yaml: yaml))
    }

    public func clearWorkflowFile(app: String) async throws {
        try await sendEmpty("DELETE", "apps/\(segment(app))/workflow-file")
    }

    // MARK: - Builds and jobs

    public func deploy(_ request: DeployRequest) async throws -> Build { try await send("POST", "builds", body: request) }

    public func builds(app: String? = nil, limit: Int? = nil) async throws -> [Build] {
        try await get("builds", query: ["app": app, "limit": limit.map(String.init)])
    }

    public func build(_ id: UUID) async throws -> Build { try await get("builds/\(id.uuidString)") }
    public func cancelBuild(_ id: UUID) async throws -> Build { try await send("POST", "builds/\(id.uuidString)/cancel") }
    public func job(_ id: UUID) async throws -> Job { try await get("jobs/\(id.uuidString)") }

    public func log(jobID: UUID, step: String? = nil, tail: Int? = nil) async throws -> [LogEntry] {
        try await get("jobs/\(jobID.uuidString)/log", query: ["step": step, "tail": tail.map(String.init)])
    }

    public func artifacts(jobID: UUID) async throws -> [ArtifactInfo] { try await get("jobs/\(jobID.uuidString)/artifacts") }

    public func artifact(jobID: UUID, name: String) async throws -> Data {
        try await perform(request("GET", "jobs/\(jobID.uuidString)/artifacts/\(segment(name))"))
    }

    // MARK: - Repositories, App Store Connect and deploy checks

    public func settings() async throws -> SettingsStatus { try await get("settings") }
    public func githubRepositories() async throws -> [GitHubRepo] { try await get("github/repos") }

    /// `repository` is `owner/name`.
    public func inspectRepository(_ repository: String, ref: String? = nil) async throws -> RepositoryInspection {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        let path = "github/repos/\(segment(parts.first ?? ""))/\(segment(parts.count > 1 ? parts[1] : ""))/inspect"
        return try await get(path, query: ["ref": ref])
    }

    public func appStoreConnectApps() async throws -> [ASCAppSummary] { try await get("asc/apps") }

    // MARK: Signing

    /// The server's Apple Development identity for VM archives; never the `.p12` or its password.
    public func signingStatus() async throws -> SigningStatus { try await get("signing") }
    /// Create, or Renew within 30 days of expiry: one development certificate through App Store Connect.
    public func createSigningCertificate() async throws -> SigningCreateResponse { try await send("POST", "signing/certificate") }
    public func importSigningIdentity(p12: Data, password: String) async throws -> SigningStatus {
        try await send("POST", "signing/import", body: ImportSigningIdentityRequest(p12: p12, password: password))
    }
    /// Deletes the server's stored copy; the certificate is not revoked.
    public func removeSigningIdentity() async throws -> SigningStatus { try await send("DELETE", "signing") }

    public func workflowSuggestion(app: String, ref: String? = nil, bundleID: String? = nil) async throws -> WorkflowSuggestion {
        try await get("apps/\(segment(app))/workflow-suggestion", query: ["ref": ref, "bundleID": bundleID])
    }

    /// The workflows in effect at `ref`, nil meaning the default branch.
    public func workflows(app: String, ref: String?) async throws -> WorkflowsResponse {
        try await get("apps/\(segment(app))/workflows", query: ["ref": ref])
    }

    public func branches(app: String) async throws -> RepositoryBranches { try await get("apps/\(segment(app))/branches") }

    public func deployCheck(app: String, workflow: String, ref: String? = nil, commit: String? = nil, machine: String? = nil)
        async throws -> DeployCheck
    {
        try await get(
            "apps/\(segment(app))/deploy-check",
            query: ["workflow": workflow, "ref": ref, "commit": commit, "machine": machine])
    }

    public func betaGroups(app: String) async throws -> [BetaGroup] { try await get("apps/\(segment(app))/beta-groups") }

    public func createBetaGroup(app: String, _ request: CreateBetaGroupRequest) async throws -> BetaGroup {
        try await send("POST", "apps/\(segment(app))/beta-groups", body: request)
    }

    // MARK: - API tokens

    public func apiTokens() async throws -> [APIToken] { try await get("api-tokens") }

    public func createAPIToken(_ request: CreateAPITokenRequest) async throws -> CreateAPITokenResponse {
        try await send("POST", "api-tokens", body: request)
    }

    public func revokeAPIToken(_ token: String) async throws { try await sendEmpty("DELETE", "api-tokens/\(segment(token))") }
    public func currentAPIToken() async throws -> APIToken { try await get("api-tokens/current") }

    // MARK: - Machines

    public func machines() async throws -> [Machine] { try await get("machines") }

    public func createMachine(_ request: CreateMachineRequest) async throws -> CreateMachineResponse {
        try await send("POST", "machines", body: request)
    }

    public func deleteMachine(_ machine: String) async throws { try await sendEmpty("DELETE", "machines/\(segment(machine))") }

    /// Turns builds on `machine` (name or ID) off: it takes no new jobs until `resumeMachine`.
    public func pauseMachine(_ machine: String) async throws -> Machine {
        try await send("POST", "machines/\(segment(machine))/pause")
    }

    public func resumeMachine(_ machine: String) async throws -> Machine {
        try await send("POST", "machines/\(segment(machine))/resume")
    }

    // MARK: - Plumbing

    private struct Empty: Encodable {}

    private func get<Response: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> Response {
        try decode(try await perform(request("GET", path, query: query)))
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = Empty?.none)
        async throws -> Response
    {
        try decode(try await perform(try request(method, path, body: body)))
    }

    private func sendEmpty(_ method: String, _ path: String, body: (some Encodable)? = Empty?.none) async throws {
        _ = try await perform(try request(method, path, body: body))
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONCoding.decoder.decode(Response.self, from: data)
        } catch {
            throw HangarAPIError.invalidResponse(error)
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw HangarAPIError.transport(error)
        }
        try Self.check(status: response.statusCode, body: data)
        return data
    }

    static func check(status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let error = (try? JSONCoding.decoder.decode(APIError.self, from: body))
            ?? APIError(code: "http_\(status)", message: HTTPURLResponse.localizedString(forStatusCode: status))
        throw HangarAPIError.server(error, status: status)
    }

    private func request(_ method: String, _ path: String, body: (some Encodable)?) throws -> URLRequest {
        var request = request(method, path)
        if let body {
            request.httpBody = try JSONCoding.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// `path` is already percent-encoded (fixed words, UUIDs and `segment(_:)` output). Nil query values are left out.
    func request(_ method: String, _ path: String, query: [String: String?] = [:]) -> URLRequest {
        request(
            method, path,
            items: query.sorted { Self.queryOrder($0.key) < Self.queryOrder($1.key) }
                .compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } })
    }

    /// As above with the query items as given, so a name may repeat (`workflow=A&workflow=B`).
    func request(_ method: String, _ path: String, items: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var root = components.percentEncodedPath
        while root.hasSuffix("/") { root.removeLast() }
        components.percentEncodedPath = root + "/api/v1/" + path
        components.queryItems = items.isEmpty ? nil : items
        // URLComponents leaves `+` as it is, which the server (like any form decoder) reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url ?? baseURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// A fixed order keeps URLs stable (dictionaries are unordered): follow, app, ref, step, then the rest.
    private static func queryOrder(_ key: String) -> String {
        let order = ["follow", "app", "workflow", "ref", "commit", "step", "limit", "tail"]
        return order.firstIndex(of: key).map { "\($0)" } ?? "9\(key)"
    }

    /// One path segment: anything but unreserved characters is percent-encoded, so a name cannot add segments.
    private func segment(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }
}
