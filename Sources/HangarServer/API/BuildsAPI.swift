import Foundation
import HangarCore
import Hummingbird

extension HangarServerApp {
    static let defaultBuildLimit = 50
    static let maxBuildLimit = 200

    func addBuildRoutes(to api: APIGroup) {
        api.post("builds") { request, context in
            let input = try await request.decode(as: DeployRequest.self, context: context)
            return try await Response.json(buildService.deploy(input), status: .accepted)
        }
        api.get("builds") { request, _ in
            var appID: UUID?
            if let key = request.uri.queryParameters.get("app") {
                guard let app = try apps.find(slugOrID: key) else {
                    throw APIError(code: "app_not_found", message: "No app '\(key)'.")
                }
                appID = app.id
            }
            let limit = min(max(try request.integer("limit") ?? Self.defaultBuildLimit, 1), Self.maxBuildLimit)
            return try Response.json(builds.builds(appID: appID, limit: limit))
        }
        api.get("builds/:id") { _, context in try Response.json(build(context)) }
        api.post("builds/:id/cancel") { _, context in try await Response.json(buildService.cancel(buildID: build(context).id)) }
    }

    func addJobRoutes(to api: APIGroup) {
        api.get("jobs/:id") { _, context in try Response.json(job(context)) }
        api.get("jobs/:id/log") { request, context in
            let job = try job(context)
            let step = request.uri.queryParameters.get("step")
            if let follow = request.uri.queryParameters.get("follow"), follow == "1" || follow == "true" {
                return logFollowResponse(jobID: job.id, step: step)
            }
            return try await Response.json(logStore.read(jobID: job.id, step: step, tail: request.integer("tail")))
        }
        api.get("jobs/:id/artifacts") { _, context in try Response.json(artifactStore.list(jobID: job(context).id)) }
        api.get("jobs/:id/artifacts/:name") { _, context in
            let name = try context.parameters.require("name")
            let url = try artifactStore.url(jobID: job(context).id, name: name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular, let size = attributes?[.size] as? Int else {
                throw APIError(code: "artifact_not_found", message: "No artifact '\(name)'.")
            }
            let body = try await FileIO().loadFile(path: url.path, context: context)
            return Response(
                status: .ok,
                headers: [
                    .contentType: "application/octet-stream", .contentLength: "\(size)",
                    .contentDisposition: "attachment; filename=\"\(Self.headerSafe(name))\"",
                ],
                body: body)
        }
    }

    private func build(_ context: HangarRequestContext) throws -> Build {
        let key = try context.parameters.require("id")
        guard let id = UUID(uuidString: key), let build = try builds.build(id: id) else {
            throw APIError(code: "build_not_found", message: "No build '\(key)'.")
        }
        return build
    }

    func job(_ context: HangarRequestContext) throws -> Job {
        let key = try context.parameters.require("id")
        guard let id = UUID(uuidString: key), let job = try builds.job(id: id) else {
            throw APIError(code: "job_not_found", message: "No job '\(key)'.")
        }
        return job
    }

    /// A file name fit for a quoted header parameter.
    static func headerSafe(_ name: String) -> String {
        String(name.unicodeScalars.map { $0 == "\"" || $0.value < 0x20 || $0.value == 0x7F ? "_" : Character($0) })
    }
}
