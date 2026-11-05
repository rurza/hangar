import Foundation
import HangarClient
import HangarCore

/// One MCP tool: its schema and hints as `tools/list` shows them, and the handler `tools/call` runs.
public struct MCPTool: Sendable {
    /// MCP tool annotations: hints for the client, which may ask the user before an outward-facing call.
    public struct Hints: Sendable, Equatable {
        public var readOnly: Bool
        public var destructive: Bool
        public var idempotent: Bool
        /// It reaches beyond Hangar (GitHub, App Store Connect).
        public var openWorld: Bool

        public static let read = Hints(readOnly: true, destructive: false, idempotent: true, openWorld: false)
        public static let readExternal = Hints(readOnly: true, destructive: false, idempotent: true, openWorld: true)
    }

    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var hints: Hints
    public var handler: @Sendable (ToolArguments) async throws -> ToolOutput

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue, hints: Hints,
        handler: @escaping @Sendable (ToolArguments) async throws -> ToolOutput
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.hints = hints
        self.handler = handler
    }

    /// The entry of `tools/list`.
    var listing: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(hints.readOnly),
                "destructiveHint": .bool(hints.destructive),
                "idempotentHint": .bool(hints.idempotent),
                "openWorldHint": .bool(hints.openWorld),
            ]),
        ])
    }
}

/// What a tool returns: text for the agent (JSON or a log tail).
public struct ToolOutput: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    /// `value` as pretty JSON with sorted keys, dates in ISO 8601.
    public static func json(_ value: some Encodable) throws -> ToolOutput {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ToolOutput(text: String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

/// A failure the agent should read and act on (a missing argument, a refused confirmation): returned as a tool
/// result with `isError`, not a protocol error.
public struct ToolError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The `arguments` of a `tools/call`, with typed accessors that throw `ToolError`s naming the argument.
public struct ToolArguments: Sendable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) { self.values = values }

    public func string(_ name: String) throws -> String {
        guard let value = try optionalString(name) else { throw ToolError("'\(name)' is required.") }
        return value
    }

    /// Nil when absent, null or empty after trimming.
    public func optionalString(_ name: String) throws -> String? {
        switch values[name] {
        case nil, .null: return nil
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: throw ToolError("'\(name)' must be a string.")
        }
    }

    /// The string exactly as given (YAML keeps its indentation); nil when absent or null.
    public func rawString(_ name: String) throws -> String? {
        switch values[name] {
        case nil, .null: return nil
        case .string(let text): return text
        default: throw ToolError("'\(name)' must be a string.")
        }
    }

    public func bool(_ name: String, default fallback: Bool) throws -> Bool {
        switch values[name] {
        case nil, .null: return fallback
        case .bool(let flag): return flag
        default: throw ToolError("'\(name)' must be true or false.")
        }
    }

    /// Clamped to `range`; `fallback` when absent.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        switch values[name] {
        case nil, .null: return fallback
        case .int(let number): return min(max(number, range.lowerBound), range.upperBound)
        case .double(let number) where number.rounded() == number:
            return min(max(Int(number), range.lowerBound), range.upperBound)
        default: throw ToolError("'\(name)' must be an integer.")
        }
    }

    public func uuid(_ name: String) throws -> UUID {
        guard let id = try optionalUUID(name) else { throw ToolError("'\(name)' is required.") }
        return id
    }

    public func optionalUUID(_ name: String) throws -> UUID? {
        guard let text = try optionalString(name) else { return nil }
        guard let id = UUID(uuidString: text) else { throw ToolError("'\(name)' must be a UUID, such as one get_build returns.") }
        return id
    }

    public func object(_ name: String) throws -> JSONValue? {
        switch values[name] {
        case nil, .null: return nil
        case .object(let object): return .object(object)
        default: throw ToolError("'\(name)' must be an object.")
        }
    }
}

/// JSON Schema fragments for tool inputs.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    static func string(_ description: String, oneOf values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int, maximum: Int) -> JSONValue {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum),
        ])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func anyObject(_ description: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(description)])
    }

    static let app = string("The app's slug (from list_apps) or UUID.")
}
