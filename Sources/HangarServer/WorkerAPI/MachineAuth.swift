import Foundation
import HangarCore
import Hummingbird

/// Resolves the machine of `Authorization: Bearer <token>` and puts it in the context; 401 `unauthorized` when the
/// header is missing or the token unknown. The token itself is never logged.
struct MachineAuth: RouterMiddleware {
    typealias Context = HangarRequestContext

    let machines: MachineRepository

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else { throw Self.unauthorized }
        let token = header.dropFirst("Bearer ".count).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, let machine = try machines.authenticate(token: token) else { throw Self.unauthorized }
        var context = context
        context.machine = machine
        return try await next(request, context)
    }

    static let unauthorized = APIError(code: "unauthorized", message: "A valid machine token is required.")
}

extension HangarRequestContext {
    /// The machine `MachineAuth` resolved; only the worker routes, which it guards, call this.
    func requireMachine() throws -> Machine {
        guard let machine else { throw MachineAuth.unauthorized }
        return machine
    }
}
