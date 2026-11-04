import Foundation
import HangarCore
import Hummingbird

/// The one place errors become HTTP statuses and `{ "code", "message" }` bodies. Messages name variables, never
/// their values.
enum APIErrorMapping {
    static let notFoundCodes: Set<String> = [
        "not_found", "app_not_found", "build_not_found", "job_not_found", "machine_not_found", "workflow_not_found",
        "artifact_not_found", "ref_not_found",
    ]
    static let conflictCodes: Set<String> = [
        "app_exists", "machine_exists", "bump_not_higher", "job_not_assigned_to_machine", "job_state_conflict",
    ]

    static func map(_ error: any Error) -> (HTTPResponse.Status, APIError) {
        switch error {
        case let error as APIError: return (status(code: error.code), error)
        case let error as DeployError: return map(error)
        case let error as BuildNumberError: return map(error)
        case let error as SourceHostError: return map(error)
        case let error as WorkflowFileError: return (.badRequest, APIError(code: "invalid_workflow_file", message: error.description))
        case let error as HTTPError: return map(error)
        case is DecodingError: return (.badRequest, APIError(code: "invalid_request", message: "The request body is not valid."))
        case let error as URLError:
            return (.badGateway, APIError(code: "upstream_unavailable", message: "An upstream service is unreachable: \(error.localizedDescription)"))
        case is URLSessionTransport.NonHTTPResponse:
            return (.badGateway, APIError(code: "upstream_unavailable", message: "An upstream service sent a non-HTTP response."))
        default: return (.internalServerError, APIError(code: "internal_error", message: "Internal server error."))
        }
    }

    static func status(code: String) -> HTTPResponse.Status {
        if code == "unauthorized" { return .unauthorized }
        if notFoundCodes.contains(code) { return .notFound }
        if conflictCodes.contains(code) { return .conflict }
        return .badRequest
    }

    private static func error(_ code: String, _ message: String) -> (HTTPResponse.Status, APIError) {
        (status(code: code), APIError(code: code, message: message))
    }

    private static func map(_ error: DeployError) -> (HTTPResponse.Status, APIError) {
        switch error {
        case .appNotFound(let key): self.error("app_not_found", "No app '\(key)'.")
        case .machineNotFound(let key): self.error("machine_not_found", "No machine '\(key)'.")
        case .refNotFound(let ref): self.error("ref_not_found", "The repository has no ref '\(ref)'.")
        case .workflowFileMissing(let commit):
            self.error("workflow_file_missing", "Commit \(commit) has no \(WorkflowFile.path).")
        case .workflowFile(let error): self.error("invalid_workflow_file", error.description)
        case .workflowNotFound(let name, let available):
            self.error(
                "workflow_not_found",
                "No workflow '\(name)' in \(WorkflowFile.path); available: \(available.joined(separator: ", ")).")
        case .approvalNotSupported(let postAction):
            self.error(
                "approval_not_supported", "Post-action '\(postAction)' requires approval, which is not supported yet.")
        case .numbering(let error): map(error)
        case .buildNotFound(let id): self.error("build_not_found", "No build \(id.uuidString).")
        }
    }

    private static func map(_ error: BuildNumberError) -> (HTTPResponse.Status, APIError) {
        switch error {
        case .appStoreConnectNotConfigured:
            (.badGateway, APIError(
                code: "app_store_connect_not_configured",
                message: "Set the global variables HANGAR_ASC_KEY_ID, HANGAR_ASC_ISSUER_ID and HANGAR_ASC_KEY_PATH."))
        case .sourceUnavailable(let source, let reason):
            (.badGateway, APIError(
                code: "build_number_source_unavailable", message: "Build number source '\(source)' failed: \(reason)"))
        case .nonInteger(let source, let value):
            (.badGateway, APIError(
                code: "build_number_not_integer",
                message: "Build number source '\(source)' has the non-integer build number '\(value)'."))
        case .bumpNotHigher(let current, let requested):
            self.error("bump_not_higher", "The next number is already \(current); \(requested) is not higher.")
        }
    }

    private static func map(_ error: SourceHostError) -> (HTTPResponse.Status, APIError) {
        switch error {
        case .refNotFound(let ref): self.error("ref_not_found", "The repository has no ref '\(ref)'.")
        case .unsupportedRepository(let url):
            self.error("unsupported_repository", "'\(url)' is not a supported repository URL (GitHub only).")
        case .invalidPath(let path): self.error("invalid_path", "'\(path)' is not a valid repository path.")
        case .http(let status, _):
            // The body is left out: it is the host's text, not ours, and may be large.
            (.badGateway, APIError(code: "source_host_error", message: "The source host answered HTTP \(status)."))
        }
    }

    private static func map(_ error: HTTPError) -> (HTTPResponse.Status, APIError) {
        let code =
            switch error.status {
            case .badRequest: "invalid_request"
            case .notFound: "not_found"
            case .contentTooLarge: "payload_too_large"
            default: error.status.reasonPhrase.lowercased().replacingOccurrences(of: " ", with: "_")
            }
        return (error.status, APIError(code: code, message: error.body ?? error.status.reasonPhrase))
    }
}
