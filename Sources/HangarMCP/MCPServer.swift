import Foundation
import HangarClient
import HangarCore

/// A Model Context Protocol server over newline-delimited JSON-RPC 2.0 (the stdio transport), offering tools only.
/// Requests run concurrently, so a long `wait_for_build` does not hold up a `ping`; responses may come out of order.
public struct MCPServer: Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String
    public let tools: [MCPTool]
    /// Turns an unexpected handler error into the text of an `isError` result.
    let describe: @Sendable (any Error) -> String

    public init(
        name: String, version: String, instructions: String, tools: [MCPTool],
        describe: @escaping @Sendable (any Error) -> String = { "\($0)" }
    ) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.describe = describe
    }

    /// Reads requests from `lines` until it ends, writing each response line (without the newline) to `write`.
    public func run<Lines: AsyncSequence & Sendable>(lines: Lines, write: @escaping @Sendable (String) -> Void) async throws
    where Lines.Element == String {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await line in lines {
                group.addTask {
                    if let response = await handle(line) { write(response) }
                }
            }
            try await group.waitForAll()
        }
    }

    /// The response line to one request line; nil for a notification or a blank line.
    public func handle(_ line: String) async -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
            let message = try? JSONCoding.decoder.decode(JSONValue.self, from: data)
        else { return Self.encode(Self.error(id: .null, code: -32700, message: "Parse error")) }
        guard case .object(let fields) = message, fields["jsonrpc"] == .string("2.0"),
            case .string(let method)? = fields["method"]
        else { return Self.encode(Self.error(id: Self.id(of: message), code: -32600, message: "Invalid request")) }
        guard let id = fields["id"], id != .null else { return nil }  // a notification: nothing to answer
        let params: [String: JSONValue]
        switch fields["params"] {
        case .object(let object)?: params = object
        case nil, .null?: params = [:]
        default: return Self.encode(Self.error(id: id, code: -32602, message: "params must be an object"))
        }
        let reply: JSONValue
        switch method {
        case "initialize": reply = Self.result(id: id, initialize(params))
        case "ping": reply = Self.result(id: id, .object([:]))
        case "tools/list": reply = Self.result(id: id, .object(["tools": .array(tools.map(\.listing))]))
        case "tools/call": reply = await call(id: id, params)
        default: reply = Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return Self.encode(reply)
    }

    func initialize(_ params: [String: JSONValue]) -> JSONValue {
        var version = Self.supportedProtocolVersions[0]
        if case .string(let asked)? = params["protocolVersion"], Self.supportedProtocolVersions.contains(asked) {
            version = asked
        }
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": .string(name), "version": .string(self.version)]),
            "instructions": .string(instructions),
        ])
    }

    func call(id: JSONValue, _ params: [String: JSONValue]) async -> JSONValue {
        guard case .string(let name)? = params["name"] else {
            return Self.error(id: id, code: -32602, message: "tools/call needs a tool name")
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case .object(let object)?: arguments = object
        case nil, .null?: arguments = [:]
        default: return Self.error(id: id, code: -32602, message: "arguments must be an object")
        }
        let output: ToolOutput
        do {
            output = try await tool.handler(ToolArguments(arguments))
        } catch let error as ToolError {
            output = ToolOutput(text: error.message, isError: true)
        } catch {
            output = ToolOutput(text: describe(error), isError: true)
        }
        return Self.result(
            id: id,
            .object([
                "content": .array([.object(["type": .string("text"), "text": .string(output.text)])]),
                "isError": .bool(output.isError),
            ]))
    }

    static func id(of message: JSONValue) -> JSONValue {
        if case .object(let fields) = message, let id = fields["id"] { return id }
        return .null
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ])
    }

    /// One line: no pretty printing, so no newline inside a message.
    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self))
            ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
    }
}
