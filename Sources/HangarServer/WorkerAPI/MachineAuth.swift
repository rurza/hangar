import Foundation
import HangarCore
import Hummingbird

/// Resolves the machine of `Authorization: Bearer <token>` and puts it in the context; 401 `unauthorized` when the
/// header is missing or the token unknown. The token itself is never logged.
///
/// A job token (`hgj_…`, VM builds design) resolves to the machine it was issued to and limits the request to that
/// job's own routes (`JobTokenPolicy`), checked here so no worker route can forget it: 401 `invalid_job_token` when
/// it is unknown, revoked or its job is over, 403 `job_token_scope` for any other route.
struct MachineAuth: RouterMiddleware {
    typealias Context = HangarRequestContext

    let machines: MachineRepository
    let jobTokens: JobTokenRepository

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else { throw Self.unauthorized }
        let token = header.dropFirst("Bearer ".count).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { throw Self.unauthorized }
        var context = context
        // A machine token first, so a machine whose random token happens to carry the prefix still works.
        if let machine = try machines.authenticate(token: token) {
            context.machine = machine
        } else if token.hasPrefix(JobTokenRepository.prefix) {
            guard let (jobID, machineID) = try jobTokens.authenticate(token: token),
                let machine = try machines.find(nameOrID: machineID.uuidString)
            else { throw Self.invalidJobToken }
            let path = String(request.uri.path.dropFirst(CrossSiteGuard.workerPrefix.count))
            guard JobTokenPolicy.allows(method: request.method, path: path, jobID: jobID) else {
                throw APIError(
                    code: "job_token_scope",
                    message: "A job token can only start, report on and finish its own job, not call \(request.method) /api/v1/worker/\(path).")
            }
            context.machine = machine
            context.jobScope = jobID
        } else {
            throw Self.unauthorized
        }
        return try await next(request, context)
    }

    static let unauthorized = APIError(code: "unauthorized", message: "A valid machine token is required.")
    static let invalidJobToken = APIError(
        code: "invalid_job_token", message: "The job token is unknown, was revoked or its job is no longer running here.")
}

/// The worker routes a job token may call: its own job's start, info, steps, log, artifacts and finish. Everything
/// else (heartbeat, next job, me, issuing or revoking tokens, another job) needs the machine token.
enum JobTokenPolicy {
    static let jobRoutes: Set<String> = ["start", "info", "steps", "log", "finish"]

    /// `path` is relative to `/api/v1/worker/`, without a query.
    static func allows(method: HTTPRequest.Method, path: String, jobID: UUID) -> Bool {
        guard method == .post else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "jobs", UUID(uuidString: parts[1]) == jobID else { return false }
        switch parts.count {
        case 3: return jobRoutes.contains(parts[2])
        case 4: return parts[2] == "artifacts" && !parts[3].isEmpty
        default: return false
        }
    }
}

extension HangarRequestContext {
    /// The machine `MachineAuth` resolved; only the worker routes, which it guards, call this.
    func requireMachine() throws -> Machine {
        guard let machine else { throw MachineAuth.unauthorized }
        return machine
    }

    /// Refuses a job token: for the routes that need the machine itself, behind `JobTokenPolicy` as a second check.
    func requireMachineToken() throws {
        if jobScope != nil {
            throw APIError(code: "job_token_scope", message: "This needs the machine token, not a job token.")
        }
    }
}
