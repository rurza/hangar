import Foundation

/// Writes a `WorkflowFile` as `.hangar.yml` in the documented shape (the same the web editor's `workflowToYAML`
/// writes): versions and team IDs quoted, other strings plain unless YAML would read them differently.
public enum WorkflowYAMLWriter {
    public static func yaml(_ file: WorkflowFile) -> String {
        var lines = ["version: \(file.version)", "workflows:"]
        for name in file.workflows.keys.sorted() {
            let workflow = file.workflows[name]!
            lines.append("  \(scalar(name)):")
            if let project = workflow.project { lines.append("    project: \(scalar(project))") }
            if let workspace = workflow.workspace { lines.append("    workspace: \(scalar(workspace))") }
            lines.append("    xcode: \(quoted(workflow.xcode))")
            if let team = workflow.teamID { lines.append("    team: \(quoted(team))") }
            if !workflow.tools.isEmpty { lines.append("    tools: [\(workflow.tools.map(scalar).joined(separator: ", "))]") }
            if let start = workflow.start {
                switch start.manual.branches {
                case .any: lines.append("    start: { manual: { branches: any } }")
                case .patterns(let names):
                    lines.append("    start: { manual: { branches: [\(names.map(scalar).joined(separator: ", "))] } }")
                }
            }
            lines.append("    actions:")
            for action in workflow.actions { lines.append("      - " + Self.action(action)) }
            if !workflow.postActions.isEmpty {
                lines.append("    post-actions:")
                for spec in workflow.postActions {
                    guard !spec.settings.isEmpty || spec.requiresApproval else {
                        lines.append("      - \(scalar(spec.name))")
                        continue
                    }
                    lines.append("      - \(scalar(spec.name)):")
                    if spec.requiresApproval { lines.append("          requires-approval: true") }
                    for key in spec.settings.keys.sorted() {
                        lines.append("          \(scalar(key)): \(value(spec.settings[key]!))")
                    }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Archives in the flat form, tests as `test: { ... }` with only the fields they set.
    private static func action(_ action: WorkflowAction) -> String {
        var fields = ["scheme: \(scalar(action.scheme))", "platform: \(action.platform.rawValue)"]
        switch action.kind {
        case .archive:
            fields.append("export: \((action.export ?? .appStoreConnect).rawValue)")
            return "{ \(fields.joined(separator: ", ")) }"
        case .test:
            if let destination = action.destination { fields.append("destination: \(scalar(destination))") }
            if let testPlan = action.testPlan { fields.append("test-plan: \(scalar(testPlan))") }
            return "test: { \(fields.joined(separator: ", ")) }"
        }
    }

    private static func value(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): scalar(text)
        case .int(let number): "\(number)"
        case .double(let number): "\(number)"
        case .bool(let flag): flag ? "true" : "false"
        case .null: "null"
        case .array(let items): "[\(items.map(Self.value).joined(separator: ", "))]"
        case .object(let map): "{ \(map.keys.sorted().map { "\(scalar($0)): \(Self.value(map[$0]!))" }.joined(separator: ", ")) }"
        }
    }

    private static let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "y", "n", "~"]

    /// Plain when it is a safe run of letters, digits and `._/-` that YAML reads back as the same string.
    static func scalar(_ text: String) -> String {
        let safe = !text.isEmpty
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._/-".unicodeScalars.contains($0)) }
            && !reserved.contains(text.lowercased())
            && !(text.first!.isNumber || text.first == "-" || text.first == "." )
        return safe ? text : quoted(text)
    }

    /// A double-quoted YAML string; control characters and YAML's extra line breaks are escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85 || scalar.value == 0x2028
                    || scalar.value == 0x2029 || scalar.value == 0xFEFF
                {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
