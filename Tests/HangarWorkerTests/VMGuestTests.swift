import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct VMSigningTests {
    static func directory() throws -> String {
        let path = NSTemporaryDirectory() + "hangar-vm-signing-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func theIdentityIsKeptInTwoPrivateFiles() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = VMIdentityStore(dataDirectory: directory)
        #expect(try store.load() == nil)
        try store.save(p12: Data("p12".utf8), password: SensitiveText("pa ss\"word"))
        #expect(try store.load() == GuestIdentity(p12: Data("p12".utf8), password: "pa ss\"word"))
        for path in [store.file, store.passwordFile] {
            #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        }
        #expect("\(try store.load()!)" == "<identity>")
        store.remove()
        #expect(!store.exists)
    }

    /// `security -i` that creates the keychain file a `create-keychain` names.
    final class CreatingRunner: ProcessRunner {
        let recording = RecordingProcessRunner()
        var commands: [ProcessCommand] { recording.commands }

        func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
            if let input = command.standardInput?.value, input.hasPrefix("create-keychain "), let quote = input.firstIndex(of: "\"") {
                let path = input[input.index(after: quote)...].prefix { $0 != "\"" }
                FileManager.default.createFile(atPath: String(path), contents: Data())
            }
            return try await recording.run(command, onLine: onLine)
        }
    }

    @Test func theGuestsKeychainIsCreatedImportedAndAllowedForCodesign() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runner = CreatingRunner()
        let keychain = try await GuestKeychain.install(
            GuestIdentity(p12: Data("p12".utf8), password: "id \"pw\""), directory: directory + "/kc", runner: runner,
            password: SensitiveText("kcpw"))

        #expect(keychain.path == directory + "/kc/job.keychain-db")
        let inputs = runner.commands.compactMap(\.standardInput?.value)
        #expect(inputs.first == "create-keychain -p kcpw \"\(keychain.path)\"\n")
        // The .p12 is split first: `-x` is ignored for a .p12, so the key is imported on its own.
        let openssl = runner.commands.filter { $0.executable == "/usr/bin/openssl" }
        #expect(openssl.map { Array($0.arguments.prefix(1)) } == [["pkcs12"], ["rsa"], ["pkcs12"]])
        #expect(openssl.filter { $0.arguments.contains("-passin") }.allSatisfy {
            $0.arguments.contains("stdin") && $0.standardInput?.value == "id \"pw\"\n"
        })
        let imports = inputs.filter { $0.hasPrefix("import ") }
        #expect(imports.count == 2)
        let key = try #require(imports.first)
        #expect(key.contains("identity-key.pem") && key.contains("-t priv -f openssl -x -T /usr/bin/codesign\n"))
        #expect(!imports.contains { $0.contains("/usr/bin/security") || $0.contains("-P ") })
        #expect(imports.last?.contains("identity-certificates.pem\" -k") == true)
        #expect(imports.last?.hasSuffix("-t cert -f pemseq\n") == true)
        #expect(inputs.contains { $0.hasPrefix("set-key-partition-list -S apple-tool:,apple:,codesign:") })
        #expect(runner.commands.contains { $0.arguments == ["set-keychain-settings", keychain.path] })
        #expect(runner.commands.contains { $0.arguments.starts(with: ["default-keychain", "-d", "user", "-s"]) })
        #expect(!runner.commands.contains { $0.arguments.joined().contains("kcpw") || $0.arguments.joined().contains("pw\"") })
        // Nothing but the keychain is left: no .p12, no key or certificate file, and no password file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory + "/kc") == ["job.keychain-db"])
        #expect(try keychain.readPassword() == SensitiveText("kcpw"))
    }

    @Test func aTestJobGetsAKeychainWithoutAnIdentity() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runner = CreatingRunner()
        _ = try await GuestKeychain.install(nil, directory: directory, runner: runner)
        #expect(!runner.commands.contains { $0.standardInput?.value.hasPrefix("import ") == true })
    }
}

@Suite(.timeLimit(.minutes(1))) struct GuestJobTests {
    @Test func theBundleTravelsAsOneJSONLine() throws {
        let bundle = GuestJobBundle(
            assignment: WorkerLoopTests.assignment(), token: "hgj_t", serverURL: URL(string: "http://127.0.0.1:8787")!,
            identity: GuestIdentity(p12: Data([0, 1, 2]), password: "pw"), vmNote: "VM: restored", machineName: "mini (VM)")
        let line = String(decoding: try JSONCoding.encoder.encode(bundle), as: UTF8.self)
        #expect(!line.contains("\n"))
        #expect(try JSONCoding.decoder.decode(GuestJobBundle.self, from: Data(line.utf8)) == bundle)
    }

    @Test func controlLinesRoundTrip() {
        #expect(GuestControl(line: "cancel") == .cancel(reason: nil))
        #expect(GuestControl(line: "cancel timed out") == .cancel(reason: "timed out"))
        #expect(GuestControl(line: GuestControl.cancel(reason: "a\nb").line) == .cancel(reason: "a b"))
        #expect(GuestControl(line: "anything else") == nil)
    }

    @Test func theResultLineIsWhatTheHostParses() {
        let result = JobResult(status: .failed, failureReason: "archive failed", outputs: ["x": "y"])
        let line = GuestJobRunner.resultLine(result)
        #expect(line.hasPrefix("hangar-result {"))
        #expect(GuestJobRunner.parseResult(line) == result)
        #expect(GuestJobRunner.parseResult("2026-11-05 info: hangar-result") == nil)
    }

    @Test func theFirstReasonWinsAndAVanishedHostCancels() {
        let reader = GuestControlReader()
        #expect(!reader.isCancelled)
        reader.apply(.cancel(reason: "timeout"))
        reader.hostGone()
        #expect(reader.isCancelled && reader.stopReason == "timeout")
        let orphan = GuestControlReader()
        orphan.hostGone()
        #expect(orphan.stopReason == "the build VM lost its connection to the host's worker")
    }

    @Test func theReaderTakesTheBundleThenWatchesForControlLines() throws {
        let pipe = Pipe()
        let bundle = GuestJobBundle(
            assignment: WorkerLoopTests.assignment(), token: "hgj_t", serverURL: URL(string: "http://127.0.0.1:8787")!,
            identity: nil, vmNote: nil, machineName: "mini (VM)")
        let line = try JSONCoding.encoder.encode(bundle) + Data("\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: line)
        let reader = GuestControlReader()
        #expect(try reader.readBundle(from: pipe.fileHandleForReading) == bundle)
        try pipe.fileHandleForWriting.write(contentsOf: Data("cancel stop now\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        while !reader.isCancelled, Date() < deadline { usleep(10_000) }
        #expect(reader.stopReason == "stop now")
    }

    @Test func aMissingBundleIsAnError() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        #expect(throws: GuestBundleError.self) { try GuestControlReader().readBundle(from: pipe.fileHandleForReading) }
    }

    @Test func theGuestRunsThePipelineWithTheJobTokenAndHomebrewQuiet() async throws {
        let home = NSTemporaryDirectory() + "hangar-guest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // security creates nothing here, so the job's keychain is missing: the checkout step fails at preparation,
        // after logging the VM note.
        let runner = RecordingProcessRunner()
        let connection = FakeServerConnection()
        let made = Mutex<(URL, String)?>(nil)
        var assignment = WorkerLoopTests.assignment()
        assignment.job.action = WorkflowAction(scheme: "Demo", platform: .iOS, export: .appStoreConnect)
        let bundle = GuestJobBundle(
            assignment: assignment, token: "hgj_t", serverURL: URL(string: "http://127.0.0.1:8787")!, identity: nil,
            vmNote: "VM: restored slot 0's saved state in 4.5 s on mini", machineName: "mini (VM)")
        let outcome = await GuestJobRunner(runner: runner, home: home).run(
            bundle, cancelled: { false }, stopReason: { nil },
            connection: { url, token in
                made.withLock { $0 = (url, token) }
                return connection
            })
        guard case .finished(let result) = outcome else {
            Issue.record("the guest handed off a job that failed at checkout")
            return
        }
        #expect(made.withLock { $0?.0 } == URL(string: "http://127.0.0.1:8787")!)
        #expect(made.withLock { $0?.1 } == "hgj_t")
        #expect(result.status == .failed)
        #expect(connection.logLines.first == "VM: restored slot 0's saved state in 4.5 s on mini")
        #expect(result.failureReason?.contains("keychain") == true)
        #expect(connection.result == result)
    }
}
