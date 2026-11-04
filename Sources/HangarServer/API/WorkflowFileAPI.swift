import Foundation
import HangarCore
import Hummingbird

/// The workflow an app defines in Hangar. A body is parsed before it is stored, so a stored file is always valid.
extension HangarServerApp {
    static let maxWorkflowFileBytes = 64 * 1024

    func addWorkflowFileRoutes(to api: APIGroup) {
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
            guard let stored = try workflowFiles.get(appID: app.id) else { throw Self.workflowFileNotFound(app) }
            return try Response.json(try Self.storedFile(stored))
        }
        api.delete("apps/:id/workflow-file") { _, context in
            try workflowFiles.delete(appID: app(context).id)
            return Response(status: .noContent)
        }
    }

    private static func workflowFileNotFound(_ app: App) -> APIError {
        APIError(code: "workflow_file_not_found", message: "\(app.name) has no workflow defined in Hangar.")
    }

    private static func storedFile(_ stored: (yaml: String, updatedAt: Date)) throws -> StoredWorkflowFile {
        StoredWorkflowFile(yaml: stored.yaml, workflows: try WorkflowFileParser.parse(stored.yaml), updatedAt: stored.updatedAt)
    }
}
