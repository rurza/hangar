import Foundation
import HangarClient
import HangarCore
import Synchronization

@testable import HangarMCP

/// A fake Hangar server: answers by method and path (query ignored unless the key includes it), records every
/// request, and 404s anything unknown with `not_found`.
final class RouteTransport: HTTPTransport {
    struct Recorded: Sendable {
        var method: String
        var path: String
        var query: String?
        var body: Data?
        var authorization: String?

        func json<T: Decodable>(_ type: T.Type) throws -> T { try JSONCoding.decoder.decode(T.self, from: body ?? Data()) }
    }

    private let state = Mutex<(routes: [String: [StubTransport.Response]], requests: [Recorded])>(([:], []))

    /// `key` is `"GET apps"` (path after /api/v1/) or `"GET apps?ref=main"`. Several responses for one key are served in
    /// order, the last one repeating.
    func on(_ key: String, _ responses: StubTransport.Response...) {
        state.withLock { $0.routes[key, default: []].append(contentsOf: responses) }
    }

    func on(_ key: String, json value: some Encodable, status: Int = 200) {
        on(key, StubTransport.Response(status: status, body: try! JSONCoding.encoder.encode(value)))
    }

    func on(_ key: String, error code: String, status: Int) {
        on(key, json: APIError(code: code, message: "\(code) message"), status: status)
    }

    var requests: [Recorded] { state.withLock { $0.requests } }

    func requests(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let path = String(url.path.dropFirst("/api/v1/".count))
        let method = request.httpMethod ?? "GET"
        let recorded = Recorded(
            method: method, path: path, query: url.query, body: request.httpBody,
            authorization: request.value(forHTTPHeaderField: "Authorization"))
        let response = state.withLock { state -> StubTransport.Response in
            state.requests.append(recorded)
            for key in ["\(method) \(path)?\(url.query ?? "")", "\(method) \(path)"] {
                guard var queue = state.routes[key], !queue.isEmpty else { continue }
                let first = queue.removeFirst()
                if !queue.isEmpty { state.routes[key] = queue }
                return first
            }
            return StubTransport.Response(
                status: 404, body: try! JSONCoding.encoder.encode(APIError(code: "not_found", message: "no route \(method) \(path)")))
        }
        return (response.body, HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

enum Fixtures {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let server = URL(string: "http://mini.tailnet:8787")!
    static let token = "hgr_" + String(repeating: "k", count: 43)
    static let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let machineID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    static let app = App(
        id: appID, slug: "legilo", name: "Legilo", repoURL: "https://github.com/acme/legilo",
        appStoreConnectAppID: "42", createdAt: t0)

    static func tools(_ transport: RouteTransport, now: @escaping @Sendable () -> Date = { t0 }) -> HangarTools {
        HangarTools(
            api: HangarAPI(baseURL: server, transport: transport, token: token), now: now, sleep: { _ in },
            pollInterval: .milliseconds(1))
    }

    static func tool(_ name: String, _ tools: HangarTools) -> MCPTool {
        tools.all.first { $0.name == name }!
    }

    /// Runs the tool as `tools/call` does, turning a `ToolError` into an error result.
    static func call(_ name: String, _ tools: HangarTools, _ arguments: [String: JSONValue] = [:]) async throws -> ToolOutput {
        do {
            return try await tool(name, tools).handler(ToolArguments(arguments))
        } catch let error as ToolError {
            return ToolOutput(text: error.message, isError: true)
        }
    }

    static let workflow = Workflow(
        project: "Legilo.xcodeproj", xcode: "27.2",
        actions: [WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect)],
        postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("Internal")])])],
        start: WorkflowStart(branches: .patterns(["release/2.0", "main"])))

    static let file = WorkflowFile(version: 1, workflows: ["release": workflow])

    static func build(status: BuildStatus, jobStatus: JobStatus, failedStep: String? = nil, outputs: [String: String] = [:]) -> Build {
        let buildID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let jobID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        var steps = [StepRecord(name: "checkout", status: .succeeded)]
        if let failedStep { steps.append(StepRecord(name: failedStep, status: .failed)) }
        let job = Job(
            id: jobID, buildID: buildID, action: workflow.actions[0], status: jobStatus, machineID: machineID,
            steps: steps, failureReason: failedStep.map { "\($0): xcodebuild exited with 65" }, outputs: outputs,
            createdAt: t0)
        return Build(
            id: buildID, appID: appID, workflow: "release", ref: "main", commit: "abcdef1234567", buildNumber: 310,
            status: status, createdAt: t0, jobs: [job])
    }

    static let machine = Machine(id: machineID, name: "mini", lastSeenAt: t0, createdAt: t0)

    static func object(_ text: String) throws -> [String: JSONValue] {
        guard case .object(let fields) = try JSONCoding.decoder.decode(JSONValue.self, from: Data(text.utf8)) else {
            throw ToolError("not an object: \(text)")
        }
        return fields
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
}
