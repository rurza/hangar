import Foundation
import HangarClient
import HangarCore

extension HangarTools {
    /// The workflow file an edit starts from and a diff is taken against.
    struct CurrentWorkflowFile {
        var yaml: String
        var file: WorkflowFile?
        /// "stored in Hangar", "repository .hangar.yml at abc1234 (as Hangar reads it)", "none".
        var label: String
    }

    func currentWorkflowFile(app: String) async throws -> CurrentWorkflowFile {
        do {
            let stored = try await api.workflowFile(app: app)
            return CurrentWorkflowFile(yaml: stored.yaml, file: stored.workflows, label: "stored in Hangar")
        } catch HangarAPIError.server(let error, _) where error.code == "workflow_file_not_found" {}
        do {
            let response = try await api.workflows(app: app, ref: nil)
            return CurrentWorkflowFile(
                yaml: WorkflowYAMLWriter.yaml(response.workflows), file: response.workflows,
                label: "repository \(WorkflowFile.path) at \(response.commit.prefix(7)) (as Hangar reads it)")
        } catch HangarAPIError.server(let error, _)
            where ["workflow_file_missing", "invalid_workflow_file"].contains(error.code)
        {
            return CurrentWorkflowFile(yaml: "", file: nil, label: "none")
        }
    }

    func setWorkflow(_ arguments: ToolArguments) async throws -> ToolOutput {
        let app = try arguments.string("app")
        let dryRun = try arguments.bool("dry_run", default: true)
        let yamlArgument = try arguments.rawString("yaml")
        let name = try arguments.optionalString("workflow_name")
        let workflowArgument = try arguments.object("workflow")
        let remove = try arguments.optionalString("remove")
        let modes = [yamlArgument != nil, name != nil || workflowArgument != nil, remove != nil].filter { $0 }.count
        guard modes == 1 else {
            throw ToolError("Give exactly one of: yaml, workflow_name with workflow, or remove.")
        }
        let current = try await currentWorkflowFile(app: app)

        let proposed: String
        if let yamlArgument {
            proposed = yamlArgument.hasSuffix("\n") ? yamlArgument : yamlArgument + "\n"
        } else if let remove {
            guard var file = current.file, file.workflows[remove] != nil else {
                throw ToolError("There is no workflow '\(remove)' (current file: \(current.label)).")
            }
            file.workflows[remove] = nil
            guard !file.workflows.isEmpty else {
                throw ToolError("Removing '\(remove)' would leave no workflows; use clear_workflow_file to drop the stored file instead.")
            }
            proposed = WorkflowYAMLWriter.yaml(file)
        } else {
            guard let name, let workflowArgument else { throw ToolError("workflow_name and workflow go together.") }
            let workflow: Workflow
            do {
                let normalized = Self.normalizedWorkflowJSON(workflowArgument)
                workflow = try JSONCoding.decoder.decode(Workflow.self, from: try JSONEncoder().encode(normalized))
            } catch {
                throw ToolError("'workflow' is not a valid workflow: \(Self.decodingProblem(error)). See the tool's description for its shape.")
            }
            var file = current.file ?? WorkflowFile(version: 1, workflows: [:])
            file.workflows[name] = workflow
            proposed = WorkflowYAMLWriter.yaml(file)
        }

        struct Result: Encodable {
            var valid: Bool
            var applied: Bool
            var dryRun: Bool
            var problems: [String]
            var warnings: [String]
            var current: String
            var diff: String
            var workflows: [String]
        }
        let parsed: WorkflowFile
        do {
            parsed = try WorkflowFileParser.parse(proposed)
        } catch {
            var output = try ToolOutput.json(
                Result(
                    valid: false, applied: false, dryRun: dryRun, problems: [error.description], warnings: [],
                    current: current.label,
                    diff: LineDiff.unified(current.yaml, proposed, oldLabel: current.label, newLabel: "proposed"),
                    workflows: []))
            output.isError = true
            return output
        }
        if proposed.utf8.count > 64 * 1024 {
            throw ToolError("The workflow file is \(proposed.utf8.count / 1024) KB; Hangar stores at most 64 KB.")
        }
        let warnings = await workflowWarnings(parsed, app: app)
        let diff = LineDiff.unified(current.yaml, proposed, oldLabel: current.label, newLabel: "proposed")
        var applied = false
        if !dryRun {
            _ = try await api.setWorkflowFile(app: app, yaml: proposed)
            applied = true
        }
        return try .json(
            Result(
                valid: true, applied: applied, dryRun: dryRun, problems: [], warnings: warnings, current: current.label,
                diff: diff.isEmpty ? "(no changes)" : diff, workflows: parsed.workflows.keys.sorted()))
    }

    /// What would go wrong later: TestFlight groups App Store Connect does not have, schemes the repository does not
    /// have, approvals Hangar cannot give. Each check that cannot be made says so instead.
    func workflowWarnings(_ file: WorkflowFile, app: String) async -> [String] {
        var warnings: [String] = []
        let workflows = file.workflows.sorted { $0.key < $1.key }
        let wantedGroups = workflows.flatMap { name, workflow in
            workflow.postActions.filter { $0.name == TestFlightSettings.actionName }.flatMap { spec in
                ((try? TestFlightSettings(settings: spec.settings))?.groups ?? []).map { (name, $0) }
            }
        }
        if !wantedGroups.isEmpty {
            do {
                let existing = Set(try await api.betaGroups(app: app).map(\.name))
                for (workflow, group) in wantedGroups where !existing.contains(group) {
                    warnings.append(
                        "Workflow '\(workflow)': App Store Connect has no TestFlight group '\(group)' for this app; the testflight step will fail. Create it (create_testflight_group, with the user's consent) or fix the name.")
                }
            } catch {
                warnings.append("Could not check the TestFlight groups: \(Self.describe(error, server: server))")
            }
        }
        do {
            let schemes = Set(try await api.workflowSuggestion(app: app).schemes.map(\.name))
            for (name, workflow) in workflows {
                for action in workflow.actions where !schemes.contains(action.scheme) {
                    warnings.append(
                        "Workflow '\(name)': the repository's default branch has no scheme '\(action.scheme)' (found: \(schemes.sorted().joined(separator: ", "))).")
                }
            }
        } catch {
            warnings.append("Could not check the schemes against the repository: \(Self.describe(error, server: server))")
        }
        for (name, workflow) in workflows {
            for spec in workflow.postActions where spec.requiresApproval {
                warnings.append("Workflow '\(name)': post-action '\(spec.name)' requires approval, which Hangar does not support yet; deploys will be refused.")
            }
        }
        return warnings
    }

    func startBuild(_ arguments: ToolArguments) async throws -> ToolOutput {
        let app = try arguments.string("app")
        let workflowName = try arguments.string("workflow")
        let machine = try arguments.optionalString("machine")
        guard try arguments.bool("confirm", default: false) else {
            throw ToolError(
                "start_build reserves a build number and can upload to App Store Connect and TestFlight; call it with confirm: true once the user asked for this build.")
        }
        let allowBlocked = try arguments.bool("allow_blocked", default: false)
        var warnings: [String] = []

        var ref = try arguments.optionalString("ref")
        let workflows = try await api.workflows(app: app, ref: ref)
        guard let workflow = workflows.workflows.workflows[workflowName] else {
            let names = workflows.workflows.workflows.keys.sorted().joined(separator: ", ")
            throw ToolError("No workflow '\(workflowName)'; available: \(names).")
        }
        if ref == nil {
            if let suggested = workflow.suggestedBranch {
                ref = suggested
            } else {
                ref = try await api.branches(app: app).defaultBranch
            }
        }
        guard let ref else { throw ToolError("The repository has no default branch; pass ref.") }
        if !workflow.sourceBranches.matches(ref), !Self.looksLikeCommit(ref) {
            warnings.append("'\(ref)' is not one of the branches workflow '\(workflowName)' starts from; building it anyway.")
        }

        let check = try await api.deployCheck(app: app, workflow: workflowName, ref: ref, machine: machine)
        if !check.canDeploy && !allowBlocked {
            let reasons = check.blocking.map { action in
                action.reasons.isEmpty
                    ? "\(action.action): no build Mac is enrolled" + (machine.map { " named \($0)" } ?? "")
                    : action.action + ": "
                        + action.reasons.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value.joined(separator: ", ")))" }
                        .joined(separator: "; ")
            }
            throw ToolError(
                "No Mac can run every action now, so the build was not started:\n- " + reasons.joined(separator: "\n- ")
                    + "\nFix the machines, or pass allow_blocked: true to queue it anyway.")
        }
        for action in check.warnings {
            let reasons = Set(action.reasons.values.flatMap { $0 }).sorted().joined(separator: ", ")
            warnings.append("\(action.action) will wait: \(reasons)")
        }

        let build = try await api.deploy(DeployRequest(app: app, workflow: workflowName, ref: ref, machine: machine))
        struct Started: Encodable {
            var warnings: [String]
            var postActions: [String]
            var build: Views.BuildView
            var next: String
        }
        return try .json(
            Started(
                warnings: warnings, postActions: workflow.postActions.map(Self.describe),
                build: try await view(build, excerpts: false),
                next: "Follow it with wait_for_build or get_build (build_id \(build.id.uuidString))."))
    }

    /// The API's `Workflow` JSON with the YAML spellings agents often use (`team`, `post-actions`) mapped and the
    /// optional lists defaulted, so a minimal workflow decodes.
    static func normalizedWorkflowJSON(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        for (alias, key) in [("team", "teamID"), ("post-actions", "postActions"), ("post_actions", "postActions")]
        where fields[key] == nil {
            if let aliased = fields.removeValue(forKey: alias) { fields[key] = aliased }
        }
        if fields["tools"] == nil { fields["tools"] = .array([]) }
        if fields["postActions"] == nil { fields["postActions"] = .array([]) }
        if case .array(let specs)? = fields["postActions"] {
            fields["postActions"] = .array(specs.map { spec in
                switch spec {
                case .string(let name): return .object(["name": .string(name), "settings": .object([:]), "requiresApproval": .bool(false)])
                case .object(var spec):
                    if spec["settings"] == nil { spec["settings"] = .object([:]) }
                    if spec["requiresApproval"] == nil { spec["requiresApproval"] = .bool(false) }
                    return .object(spec)
                default: return spec
                }
            })
        }
        return .object(fields)
    }

    static func looksLikeCommit(_ ref: String) -> Bool {
        (7...40).contains(ref.count) && ref.allSatisfy(\.isHexDigit)
    }

    static func decodingProblem(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return keys.isEmpty ? "" : " at \(keys)"
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing '\(key.stringValue)'\(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription)\(path(context))"
        @unknown default: return "\(error)"
        }
    }
}
