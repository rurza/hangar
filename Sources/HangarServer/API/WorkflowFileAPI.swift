import Foundation
import HangarCore
import Hummingbird

/// The workflow an app defines in Hangar. A body is parsed before it is stored, so a stored file is always valid.
extension HangarServerApp {
    static let maxWorkflowFileBytes = 64 * 1024

    func addWorkflowFileRoutes(to api: APIGroup) {
        api.get("apps/:id/workflow-source") { _, context in try Response.json(try await workflowSource(app(context))) }
        api.get("apps/:id/workflow-file") { _, context in
            let app = try app(context)
            guard let stored = try workflowFiles.get(appID: app.id) else { throw Self.workflowFileNotFound(app) }
            return try Response.json(try Self.storedFile(stored))
        }
        api.put("apps/:id/workflow-file") { request, context in
            let app = try app(context)
            let input = try await request.decode(as: PutWorkflowFileRequest.self, context: context)
            guard input.yaml.utf8.count <= Self.maxWorkflowFileBytes else {
                throw APIError(
                    code: "invalid_workflow_file",
                    message: "The workflow file is too large (the limit is \(Self.maxWorkflowFileBytes / 1024) KB).")
            }
            _ = try WorkflowFileParser.parse(input.yaml)
            try workflowFiles.set(appID: app.id, yaml: input.yaml)
            repositoryWorkflowFiles.forget(app.id)
            guard let stored = try workflowFiles.get(appID: app.id) else { throw Self.workflowFileNotFound(app) }
            return try Response.json(try Self.storedFile(stored))
        }
        api.delete("apps/:id/workflow-file") { _, context in
            let app = try app(context)
            try workflowFiles.delete(appID: app.id)
            repositoryWorkflowFiles.forget(app.id)
            return Response(status: .noContent)
        }
    }

    /// Where builds take the workflow from. The repository is asked (commit, then the file) only without a stored
    /// workflow, and its answer is cached; a GitHub failure reads as unknown and is not cached.
    func workflowSource(_ app: App) async throws -> WorkflowSourceStatus {
        if try workflowFiles.get(appID: app.id) != nil { return WorkflowSourceStatus(stored: true, repositoryHasWorkflowFile: nil) }
        if let present = repositoryWorkflowFiles.get(app.id) {
            return WorkflowSourceStatus(stored: false, repositoryHasWorkflowFile: present)
        }
        do {
            let present = try await withAppToken(app) { token in
                let commit = try await repositoryDetector.sourceHost.resolveCommit(repoURL: app.repoURL, ref: "HEAD", token: token)
                return try await repositoryDetector.sourceHost.readFile(
                    repoURL: app.repoURL, commit: commit, path: WorkflowFile.path, token: token) != nil
            }
            repositoryWorkflowFiles.set(app.id, present: present)
            return WorkflowSourceStatus(stored: false, repositoryHasWorkflowFile: present)
        } catch {
            return WorkflowSourceStatus(stored: false, repositoryHasWorkflowFile: nil)
        }
    }

    private static func workflowFileNotFound(_ app: App) -> APIError {
        APIError(code: "workflow_file_not_found", message: "\(app.name) has no workflow defined in Hangar.")
    }

    private static func storedFile(_ stored: (yaml: String, updatedAt: Date)) throws -> StoredWorkflowFile {
        StoredWorkflowFile(yaml: stored.yaml, workflows: try WorkflowFileParser.parse(stored.yaml), updatedAt: stored.updatedAt)
    }
}
