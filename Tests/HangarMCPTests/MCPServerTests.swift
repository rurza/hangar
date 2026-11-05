import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarMCP

@Suite struct MCPServerTests {
    let server = MCPServer(
        name: "hangar", version: "9.9.9", instructions: "Use the tools.",
        tools: [
            MCPTool(
                name: "echo", title: "Echo", description: "Echoes `text`.",
                inputSchema: Schema.object(["text": Schema.string("Text.")], required: ["text"]), hints: .read
            ) { arguments in ToolOutput(text: try arguments.string("text")) },
            MCPTool(
                name: "boom", title: "Boom", description: "Fails.", inputSchema: Schema.object([:]),
                hints: MCPTool.Hints(readOnly: false, destructive: true, idempotent: false, openWorld: true)
            ) { _ in throw APIError(code: "x", message: "y") },
        ],
        describe: { "described: \($0)" })

    func reply(_ line: String) async throws -> [String: JSONValue] {
        let text = try #require(await server.handle(line))
        #expect(!text.contains("\n"))
        return try Fixtures.object(text)
    }

    func result(_ reply: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let result)? = reply["result"] else { throw ToolError("no result in \(reply)") }
        return result
    }

    @Test func initializeNegotiatesTheProtocolVersion() async throws {
        let known = try result(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        #expect(known["protocolVersion"] == .string("2025-03-26"))
        #expect(known["serverInfo"] == .object(["name": .string("hangar"), "version": .string("9.9.9")]))
        #expect(known["instructions"] == .string("Use the tools."))
        let unknown = try result(try await reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(unknown["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
    }

    @Test func idsComeBackAsSent() async throws {
        #expect(try await reply(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)["id"] == .int(7))
        #expect(try await reply(#"{"jsonrpc":"2.0","id":"x-1","method":"ping"}"#)["id"] == .string("x-1"))
    }

    @Test func notificationsAndBlankLinesGetNoAnswer() async {
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)
        #expect(await server.handle("   ") == nil)
    }

    @Test func protocolErrors() async throws {
        func code(_ line: String) async throws -> JSONValue? {
            guard case .object(let error)? = try await reply(line)["error"] else { return nil }
            return error["code"]
        }
        #expect(try await code("{not json") == .int(-32700))
        #expect(try await code(#"{"id":1,"method":"ping"}"#) == .int(-32600))
        #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#) == .int(-32601))
        #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope"}}"#) == .int(-32602))
    }

    @Test func toolsListCarriesSchemasAndHints() async throws {
        let listed = try result(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        guard case .array(let tools)? = listed["tools"], case .object(let boom) = tools[1],
            case .object(let annotations)? = boom["annotations"], case .object(let echo) = tools[0],
            case .object(let schema)? = echo["inputSchema"]
        else { Issue.record("unexpected listing \(listed)"); return }
        #expect(boom["name"] == .string("boom"))
        #expect(annotations["destructiveHint"] == .bool(true))
        #expect(annotations["readOnlyHint"] == .bool(false))
        #expect(schema["required"] == .array([.string("text")]))
    }

    @Test func toolResultsAndToolErrors() async throws {
        let ok = try result(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#))
        #expect(ok["isError"] == .bool(false))
        #expect(ok["content"] == .array([.object(["type": .string("text"), "text": .string("hi")])]))

        let missing = try result(try await reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#))
        #expect(missing["isError"] == .bool(true))
        #expect(missing["content"] == .array([.object(["type": .string("text"), "text": .string("'text' is required.")])]))

        let failed = try result(try await reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"boom"}}"#))
        #expect(failed["isError"] == .bool(true))
        guard case .array(let content)? = failed["content"], case .object(let first) = content[0],
            case .string(let text)? = first["text"]
        else { Issue.record("no text"); return }
        #expect(text.hasPrefix("described: "))
    }

    @Test func runAnswersEveryRequestLine() async throws {
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        let input = AsyncStream<String> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        let written = Mutex<[String]>([])
        try await server.run(lines: input) { line in written.withLock { $0.append(line) } }
        let ids = try written.withLock { $0 }.map { try Fixtures.object($0)["id"] }
        #expect(Set(ids.compactMap { $0.flatMap { if case .int(let id) = $0 { id } else { nil } } }) == [1, 2])
    }
}

@Suite struct LineDiffTests {
    @Test func equalTextsHaveNoDiff() {
        #expect(LineDiff.unified("a\nb\n", "a\nb\n", oldLabel: "old", newLabel: "new") == "")
    }

    @Test func unifiedHunks() {
        let old = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 2\n", with: "line two\n") + "line 13\n"
        #expect(LineDiff.unified(old, new, oldLabel: "old", newLabel: "new") == """
            --- old
            +++ new
            @@ -1,5 +1,5 @@
             line 1
            -line 2
            +line two
             line 3
             line 4
             line 5
            @@ -10,3 +10,4 @@
             line 10
             line 11
             line 12
            +line 13

            """)
    }

    @Test func fromNothing() {
        #expect(LineDiff.unified("", "a\n", oldLabel: "none", newLabel: "proposed") == "--- none\n+++ proposed\n@@ -0,0 +1 @@\n+a\n")
    }
}
