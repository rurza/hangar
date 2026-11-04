import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// `GET /install` (the worker install script) and `GET /install/hangar-worker` (the binary). The router test
/// client sends Host `localhost`.
@Suite(.timeLimit(.minutes(1))) struct InstallRoutesTests {
    /// Runs `/bin/sh -n` on the script: it must parse.
    static func shellParses(_ script: String) throws -> (ok: Bool, errors: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString).sh")
        try Data(script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", file.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus == 0, text)
    }

    @Test func installServesAScriptForTheRequestsHost() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            try await client.execute(uri: "/install", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/plain; charset=utf-8")
                let script = String(buffer: response.body)
                #expect(script.hasPrefix("#!/bin/sh\n"))
                #expect(script.contains("HANGAR_SERVER='http://localhost'\n"))
                #expect(!script.contains(InstallScript.originPlaceholder))
                let parsed = try Self.shellParses(script)
                #expect(parsed.ok, "sh -n: \(parsed.errors)")
            }
        }
    }

    @Test(arguments: [
        ("rurzomac-mini:8787", "http://rurzomac-mini:8787"),
        ("Studio.tail1234.ts.net.:8787", "http://studio.tail1234.ts.net:8787"),
        ("100.71.242.42:8787", "http://100.71.242.42:8787"),
        ("[fd7a:115c::1]:8787", "http://[fd7a:115c::1]:8787"),
        ("localhost", "http://localhost"),
    ])
    func originComesFromTheHost(authority: String, origin: String) throws {
        #expect(InstallScript.origin(authority: authority) == origin)
        let script = InstallScript.render(origin: origin)
        #expect(script.contains("HANGAR_SERVER='\(origin)'\n"))
        let parsed = try Self.shellParses(script)
        #expect(parsed.ok, "sh -n: \(parsed.errors)")
    }

    @Test(arguments: ["evil'host.ts.net", "a b.ts.net", "host:0", "host:70000", "host:-1", "$(id).ts.net", "", ":8787"])
    func unsafeHostsGiveNoOrigin(authority: String) {
        #expect(InstallScript.origin(authority: authority) == nil)
    }

    @Test func installRefusesAForeignHost() async throws {
        let fixture = try APIFixture(boundHost: "100.71.242.42")
        try await fixture.test { client in
            for uri in ["/install", "/install/hangar-worker"] {
                try await client.execute(uri: uri, method: .get) { response throws in
                    #expect(response.status == .misdirectedRequest)
                    #expect(try decode(APIError.self, response).code == "host_not_allowed")
                }
            }
        }
    }

    @Test func workerBinaryIs503WhenItIsNotInstalled() async throws {
        let fixture = try APIFixture(workerBinaryPath: nil)
        try await fixture.test { client in
            try await client.execute(uri: "/install/hangar-worker", method: .get) { response throws in
                #expect(response.status == .serviceUnavailable)
                #expect(try decode(APIError.self, response).code == "worker_binary_missing")
            }
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                #expect(try decode(SettingsStatus.self, response).workerInstallAvailable == false)
            }
        }
    }

    @Test func workerBinaryIs503WhenThePathIsGone() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString)")
        let fixture = try APIFixture(workerBinaryPath: missing.path)
        try await fixture.test { client in
            try await client.execute(uri: "/install/hangar-worker", method: .get) { response throws in
                #expect(response.status == .serviceUnavailable)
            }
        }
    }

    @Test func workerBinaryIsServedWithItsVersionAndLength() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("hangar-worker")
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        try bytes.write(to: binary)
        let fixture = try APIFixture(workerBinaryPath: binary.path)
        try await fixture.test { client in
            try await client.execute(uri: "/install/hangar-worker", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/octet-stream")
                #expect(response.headers[.contentLength] == "\(bytes.count)")
                #expect(response.headers[InstallRoutes.versionHeader] == HangarVersion.current)
                #expect(Data(response.body.readableBytesView) == bytes)
            }
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                #expect(try decode(SettingsStatus.self, response).workerInstallAvailable == true)
            }
        }
    }
}
