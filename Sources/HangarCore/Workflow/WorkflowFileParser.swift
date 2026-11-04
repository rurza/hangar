import Yams
import Foundation

public enum WorkflowFileParser {
    public static func parse(_ yaml: String) throws(WorkflowFileError) -> WorkflowFile {
        let root: JSONValue
        do {
            guard let loaded = try Yams.load(yaml: yaml) else { throw WorkflowFileError.invalidYAML("the file is empty") }
            root = try convert(loaded)
        } catch let error as WorkflowFileError {
            throw error
        } catch {
            throw .invalidYAML("\(error)")
        }
        guard case .object(let top) = root else { throw .invalidYAML("the top level must be a map") }

        guard let versionValue = top["version"] else { throw .invalidYAML("missing 'version'") }
        guard case .int(let version) = versionValue else { throw .invalidYAML("'version' must be an integer") }
        guard version == 1 else { throw .unsupportedVersion(version) }

        guard case .object(let rawWorkflows)? = top["workflows"] else { throw .invalidYAML("missing 'workflows' map") }
        guard !rawWorkflows.isEmpty else { throw .noWorkflows }

        var workflows: [String: Workflow] = [:]
        for name in rawWorkflows.keys.sorted() {
            workflows[name] = try workflow(named: name, from: rawWorkflows[name]!)
        }
        return WorkflowFile(version: version, workflows: workflows)
    }

    // MARK: - Mapping

    private static func workflow(named name: String, from value: JSONValue) throws(WorkflowFileError) -> Workflow {
        guard case .object(let map) = value else { throw .invalidYAML("workflow '\(name)' must be a map") }
        try rejectUnknownKeys(
            map, allowed: ["project", "workspace", "xcode", "team", "tools", "actions", "post-actions"],
            context: "workflow '\(name)'")

        let project = try optionalString(map["project"], key: "project", workflow: name)
        let workspace = try optionalString(map["workspace"], key: "workspace", workflow: name)
        if project != nil, workspace != nil { throw .projectAndWorkspace(workflow: name) }
        if project == nil, workspace == nil { throw .noProject(workflow: name) }

        guard let xcode = try optionalString(map["xcode"], key: "xcode", workflow: name) else {
            throw .invalidYAML("workflow '\(name)' is missing 'xcode'")
        }
        let team = try optionalString(map["team"], key: "team", workflow: name)
        let tools = try stringList(map["tools"], key: "tools", workflow: name)

        guard case .array(let rawActions)? = map["actions"], !rawActions.isEmpty else { throw .noActions(workflow: name) }
        let actions = try rawActions.map { raw throws(WorkflowFileError) in try archiveAction(raw, workflow: name) }

        var postActions: [PostActionSpec] = []
        if let rawPost = map["post-actions"] {
            guard case .array(let entries) = rawPost else {
                throw .invalidYAML("workflow '\(name)': 'post-actions' must be a list")
            }
            for entry in entries {
                let spec = try postAction(entry, workflow: name)
                try PostActionCatalog.validate(spec, workflow: name)
                postActions.append(spec)
            }
        }
        return Workflow(
            project: project, workspace: workspace, xcode: xcode, teamID: team,
            tools: tools, actions: actions, postActions: postActions
        )
    }

    private static func archiveAction(_ value: JSONValue, workflow: String) throws(WorkflowFileError) -> ArchiveAction {
        guard case .object(let map) = value else { throw .invalidYAML("workflow '\(workflow)': each action must be a map") }
        try rejectUnknownKeys(map, allowed: ["scheme", "platform", "export"], context: "an action in workflow '\(workflow)'")
        func required(_ key: String) throws(WorkflowFileError) -> String {
            guard let text = try optionalString(map[key], key: key, workflow: workflow) else {
                throw .invalidYAML("workflow '\(workflow)': action is missing '\(key)'")
            }
            return text
        }
        let scheme = try required("scheme")
        let platformName = try required("platform")
        let exportName = try required("export")
        guard let platform = Platform(rawValue: platformName) else { throw .unknownPlatform(platformName) }
        guard let export = ExportMethod(rawValue: exportName) else { throw .unknownExportMethod(exportName) }
        return ArchiveAction(scheme: scheme, platform: platform, export: export)
    }

    private static func postAction(_ value: JSONValue, workflow: String) throws(WorkflowFileError) -> PostActionSpec {
        switch value {
        case .string(let name):
            return PostActionSpec(name: name)
        case .object(let map):
            guard map.count == 1, let (name, raw) = map.first else {
                throw .invalidYAML("workflow '\(workflow)': a post-action must be a single 'name: settings' entry")
            }
            var settings: [String: JSONValue]
            switch raw {
            case .null: settings = [:]
            case .object(let object): settings = object
            default: throw .invalidPostActionSettings(name: name, reason: "settings must be a map, not a \(raw.kind)")
            }
            var requiresApproval = false
            if let flag = settings.removeValue(forKey: "requires-approval") {
                guard case .bool(let value) = flag else {
                    throw .invalidPostActionSettings(name: name, reason: "'requires-approval' must be true or false")
                }
                requiresApproval = value
            }
            return PostActionSpec(name: name, settings: settings, requiresApproval: requiresApproval)
        default:
            throw .invalidYAML("workflow '\(workflow)': a post-action must be a name or a 'name: settings' entry")
        }
    }

    private static func rejectUnknownKeys(
        _ map: [String: JSONValue], allowed: Set<String>, context: String
    ) throws(WorkflowFileError) {
        if let unknown = map.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw .invalidYAML("\(context) has unknown key '\(unknown)'")
        }
    }

    private static func optionalString(_ value: JSONValue?, key: String, workflow: String) throws(WorkflowFileError) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        // Numbers are rejected: YAML would change `27.10` to 27.1 and drop leading zeros.
        case .int, .double:
            throw .invalidYAML("workflow '\(workflow)': '\(key)' must be a quoted string, e.g. \(key): \"...\"")
        default: throw .invalidYAML("workflow '\(workflow)': '\(key)' must be a string")
        }
    }

    private static func stringList(_ value: JSONValue?, key: String, workflow: String) throws(WorkflowFileError) -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value else { throw .invalidYAML("workflow '\(workflow)': '\(key)' must be a list") }
        return try items.map { item throws(WorkflowFileError) in
            guard case .string(let text) = item else {
                throw .invalidYAML("workflow '\(workflow)': '\(key)' must contain only strings")
            }
            return text
        }
    }

    // MARK: - Yams -> JSONValue

    private static func convert(_ any: Any) throws(WorkflowFileError) -> JSONValue {
        switch any {
        case let value as Bool: return .bool(value)
        case let value as Int: return .int(value)
        case let value as Double: return .double(value)
        case let value as String: return .string(value)
        case is NSNull: return .null
        case let value as [Any]:
            return .array(try value.map { element throws(WorkflowFileError) in try convert(element) })
        case let value as [AnyHashable: Any]:
            var object: [String: JSONValue] = [:]
            for (key, element) in value {
                guard let key = key as? String else { throw .invalidYAML("map keys must be strings, found '\(key)'") }
                object[key] = try convert(element)
            }
            return .object(object)
        default:
            throw .invalidYAML("unsupported value '\(any)'")
        }
    }
}
