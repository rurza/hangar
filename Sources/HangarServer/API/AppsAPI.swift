import Foundation
import HangarCore
import Hummingbird

extension HangarServerApp {
    func addAppRoutes(to api: APIGroup) {
        api.get("apps") { _, _ in
            let all = try apps.all()
            appIconBackfill.fill(all)  // apps without an icon; the UI shows a stored one on its next load
            return try Response.json(all)
        }
        api.post("apps") { request, context in
            let input = try await request.decode(as: CreateAppRequest.self, context: context)
            let app = try apps.create(input)
            appIconBackfill.fill([app])  // only when no icon was given
            return try Response.json(app, status: .created)
        }
        api.get("apps/:id") { _, context in try Response.json(app(context)) }
        api.delete("apps/:id") { _, context in
            try apps.delete(id: app(context).id)
            return Response(status: .noContent)
        }
        api.get("apps/:id/workflows") { request, context in
            let app = try app(context)
            guard let ref = request.uri.queryParameters.get("ref"), !ref.isEmpty else {
                throw APIError(code: "invalid_request", message: "The 'ref' query parameter is required.")
            }
            let (commit, file, source) = try await buildService.workflows(app: app, ref: ref)
            return try Response.json(WorkflowsResponse(commit: commit, workflows: file, source: source))
        }
    }
}
