import Foundation

/// JSON form: `"global"`, `{"app": "<uuid>"}` or `{"group": "<uuid>"}` (a variable group's).
public enum VariableScope: Codable, Hashable, Sendable {
    case global
    case app(UUID)
    case group(UUID)

    private enum CodingKeys: String, CodingKey { case app, group }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            guard text == "global" else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unknown scope '\(text)'")
            }
            self = .global
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let group = try container.decodeIfPresent(UUID.self, forKey: .group) {
            self = .group(group)
        } else {
            self = .app(try container.decode(UUID.self, forKey: .app))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .global:
            var container = encoder.singleValueContainer()
            try container.encode("global")
        case .app(let id):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .app)
        case .group(let id):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .group)
        }
    }
}

public struct VariableSummary: Codable, Equatable, Sendable {
    public var scope: VariableScope
    public var name: String
    public var isSecret: Bool
    public var asFile: Bool
    /// The workflows of the app that get it, sorted; empty means all of them. Only app variables have any.
    public var workflows: [String]
    public var updatedAt: Date

    public init(
        scope: VariableScope, name: String, isSecret: Bool, asFile: Bool, workflows: [String] = [], updatedAt: Date
    ) {
        self.scope = scope
        self.name = name
        self.isSecret = isSecret
        self.asFile = asFile
        self.workflows = workflows
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case scope, name, isSecret, asFile, workflows, updatedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(VariableScope.self, forKey: .scope)
        name = try container.decode(String.self, forKey: .name)
        isSecret = try container.decode(Bool.self, forKey: .isSecret)
        asFile = try container.decode(Bool.self, forKey: .asFile)
        workflows = try container.decodeIfPresent([String].self, forKey: .workflows) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public struct VariableInput: Codable, Equatable, Sendable {
    public var value: String
    public var isSecret: Bool
    public var asFile: Bool
    /// For an app variable: the workflows that get it; empty (or absent) means all of them.
    public var workflows: [String]

    public init(value: String, isSecret: Bool = false, asFile: Bool = false, workflows: [String] = []) {
        self.value = value
        self.isSecret = isSecret
        self.asFile = asFile
        self.workflows = workflows
    }

    private enum CodingKeys: String, CodingKey { case value, isSecret, asFile, workflows }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        asFile = try container.decodeIfPresent(Bool.self, forKey: .asFile) ?? false
        workflows = try container.decodeIfPresent([String].self, forKey: .workflows) ?? []
    }
}

/// `PATCH` of one app variable: what is present changes, the rest stays. `workflows` empty means all workflows.
public struct VariableUpdate: Codable, Equatable, Sendable {
    public var workflows: [String]?
    public var value: String?
    public var isSecret: Bool?
    public var asFile: Bool?

    public init(workflows: [String]? = nil, value: String? = nil, isSecret: Bool? = nil, asFile: Bool? = nil) {
        self.workflows = workflows
        self.value = value
        self.isSecret = isSecret
        self.asFile = asFile
    }
}

/// A named set of variables that apps link (Settings → Variable Groups).
public struct VariableGroup: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var variables: [VariableSummary]
    /// The apps that link it, by name.
    public var apps: [VariableGroupUse]

    public init(id: UUID, name: String, createdAt: Date, variables: [VariableSummary] = [], apps: [VariableGroupUse] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.variables = variables
        self.apps = apps
    }
}

/// An app that links a group, and for which of its workflows (empty: all).
public struct VariableGroupUse: Codable, Equatable, Sendable {
    public var appID: UUID
    public var slug: String
    public var name: String
    public var workflows: [String]

    public init(appID: UUID, slug: String, name: String, workflows: [String]) {
        self.appID = appID
        self.slug = slug
        self.name = name
        self.workflows = workflows
    }
}

/// A group as one app links it. An app's links are listed in precedence order: the first wins a name two share.
public struct AppVariableGroupLink: Codable, Equatable, Sendable {
    public var groupID: UUID
    public var name: String
    /// The app's workflows that get the group; empty means all of them.
    public var workflows: [String]
    public var variables: [VariableSummary]

    public init(groupID: UUID, name: String, workflows: [String], variables: [VariableSummary]) {
        self.groupID = groupID
        self.name = name
        self.workflows = workflows
        self.variables = variables
    }
}

public struct VariableGroupRequest: Codable, Equatable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct LinkVariableGroupRequest: Codable, Equatable, Sendable {
    public var workflows: [String]
    public init(workflows: [String] = []) { self.workflows = workflows }

    private enum CodingKeys: String, CodingKey { case workflows }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflows = try container.decodeIfPresent([String].self, forKey: .workflows) ?? []
    }
}

/// Where a job's variable comes from.
public struct VariableSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case global, group, app }
    public var kind: Kind
    /// The group's name, for `group`.
    public var group: String?
    /// The workflows the app variable or the group's link is limited to; empty means all of them.
    public var workflows: [String]

    public init(kind: Kind, group: String? = nil, workflows: [String] = []) {
        self.kind = kind
        self.group = group
        self.workflows = workflows
    }
}

/// A name a job gets, without its value: where it comes from, and what it replaces there.
public struct EffectiveVariable: Codable, Equatable, Sendable {
    public var name: String
    public var isSecret: Bool
    public var asFile: Bool
    public var source: VariableSource
    /// Lower layers that define the name too, most specific first.
    public var replaces: [VariableSource]

    public init(name: String, isSecret: Bool, asFile: Bool, source: VariableSource, replaces: [VariableSource] = []) {
        self.name = name
        self.isSecret = isSecret
        self.asFile = asFile
        self.source = source
        self.replaces = replaces
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
