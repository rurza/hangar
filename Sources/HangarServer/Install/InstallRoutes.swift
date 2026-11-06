import Foundation
import HangarCore
import Hummingbird

/// The one-command worker install: `GET /install` is the shell script (`curl -fsSL <server>/install | sh`) and
/// `GET /install/hangar-worker` the worker binary it downloads. `GET /install/hangar` is the CLI, for Macs where
/// agents work. Both sit outside `/api/v1` and are GET-only, so the
/// cross-site guard does not apply; the Host check does, and the script's server address comes from that Host.
struct InstallRoutes: Sendable {
    static let versionHeader = HTTPFields.Element.Name("X-Hangar-Version")!

    let workerBinaryPath: String?

    func addRoutes(to router: Router<HangarRequestContext>) {
        router.get("install") { request, _ in
            guard let origin = request.authority.flatMap(InstallScript.origin(authority:)) else {
                throw APIError(code: "invalid_request", message: "The Host header cannot be used as the server's address.")
            }
            let script = InstallScript.render(
                origin: origin, workerSHA256: WorkerBinaryDigest.current(at: workerBinaryPath))
            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/plain; charset=utf-8", .contentLength: "\(script.utf8.count)",
                    .cacheControl: "no-store", .xContentTypeOptions: "nosniff",
                ],
                body: ResponseBody(byteBuffer: ByteBuffer(string: script)))
        }
        router.get("install/hangar") { _, context in
            guard let binary = Self.workerBinary(at: cliBinaryPath) else {
                throw APIError(
                    code: "cli_binary_missing",
                    message: "This server has no hangar CLI to hand out. Reinstall the server with the latest scripts/server/install-server.sh.")
            }
            let body = try await FileIO().loadFile(path: binary.path, context: context)
            return Response(
                status: .ok,
                headers: [
                    .contentType: "application/octet-stream", .contentLength: "\(binary.size)",
                    .cacheControl: "no-store", Self.versionHeader: HangarVersion.current,
                ],
                body: body)
        }
        router.get("install/hangar-worker") { _, context in
            guard let binary = Self.workerBinary(at: workerBinaryPath) else {
                throw APIError(
                    code: "worker_binary_missing",
                    message: "This server has no hangar-worker binary to hand out. Reinstall the server with the latest scripts/server/install-server.sh.")
            }
            let body = try await FileIO().loadFile(path: binary.path, context: context)
            return Response(
                status: .ok,
                headers: [
                    .contentType: "application/octet-stream", .contentLength: "\(binary.size)",
                    .cacheControl: "no-store", Self.versionHeader: HangarVersion.current,
                ],
                body: body)
        }
    }

    /// The `hangar` CLI the server hands to a Mac where agents work: installed next to `hangar-worker`.
    var cliBinaryPath: String? {
        workerBinaryPath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("hangar") }
    }

    /// The binary at `path` and its size, nil when there is no path or it is not a non-empty regular file.
    static func workerBinary(at path: String?) -> (path: String, size: Int)? {
        guard let path,
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue, size > 0
        else { return nil }
        return (path, size)
    }
}

/// Where the server finds the `hangar-worker` it hands out: next to its own executable, symlinks resolved, the way
/// `WebUI` finds its bundle. install-server.sh installs both into the same bin directory.
public enum WorkerBinary {
    public static let name = "hangar-worker"

    /// The executable `hangar-worker` beside the running executable, nil when there is none.
    public static func locate() -> String? {
        guard
            let directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        else { return nil }
        let path = directory.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
