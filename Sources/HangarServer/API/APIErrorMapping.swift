import Foundation
import HangarCore
import Hummingbird

/// The one place errors become HTTP statuses and `{ "code", "message" }` bodies. Messages name variables, never
/// their values.
enum APIErrorMapping {
    static let notFoundCodes: Set<String> = [
        "not_found", "app_not_found", "build_not_found", "job_not_found", "machine_not_found", "workflow_not_found",
        "artifact_not_found", "ref_not_found", "workflow_file_not_found", "icon_not_found", "repository_not_found",
        "token_not_found", "variable_not_found", "variable_group_not_found",
    ]
    static let conflictCodes: Set<String> = [
        "app_exists", "machine_exists", "bump_not_higher", "job_not_assigned_to_machine", "job_state_conflict",
        "asc_not_configured", "github_not_configured", "issuer_required", "worker_already_installed",
        "dedicated_user_required",
        "token_exists", "variable_workflows_overlap", "variable_exists", "variable_group_exists",
        "signing_identity_exists", "signing_busy", "team_key_required",
    ]

    static func map(_ error: any Error) -> (HTTPResponse.Status, APIError) {
        switch error {
        case let error as APIError: return (status(code: error.code), error)
        case let error as PairingError: return map(error)
        case let error as DeployError: return map(error)
        case let error as BuildNumberError: return map(error)
        case let error as SourceHostError: return map(error)
        case WorkflowDetectionError.noProjectFound:
            return self.error(
                "no_project_found",
                "No Xcode workspace, project or XcodeGen project.yml was found in the repository (Pods, Carthage and other dependency folders are skipped).")
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
        if code == "unauthorized" || code == "invalid_api_token" || code == "invalid_job_token" { return .unauthorized }
        if code == "token_scope" || code == "job_token_scope" { return .forbidden }
        if code == "cross_site_request" || code == "invalid_pairing_code" || code == "local_only" { return .forbidden }
        if code == "too_many_attempts" || code == "signing_rate_limited" { return .tooManyRequests }
        if ["worker_binary_missing", "host_name_unknown", "server_address_unusable"].contains(code) { return .serviceUnavailable }
        if code == "host_not_allowed" { return .misdirectedRequest }
        if code == "unsupported_media_type" { return .unsupportedMediaType }
        if code == "github_unauthorized" { return .badGateway }
        if code == "github_rate_limited" { return .serviceUnavailable }
        if code == "asc_unavailable" || code == "asc_refused" { return .badGateway }
        if code == "detection_timeout" { return .gatewayTimeout }
        if code == "no_project_found" { return .unprocessableContent }
        if notFoundCodes.contains(code) { return .notFound }
        if conflictCodes.contains(code) { return .conflict }
        return .badRequest
    }

    private static func error(_ code: String, _ message: String) -> (HTTPResponse.Status, APIError) {
        (status(code: code), APIError(code: code, message: message))
    }

    private static func map(_ error: PairingError) -> (HTTPResponse.Status, APIError) {
        switch error {
        case .invalidCode:
            self.error(
                "invalid_pairing_code",
                "That pairing code is not valid: it may be mistyped, used or expired. Get a new one in Hangar under Machines > Add Mac.")
        case .tooManyAttempts:
            self.error("too_many_attempts", "Too many wrong pairing codes. Wait 10 minutes, then try again.")
        }
    }

    private static func map(_ error: DeployError) -> (HTTPResponse.Status, APIError) {
        switch error {
        case .appNotFound(let key): self.error("app_not_found", "No app '\(key)'.")
        case .machineNotFound(let key): self.error("machine_not_found", "No machine '\(key)'.")
        case .refNotFound(let ref): self.error("ref_not_found", "The repository has no ref '\(ref)'.")
        case .workflowFileMissing(let commit):
            self.error("workflow_file_missing", "Commit \(commit.prefix(7)) has no \(WorkflowFile.path).")
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
                message: "Set the App Store Connect key in Settings › App Store Connect."))
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
        case .http(401, _): GitHubRepositories.unauthorized.mapped
        case .rateLimited(let reset):
            APIError(
                code: "github_rate_limited",
                message: reset.map { "GitHub rate limit reached, try again at \(Self.clockTime($0))." }
                    ?? "GitHub rate limit reached, try again later.").mapped
        case .invalidResponse(let message): (.badGateway, APIError(code: "source_host_error", message: message))
        case .tooLarge(let path, let bytes):
            (.badGateway, APIError(code: "file_too_large", message: "\(path) is \(bytes / 1_048_576) MB, too big to read."))
        case .http(let status, _):
            // The body is left out: it is the host's text, not ours, and may be large.
            (.badGateway, APIError(code: "source_host_error", message: "The source host answered HTTP \(status)."))
        }
    }

    /// `HH:MM` in the server's time zone.
    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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

extension APIError {
    var mapped: (HTTPResponse.Status, APIError) { (APIErrorMapping.status(code: code), self) }
}
