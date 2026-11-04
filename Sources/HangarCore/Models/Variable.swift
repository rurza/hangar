import Foundation

/// JSON form: `"global"` or `{"app": "<uuid>"}`.
public enum VariableScope: Codable, Hashable, Sendable {
    case global
    case app(UUID)

    private enum CodingKeys: String, CodingKey { case app }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            guard text == "global" else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unknown scope '\(text)'")
            }
            self = .global
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .app(try container.decode(UUID.self, forKey: .app))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .global:
            var container = encoder.singleValueContainer()
            try container.encode("global")
        case .app(let id):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .app)
        }
    }
}

public struct VariableSummary: Codable, Equatable, Sendable {
    public var scope: VariableScope
    public var name: String
    public var isSecret: Bool
    public var asFile: Bool
    public var updatedAt: Date

    public init(scope: VariableScope, name: String, isSecret: Bool, asFile: Bool, updatedAt: Date) {
        self.scope = scope
        self.name = name
        self.isSecret = isSecret
        self.asFile = asFile
        self.updatedAt = updatedAt
    }
}

public struct VariableInput: Codable, Equatable, Sendable {
    public var value: String
    public var isSecret: Bool
    public var asFile: Bool

    public init(value: String, isSecret: Bool = false, asFile: Bool = false) {
        self.value = value
        self.isSecret = isSecret
        self.asFile = asFile
    }
}

public struct EnvEntry: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var isSecret: Bool
    public var asFile: Bool

    public init(name: String, value: String, isSecret: Bool = false, asFile: Bool = false) {
        self.name = name
        self.value = value
        self.isSecret = isSecret
        self.asFile = asFile
    }
}
