import Foundation
import HangarCore

/// `hangar-worker check`: one authenticated call (`GET /api/v1/worker/me`) that tells whether the server still
/// accepts this machine's token. The install script uses it to update an enrolled Mac without a new pairing code.
public enum WorkerCheck {
    public enum Outcome: Equatable, Sendable {
        /// The token belongs to this machine.
        case accepted(Machine)
        /// 401: the machine was removed in Hangar (or the token is wrong).
        case unauthorized
        /// No HTTP answer: the server is down or not reachable from here.
        case unreachable(String)
        /// Any other answer.
        case failed(String)

        /// 0 accepted, 3 unauthorized, 4 unreachable, 1 otherwise.
        public var exitCode: Int32 {
            switch self {
            case .accepted: 0
            case .unauthorized: 3
            case .unreachable: 4
            case .failed: 1
            }
        }

        /// A line for the user. Never contains the token or a response body.
        public func message(server: URL) -> String {
            switch self {
            case .accepted(let machine): "\(server.absoluteString) accepts this Mac as \(machine.name)."
            case .unauthorized:
                "\(server.absoluteString) does not accept this Mac's token: the machine was removed in Hangar."
            case .unreachable(let reason): "Cannot reach \(server.absoluteString): \(reason)"
            case .failed(let reason): "Checking with \(server.absoluteString) failed: \(reason)"
            }
        }
    }

    public static func run(
        configuration: WorkerConfiguration, transport: any HTTPTransport, timeout: TimeInterval = 15
    ) async -> Outcome {
        var request = URLRequest(
            url: configuration.serverURL.appendingPathComponent("api/v1/worker/me"), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            return .unreachable(error.localizedDescription)
        } catch {
            return .unreachable("no HTTP answer")
        }
        switch response.statusCode {
        case 200:
            guard let machine = try? JSONCoding.decoder.decode(Machine.self, from: data) else {
                return .failed("the answer is not a machine")
            }
            return .accepted(machine)
        case 401: return .unauthorized
        default: return .failed("HTTP \(response.statusCode)")
        }
    }
}
