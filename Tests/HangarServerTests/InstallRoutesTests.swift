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
                // An enrolled Mac is updated in place; a taken name gets a concrete example.
                #expect(script.contains(#"check --config "$config_file""#))
                #expect(script.contains("HANGAR_MACHINE_NAME=mini-2 sh"))
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

    /// The script names the binary it is about to download by its SHA-256, so a download that is not that binary
    /// is never run.
    @Test func theScriptCarriesTheServedBinarysHash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("hangar-worker")
        try Data("#!/bin/sh\necho worker\n".utf8).write(to: binary)
        let digest = try #require(SHA256File.hex(of: binary))
        let fixture = try APIFixture(workerBinaryPath: binary.path)
        try await fixture.test { client in
            try await client.execute(uri: "/install", method: .get) { response throws in
                let script = String(buffer: response.body)
                #expect(script.contains("HANGAR_WORKER_SHA256='\(digest)'\n"))
                #expect(script.contains(#"verify_sha256 "$download" "$HANGAR_WORKER_SHA256""#))
                #expect(!script.contains(InstallScript.sha256Placeholder))
            }
        }
    }

    @Test func noBinaryMeansNoHashToCheck() {
        let script = InstallScript.render(origin: "http://localhost", workerSHA256: nil)
        #expect(script.contains("HANGAR_WORKER_SHA256=''\n"))
        // Only a hex digest is ever pasted into the script.
        #expect(InstallScript.render(origin: "http://localhost", workerSHA256: "'; rm -rf ~; '").contains("HANGAR_WORKER_SHA256=''\n"))
    }

    /// The launch agent gives a stopping worker two minutes to report its jobs; launchd's default is 20 s.
    @Test func theLaunchAgentWaitsTwoMinutesBeforeSIGKILL() {
        let script = InstallScript.render(origin: "http://localhost")
        #expect(script.contains("<key>ExitTimeOut</key>\n    <integer>120</integer>"))
    }

    /// Runs the script's own `verify_sha256` (everything but the final `main` call) on a file.
    static func verify(file: URL, expected: String) throws -> Int32 {
        let script = InstallScript.render(origin: "http://localhost")
        let functions = script.replacingOccurrences(of: "main \"$@\"\n", with: "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", functions + "\nverify_sha256 \"$1\" \"$2\"\n", "verify", file.path, expected]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func verifySHA256AcceptsOnlyTheAnnouncedBinary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        try Data("the real worker".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let digest = try #require(SHA256File.hex(of: file))
        #expect(try Self.verify(file: file, expected: digest) == 0)
        #expect(try Self.verify(file: file, expected: String(repeating: "0", count: 64)) != 0)
        #expect(try Self.verify(file: file, expected: "") == 0)
    }
}
