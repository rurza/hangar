import Foundation
import HangarCore
import Hummingbird

extension HangarServerApp {
    func addNumberRoutes(to api: APIGroup) {
        api.get("apps/:id/numbers") { _, context in try await Response.json(numbers.preview(app: app(context))) }
        api.put("apps/:id/numbers/next") { request, context in
            let app = try app(context)
            let input = try await request.decode(as: BumpNumberRequest.self, context: context)
            return try await Response.json(numbers.bump(app: app, to: input.next))
        }
    }
}
