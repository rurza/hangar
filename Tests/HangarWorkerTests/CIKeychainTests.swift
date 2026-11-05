import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct CIKeychainTests {
    /// A keychain file and its password file in a temporary directory; `security` is a recording runner.
    struct Fixture {
        let directory = NSTemporaryDirectory() + "hangar-keychain-" + UUID().uuidString
        var keychain: CIKeychain { CIKeychain(path: directory + "/" + CIKeychain.fileName, passwordFile: directory + "/keychain-password") }

        init(password: String? = "s3cret\n", keychainExists: Bool = true) throws {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            if let password { try password.write(toFile: keychain.passwordFile, atomically: true, encoding: .utf8) }
            if keychainExists { FileManager.default.createFile(atPath: keychain.path, contents: Data()) }
        }

        func cleanUp() { try? FileManager.default.removeItem(atPath: directory) }
    }

    static func isSecurity(_ arguments: [String]) -> @Sendable (ProcessCommand) -> Bool {
        { $0.executable == "/usr/bin/security" && $0.arguments == arguments }
    }

    @Test func prepareUnlocksOnStandardInputThenMakesItTheDefaultAndFirstOnTheSearchList() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let path = fixture.keychain.path
        let runner = RecordingProcessRunner()
        runner.script(Self.isSecurity(["default-keychain", "-d", "user"]), lines: [#"    "/Users/hangar/Library/Keychains/login.keychain-db""#])
        runner.script(Self.isSecurity(["list-keychains", "-d", "user"]), lines: [#"    "/Users/hangar/Library/Keychains/login.keychain-db""#])

        try await fixture.keychain.prepare(runner: runner)

        #expect(runner.commands.map(\.arguments) == [
            ["-i"],
            ["default-keychain", "-d", "user"],
            ["default-keychain", "-d", "user", "-s", path],
            ["list-keychains", "-d", "user"],
            ["list-keychains", "-d", "user", "-s", path, "/Users/hangar/Library/Keychains/login.keychain-db"],
        ])
        #expect(runner.commands.first?.standardInput?.value == "unlock-keychain -p s3cret \"\(path)\"\n")
        #expect(!runner.commands.contains { $0.arguments.contains { $0.contains("s3cret") } })
        #expect(runner.commands.allSatisfy { $0.executable == "/usr/bin/security" })
    }

    @Test func prepareChangesNothingThatIsAlreadySet() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let path = fixture.keychain.path
        let runner = RecordingProcessRunner()
        // security prints the resolved path: /private/var/… for /var/….
        let printed = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        runner.script(Self.isSecurity(["default-keychain", "-d", "user"]), lines: ["    \"\(printed)\""])
        runner.script(Self.isSecurity(["list-keychains", "-d", "user"]), lines: ["    \"\(printed)\"", #"    "/Library/Keychains/System.keychain""#])

        try await fixture.keychain.prepare(runner: runner)

        #expect(runner.commands.map(\.arguments) == [["-i"], ["default-keychain", "-d", "user"], ["list-keychains", "-d", "user"]])
    }

    @Test func aKeychainLaterOnTheSearchListMovesToTheFront() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let path = fixture.keychain.path
        let runner = RecordingProcessRunner()
        runner.script(Self.isSecurity(["default-keychain", "-d", "user"]), lines: ["    \"\(path)\""])
        runner.script(Self.isSecurity(["list-keychains", "-d", "user"]), lines: [#"    "/a.keychain-db""#, "    \"\(path)\""])

        try await fixture.keychain.prepare(runner: runner)

        #expect(runner.commands.last?.arguments == ["list-keychains", "-d", "user", "-s", path, "/a.keychain-db"])
    }

    @Test func aWrongPasswordAMissingKeychainOrPasswordFileSaySo() async throws {
        let wrong = try Fixture()
        defer { wrong.cleanUp() }
        let runner = RecordingProcessRunner()
        runner.script({ $0.standardInput != nil }, lines: ["security: SecKeychainUnlock: wrong"], exitCode: 51)
        await #expect(throws: CIKeychainError.wrongPassword) { try await wrong.keychain.prepare(runner: runner) }

        let missing = try Fixture(keychainExists: false)
        defer { missing.cleanUp() }
        await #expect(throws: CIKeychainError.missing(missing.keychain.path)) {
            try await missing.keychain.prepare(runner: RecordingProcessRunner())
        }
        #expect(await missing.keychain.problem(runner: RecordingProcessRunner())?.contains("run hangar-worker isolate again") == true)

        for password in [nil, "  \n"] {
            let unreadable = try Fixture(password: password)
            defer { unreadable.cleanUp() }
            await #expect(throws: CIKeychainError.passwordUnreadable(unreadable.keychain.passwordFile)) {
                try await unreadable.keychain.prepare(runner: RecordingProcessRunner())
            }
        }
    }

    @Test func allowingCodesignSetsThePartitionListAndAcceptsAKeychainWithoutKeys() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = RecordingProcessRunner()
        try await fixture.keychain.allowCodesign(runner: runner)
        #expect(runner.commands.map(\.arguments) == [["-i"]])
        #expect(runner.commands.first?.standardInput?.value
            == "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k s3cret \"\(fixture.keychain.path)\"\n")

        let empty = RecordingProcessRunner()
        empty.script({ _ in true }, lines: ["security: SecItemCopyMatching: The specified item could not be found in the keychain."], exitCode: 1)
        try await fixture.keychain.allowCodesign(runner: empty)

        let failing = RecordingProcessRunner()
        failing.script({ _ in true }, lines: ["security: something else"], exitCode: 1)
        await #expect(throws: CIKeychainError.failed("security set-key-partition-list", exitCode: 1)) {
            try await fixture.keychain.allowCodesign(runner: failing)
        }
    }

    @Test func aWorkerIsHeadlessWhenItsHomeHasThePasswordFile() throws {
        let home = NSTemporaryDirectory() + "hangar-home-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(CIKeychain.installed(home: home) == nil)
        let keychain = CIKeychain(home: home)
        #expect(keychain.path == home + "/Library/Keychains/hangar-ci.keychain-db")
        #expect(keychain.passwordFile == home + "/Library/Application Support/Hangar/worker/keychain-password")
        #expect(keychain.passwordFile == IsolationLayout(home: home).dataDirectory + "/keychain-password")
        try FileManager.default.createDirectory(
            atPath: (keychain.passwordFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "x".write(toFile: keychain.passwordFile, atomically: true, encoding: .utf8)
        #expect(CIKeychain.installed(home: home) == keychain)
    }

    @Test func searchListPathsAreTheQuotedLines() {
        let output = """
                "/Users/hangar/Library/Keychains/hangar-ci.keychain-db"
                "/Library/Keychains/System.keychain"
            security: a warning
            """
        #expect(CIKeychain.paths(in: output) == [
            "/Users/hangar/Library/Keychains/hangar-ci.keychain-db", "/Library/Keychains/System.keychain",
        ])
    }

    @Test func theLiveRunnerWritesStandardInputAndClosesIt() async throws {
        let outcome = try await LiveProcessRunner().run(
            ProcessCommand(executable: "/bin/cat", arguments: [], standardInput: SensitiveText("one line\n")), onLine: { _ in })
        #expect(outcome == ProcessOutcome(exitCode: 0, output: "one line"))
        #expect("\(ProcessCommand(executable: "/bin/cat", arguments: [], standardInput: SensitiveText("x")))".contains("<redacted>"))
    }
}
