import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

/// Records every command and answers from a script that can change its answer as the run goes on.
fileprivate final class ScriptedRunner: IsolationRunner {
    typealias Answer = @Sendable (IsolationCommand, _ seen: [IsolationCommand]) -> IsolationResult?
    private let state = Mutex<(commands: [IsolationCommand], answers: [Answer])>(([], []))

    var commands: [IsolationCommand] { state.withLock { $0.commands } }
    /// The commands that change something or use sudo, as shell lines.
    var changes: [String] { commands.filter { $0.kind == .change || $0.isPrivileged }.map(\.description) }

    func on(_ answer: @escaping Answer) { state.withLock { $0.answers.append(answer) } }

    func run(_ command: IsolationCommand) throws -> IsolationResult {
        let (seen, answers) = state.withLock { state -> ([IsolationCommand], [Answer]) in
            state.commands.append(command)
            return (state.commands, state.answers)
        }
        for answer in answers { if let result = answer(command, seen) { return result } }
        return IsolationResult(exitCode: 0)
    }
}

fileprivate final class MemoryPasswordStore: AccountPasswordStore {
    let saved = Mutex<[(account: String, service: String, password: String)]>([])
    func save(_ password: SensitiveText, account: String, service: String) throws {
        saved.withLock { $0.append((account, service, password.value)) }
    }
}

struct FixedVerifier: AccountPasswordVerifier {
    var accepts: Bool
    func verify(_ password: SensitiveText, user: String) -> Bool { accepts }
}

fileprivate final class SequenceGenerator: PasswordGenerating {
    let count = Mutex(0)
    func generate() -> SensitiveText {
        SensitiveText(count.withLock { $0 += 1; return "pass-word-\($0)" })
    }
}

fileprivate final class Lines: Sendable {
    let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var text: String { lines.withLock { $0.joined(separator: "\n") } }
}

@Suite(.timeLimit(.minutes(1))) struct WorkerIsolationTests {
    static let server = URL(string: "http://studio:8787")!
    static let start = Date(timeIntervalSince1970: 2_000_000_000)

    /// An administrator's home with an enrolled worker in the 0.6 layout: plist, configuration, and in the work
    /// directory `~/.hangar/worker` a build cache, a leftover job and a leftover job `TMPDIR`.
    struct Fixture {
        let root: String
        let invoker: IsolationInvoker
        let binary: String
        let staging: String
        var oldData: String { invoker.home + "/Library/Application Support/Hangar/worker" }
        var oldWork: String { invoker.home + "/.hangar/worker" }

        init(withOldAgent: Bool = true, withConfig: Bool = true, isAdmin: Bool = true, name: String = "adam", uid: UInt32 = 501) throws {
            root = NSTemporaryDirectory() + "hangar-isolate-test-" + UUID().uuidString
            let home = root + "/home"
            invoker = IsolationInvoker(name: name, uid: uid, home: home, isAdmin: isAdmin)
            binary = root + "/bin/hangar-worker"
            staging = root + "/staging"
            let files = FileManager.default
            try files.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
            files.createFile(atPath: binary, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            try files.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
            let data = home + "/Library/Application Support/Hangar/worker"
            let work = home + "/.hangar/worker"
            try files.createDirectory(atPath: work + "/workspaces/legilo/DerivedData", withIntermediateDirectories: true)
            try files.createDirectory(atPath: work + "/jobs/old-job", withIntermediateDirectories: true)
            try files.createDirectory(atPath: work + "/tmp/old-job", withIntermediateDirectories: true)
            try files.createDirectory(atPath: data, withIntermediateDirectories: true)
            if withConfig {
                // workDirectory as `hangar-worker setup` leaves it: unset, so the default under this home applies.
                try WorkerConfiguration(serverURL: WorkerIsolationTests.server, token: "secret-token", dataDirectory: data)
                    .write(to: invoker.defaultConfig)
            }
            if withOldAgent {
                try WorkerLaunchAgent.plist(binary: binary, logs: home + "/Library/Logs/Hangar")
                    .write(toFile: invoker.plist, atomically: true, encoding: .utf8)
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
    }

    static func machine(runningUser: String?, lastSeen: Date?) -> Machine {
        Machine(
            id: UUID(uuidString: "8C606F06-B04B-4A91-8303-EEB30787B1FD")!, name: "mini-2", lastSeenAt: lastSeen,
            report: MachineReport(
                macOSVersion: "27.0", xcodes: [], chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: 100,
                onACPower: true, tools: [:], canSignWithoutPrompt: false, runningJobIDs: [], runningUser: runningUser),
            createdAt: start)
    }

    /// A Mac with no hangar user that logs in on the third poll; the agent runs once loaded and the server then sees
    /// the machine as hangar.
    fileprivate static func freshMac(_ runner: ScriptedRunner, sessionAfterPolls: Int = 2) {
        runner.on { command, seen in
            guard command.arguments == ["/usr/bin/id", "-u", "hangar"] else { return nil }
            let created = seen.contains { $0.arguments.contains("/usr/sbin/sysadminctl") }
            return created ? IsolationResult(exitCode: 0, output: "502") : IsolationResult(exitCode: 1)
        }
        runner.on { command, seen in
            guard command.arguments.first == "/bin/ps" else { return nil }
            let polls = seen.filter { $0.arguments.first == "/bin/ps" }.count
            return IsolationResult(
                exitCode: 0,
                output: polls > sessionAfterPolls
                    ? "  501 /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow\n  502 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
                    : "  501 /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow\n    0 /usr/sbin/cfprefsd")
        }
        runner.on { command, _ in
            command.arguments.contains("print") ? IsolationResult(exitCode: 0, output: "app.hangar.worker = {\n\tstate = running\n}") : nil
        }
        // The old worker is gone after bootout; hangar cannot read anything it should not.
        runner.on { command, _ in command.arguments.first == "/usr/bin/pgrep" ? IsolationResult(exitCode: 1) : nil }
        runner.on { command, _ in command.arguments.contains("-r") ? IsolationResult(exitCode: 1) : nil }
        runner.on { command, _ in
            command.arguments.contains("/bin/test") && command.arguments.contains("-e") ? IsolationResult(exitCode: 1) : nil
        }
        runner.on { command, _ in
            command.arguments.contains("-checkFirstLaunchStatus") ? IsolationResult(exitCode: 0) : nil
        }
    }

    fileprivate static func isolation(
        _ fixture: Fixture, runner: ScriptedRunner, options: IsolationOptions = IsolationOptions(serverData: ""),
        store: MemoryPasswordStore = MemoryPasswordStore(), verifier: FixedVerifier = FixedVerifier(accepts: true),
        check: @escaping @Sendable (WorkerConfiguration, Int) -> WorkerCheck.Outcome = { _, call in
            call == 0 ? .accepted(machine(runningUser: "adam", lastSeen: start)) : .accepted(machine(runningUser: "hangar", lastSeen: start))
        },
        output: Lines = Lines()
    ) -> WorkerIsolation {
        let calls = Mutex(0)
        var isolation = WorkerIsolation(
            invoker: fixture.invoker, options: options,
            dependencies: .init(
                runner: runner, passwords: store, verifier: verifier, generator: SequenceGenerator(),
                check: { configuration in check(configuration, calls.withLock { value in defer { value += 1 }; return value }) },
                sleep: { _ in }, now: { start }, say: { output.append($0) }, stagingDirectory: fixture.staging,
                ownExecutable: fixture.binary))
        isolation.timing.loginPolls = 10
        return isolation
    }

    // MARK: The whole run

    @Test func aFreshMacGetsTheAccountTheWorkerAndTheCacheInOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        Self.freshMac(runner)
        let store = MemoryPasswordStore()
        let output = Lines()
        let outcome = try await Self.isolation(fixture, runner: runner, store: store, output: output).run()

        let home = "/Users/hangar"
        let support = "'\(home)/Library/Application Support/Hangar/worker'"
        #expect(runner.changes == [
            "/usr/bin/sudo -v",
            "/usr/bin/sudo /usr/sbin/sysadminctl -addUser hangar -fullName Hangar -shell /bin/zsh -home /Users/hangar -password <redacted>",
            "/usr/bin/sudo /usr/bin/dscl . <<< <redacted>",
            "/usr/bin/sudo /usr/sbin/createhomedir -c -u hangar",
            "/bin/launchctl bootout gui/501/app.hangar.worker",
            "/usr/bin/sudo /usr/bin/install -d -o hangar -g staff -m 700 '\(home)/Library/Application Support' '\(home)/Library/Application Support/Hangar' \(support) \(home)/.hangar \(home)/.hangar/worker \(home)/.hangar/worker/workspaces \(home)/Library/Logs \(home)/Library/Logs/Hangar",
            "/usr/bin/sudo /usr/bin/install -d -o hangar -g staff -m 755 \(home)/.local \(home)/.local/bin \(home)/Library/LaunchAgents",
            "/usr/bin/sudo /usr/bin/install -o hangar -g staff -m 755 \(IsolationCommand.quote(URL(fileURLWithPath: fixture.binary).resolvingSymlinksInPath().path)) \(home)/.local/bin/hangar-worker",
            "/usr/bin/sudo /usr/bin/install -o hangar -g staff -m 600 \(IsolationCommand.quote(fixture.staging + "/config.json")) '\(home)/Library/Application Support/Hangar/worker/config.json'",
            "/usr/bin/sudo /bin/test -e \(home)/.hangar/worker/workspaces/legilo",
            "/usr/bin/sudo /bin/mv \(IsolationCommand.quote(fixture.oldWork + "/workspaces/legilo")) \(home)/.hangar/worker/workspaces/legilo",
            "/bin/rmdir \(IsolationCommand.quote(fixture.oldWork + "/workspaces"))",
            "/usr/bin/sudo /bin/rm -rf \(home)/.hangar/worker/workspaces/legilo/DerivedData/Build \(home)/.hangar/worker/workspaces/legilo/DerivedData/SourcePackages/workspace-state.json \(home)/.hangar/worker/workspaces/legilo/DerivedData/SourcePackages/artifacts \(home)/.hangar/worker/workspaces/legilo/DerivedData/SourcePackages/checkouts",
            "/usr/bin/sudo /usr/sbin/chown -R hangar:staff \(home)/.hangar/worker/workspaces",
            "/usr/bin/sudo /bin/rm -rf \(IsolationCommand.quote(fixture.oldWork + "/jobs"))",
            "/usr/bin/sudo /bin/rm -rf \(IsolationCommand.quote(fixture.oldWork + "/tmp"))",
            "/bin/rmdir \(IsolationCommand.quote(fixture.oldWork))",
            "/usr/bin/sudo /bin/chmod -N /Users/hangar",
            "/usr/bin/sudo /bin/chmod 700 /Users/hangar",
            "/usr/bin/sudo /usr/bin/install -o hangar -g staff -m 644 \(IsolationCommand.quote(fixture.staging + "/agent.plist")) /Users/hangar/Library/LaunchAgents/app.hangar.worker.plist",
            "/usr/bin/sudo /bin/launchctl print gui/502/app.hangar.worker",
            "/usr/bin/sudo /bin/test -f /Users/hangar/Library/Keychains/login.keychain-db",
            "/bin/rm -f \(IsolationCommand.quote(fixture.invoker.plist))",
            "/bin/rm -f \(IsolationCommand.quote(fixture.invoker.defaultConfig))",
        ])

        // The generated password: saved in the admin's keychain, given to dscl on stdin, shown once, never on argv.
        let saved = store.saved.withLock { $0 }
        #expect(saved.count == 1)
        #expect(saved.first?.account == "hangar")
        #expect(saved.first?.service == "app.hangar.worker-account")
        #expect(saved.first?.password == "pass-word-1")
        #expect(outcome.generatedPassword?.value == "pass-word-1")
        #expect(outcome.createdAccount && outcome.movedWorker)
        #expect(outcome.machineName == "mini-2")
        let dscl = try #require(runner.commands.first { $0.arguments.contains("/usr/bin/dscl") })
        #expect(dscl.input?.value == "passwd /Users/hangar pass-word-1\nquit\n")
        #expect(!runner.commands.contains { $0.arguments.contains("pass-word-1") })
        #expect(!runner.commands.contains { $0.description.contains("pass-word") })
        #expect(output.text.components(separatedBy: "pass-word-1").count == 2, "shown exactly once")
        #expect(output.text.contains("security find-generic-password -s app.hangar.worker-account -a hangar -w"))
        #expect(output.text.contains("log in as hangar once"))
        // The token never reaches a command line.
        #expect(!runner.commands.contains { $0.description.contains("secret-token") })
    }

    @Test func theConfigurationKeepsTheTokenAndMovesTheDataDirectoryIntoTheAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let staged = Mutex<WorkerConfiguration?>(nil)
        let runner = ScriptedRunner()
        runner.on { command, _ in
            // Capture the staged file at the moment sudo install would copy it.
            if command.arguments.contains("600"), let path = command.arguments.dropLast().last {
                staged.withLock { $0 = try? WorkerConfiguration.load(from: path) }
                let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
                #expect(mode == 0o600)
            }
            return nil
        }
        Self.freshMac(runner)
        _ = try await Self.isolation(fixture, runner: runner).run()
        let configuration = try #require(staged.withLock { $0 })
        #expect(configuration.token == "secret-token")
        #expect(configuration.serverURL == Self.server)
        #expect(configuration.dataDirectory == "/Users/hangar/Library/Application Support/Hangar/worker")
        #expect(configuration.workDirectory == "/Users/hangar/.hangar/worker")
        #expect(configuration.resolvedWorkDirectory == "/Users/hangar/.hangar/worker")
        #expect(!FileManager.default.fileExists(atPath: fixture.staging + "/config.json"), "the staged copy is removed")
    }

    @Test func anOlderWorkersCacheInTheDataDirectoryMovesTooAndTheAccountsOwnAppsAreKept() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let files = FileManager.default
        // A worker that ran before the work directory existed left apps in the data directory; legilo is in both.
        try files.createDirectory(atPath: fixture.oldData + "/workspaces/legilo/DerivedData", withIntermediateDirectories: true)
        try files.createDirectory(atPath: fixture.oldData + "/workspaces/other/DerivedData", withIntermediateDirectories: true)
        try files.createDirectory(atPath: fixture.oldWork + "/workspaces/kept", withIntermediateDirectories: true)
        try files.createDirectory(atPath: fixture.oldData + "/jobs/older-job", withIntermediateDirectories: true)
        let runner = ScriptedRunner()
        // hangar already has kept/ from an earlier run.
        runner.on { command, _ in
            command.arguments == ["/usr/bin/sudo", "/bin/test", "-e", "/Users/hangar/.hangar/worker/workspaces/kept"]
                ? IsolationResult(exitCode: 0) : nil
        }
        Self.freshMac(runner)
        let output = Lines()
        _ = try await Self.isolation(fixture, runner: runner, output: output).run()

        let destination = "/Users/hangar/.hangar/worker/workspaces"
        let moves = runner.changes.filter { $0.contains("/bin/mv ") }
        #expect(moves == [
            "/usr/bin/sudo /bin/mv \(IsolationCommand.quote(fixture.oldWork + "/workspaces/legilo")) \(destination)/legilo",
            "/usr/bin/sudo /bin/mv \(IsolationCommand.quote(fixture.oldData + "/workspaces/other")) \(destination)/other",
        ])
        #expect(output.text.contains("hangar already has \(destination)/kept"))
        #expect(output.text.contains("hangar already has \(destination)/legilo; leaving \(fixture.oldData)/workspaces/legilo"))
        let drop = try #require(runner.changes.first { $0.hasPrefix("/usr/bin/sudo /bin/rm -rf \(destination)") })
        #expect(drop.contains("\(destination)/legilo/DerivedData/Build") && drop.contains("\(destination)/other/DerivedData/Build"))
        #expect(!drop.contains("kept"), "an app hangar already had is not touched")
        #expect(!drop.contains("repositories"), "the git mirrors stay")
        #expect(runner.changes.contains("/usr/bin/sudo /bin/rm -rf \(IsolationCommand.quote(fixture.oldData + "/jobs"))"))
        #expect(runner.changes.contains("/usr/bin/sudo /usr/sbin/chown -R hangar:staff \(destination)"))
    }

    @Test func theDroppedCachesAreWorkDirectoryMigrations() {
        #expect(WorkDirectoryMigration.pathBoundCaches == [
            "DerivedData/Build",
            "DerivedData/SourcePackages/workspace-state.json",
            "DerivedData/SourcePackages/artifacts",
            "DerivedData/SourcePackages/checkouts",
        ])
    }

    @Test func anOldWorkDirectoryComesFromTheConfigurationOrTheDefaultUnderTheInvokersHome() {
        let data = "/Users/adam/Library/Application Support/Hangar/worker"
        let plain = WorkerConfiguration(serverURL: Self.server, token: "t", dataDirectory: data)
        #expect(WorkerIsolation.oldWorkDirectory(of: plain, home: "/Users/adam") == "/Users/adam/.hangar/worker")
        let custom = WorkerConfiguration(serverURL: Self.server, token: "t", dataDirectory: data, workDirectory: "/Volumes/Fast/ci/")
        #expect(WorkerIsolation.oldWorkDirectory(of: custom, home: "/Users/adam") == "/Volumes/Fast/ci")
    }

    @Test func aRunningAgentIsStoppedWithSIGTERMAndTheNewProcessIsAwaited() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments == ["/usr/bin/id", "-u", "hangar"] ? IsolationResult(exitCode: 0, output: "502") : nil }
        // pid 700 until two polls after the SIGTERM, then launchd's KeepAlive has started pid 701.
        runner.on { command, seen in
            guard command.arguments.contains("print") else { return nil }
            guard let kill = seen.firstIndex(where: { $0.arguments.contains("SIGTERM") }) else {
                return IsolationResult(exitCode: 0, output: "state = running\npid = 700")
            }
            let after = seen[(kill + 1)...].filter { $0.arguments.contains("print") }.count
            return IsolationResult(exitCode: 0, output: after > 2 ? "state = running\npid = 701" : "state = running\npid = 700")
        }
        Self.freshMac(runner, sessionAfterPolls: 0)
        _ = try await Self.isolation(fixture, runner: runner).run()
        let launchctl = runner.changes.filter { $0.contains("launchctl") && !$0.contains("print") }
        #expect(launchctl == [
            "/bin/launchctl bootout gui/501/app.hangar.worker",
            "/usr/bin/sudo /bin/launchctl kill SIGTERM gui/502/app.hangar.worker",
        ], "the new process is already running: no kickstart")
    }

    @Test func anAgentThatIgnoresSIGTERMIsRestartedForcibly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments == ["/usr/bin/id", "-u", "hangar"] ? IsolationResult(exitCode: 0, output: "502") : nil }
        runner.on { command, _ in
            command.arguments.contains("print") ? IsolationResult(exitCode: 0, output: "state = running\npid = 700") : nil
        }
        Self.freshMac(runner, sessionAfterPolls: 0)
        let output = Lines()
        _ = try await Self.isolation(fixture, runner: runner, output: output).run()
        #expect(runner.changes.contains("/usr/bin/sudo /bin/launchctl kickstart -k gui/502/app.hangar.worker"))
        #expect(output.text.contains("did not stop after SIGTERM"))
    }

    @Test func aPidComesFromLaunchctlPrint() {
        #expect(WorkerIsolation.pid(launchctlPrint: "gui/502/app.hangar.worker = {\n\tstate = running\n\tpid = 4242\n}") == 4242)
        #expect(WorkerIsolation.pid(launchctlPrint: "state = not running") == nil)
    }

    @Test func anExistingLoggedInAccountIsReusedWithoutANewPassword() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments == ["/usr/bin/id", "-u", "hangar"] ? IsolationResult(exitCode: 0, output: "502") : nil }
        Self.freshMac(runner, sessionAfterPolls: 0)
        let store = MemoryPasswordStore()
        let output = Lines()
        let outcome = try await Self.isolation(fixture, runner: runner, store: store, output: output).run()
        #expect(!runner.changes.contains { $0.contains("sysadminctl") || $0.contains("dscl") })
        #expect(store.saved.withLock { $0.isEmpty })
        #expect(outcome.generatedPassword == nil && !outcome.createdAccount)
        #expect(!output.text.contains("log in as hangar once"), "already logged in: no instructions")
        // Restarted onto the new binary with SIGTERM, which the worker handles gracefully; never killed outright.
        #expect(runner.changes.contains("/usr/bin/sudo /bin/launchctl kill SIGTERM gui/502/app.hangar.worker"))
        #expect(!runner.changes.contains { $0.contains("kickstart -k") })
        #expect(!runner.changes.contains { $0.contains("bootstrap") })
    }

    @Test func aSessionWithoutTheAgentGetsItBootstrappedAtOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments == ["/usr/bin/id", "-u", "hangar"] ? IsolationResult(exitCode: 0, output: "502") : nil }
        runner.on { command, seen in
            guard command.arguments.contains("print") else { return nil }
            return seen.contains { $0.arguments.contains("bootstrap") } ? IsolationResult(exitCode: 0, output: "state = running") : IsolationResult(exitCode: 113)
        }
        Self.freshMac(runner, sessionAfterPolls: 0)
        _ = try await Self.isolation(fixture, runner: runner).run()
        #expect(runner.changes.filter { $0.contains("launchctl") && !$0.contains("print") } == [
            "/bin/launchctl bootout gui/501/app.hangar.worker",
            "/usr/bin/sudo /bin/launchctl bootstrap gui/502 /Users/hangar/Library/LaunchAgents/app.hangar.worker.plist",
        ])
    }

    @Test func resetPasswordGivesAnExistingAccountANewOne() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments == ["/usr/bin/id", "-u", "hangar"] ? IsolationResult(exitCode: 0, output: "502") : nil }
        Self.freshMac(runner, sessionAfterPolls: 0)
        let store = MemoryPasswordStore()
        let outcome = try await Self.isolation(
            fixture, runner: runner, options: IsolationOptions(serverData: "", resetPassword: true), store: store
        ).run()
        #expect(!runner.changes.contains { $0.contains("sysadminctl") })
        #expect(runner.changes.contains("/usr/bin/sudo /usr/bin/dscl . <<< <redacted>"))
        #expect(store.saved.withLock { $0.map(\.password) } == ["pass-word-1"])
        #expect(outcome.generatedPassword?.value == "pass-word-1")
    }

    @Test func anAgentTheLoginDidNotLoadIsBootstrapped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, seen in
            guard command.arguments.contains("print") else { return nil }
            let bootstrapped = seen.contains { $0.arguments.contains("bootstrap") }
            return bootstrapped ? IsolationResult(exitCode: 0, output: "state = running") : IsolationResult(exitCode: 113)
        }
        Self.freshMac(runner)
        _ = try await Self.isolation(fixture, runner: runner).run()
        #expect(runner.changes.filter { $0.contains("bootstrap") } == [
            "/usr/bin/sudo /bin/launchctl bootstrap gui/502 /Users/hangar/Library/LaunchAgents/app.hangar.worker.plist"
        ])
    }

    @Test func installScriptConfigurationIsMovedButLeftForTheScriptToDelete() async throws {
        let fixture = try Fixture(withOldAgent: false, withConfig: false)
        defer { fixture.cleanUp() }
        let enrolled = fixture.root + "/enrolled.json"
        try WorkerConfiguration(serverURL: Self.server, token: "fresh-token", dataDirectory: "/Users/hangar/x").write(to: enrolled)
        let runner = ScriptedRunner()
        Self.freshMac(runner)
        _ = try await Self.isolation(
            fixture, runner: runner, options: IsolationOptions(sourceConfig: enrolled, binary: fixture.binary, serverData: "")
        ).run()
        #expect(!runner.changes.contains { $0.contains("bootout") }, "no old agent to stop")
        #expect(!runner.changes.contains { $0.hasPrefix("/bin/rm -f") })
        #expect(runner.changes.contains { $0.contains("-m 600") })
    }

    @Test func withNothingToMoveTheAccountsOwnConfigurationIsKept() async throws {
        let fixture = try Fixture(withOldAgent: false, withConfig: false)
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments == ["/usr/bin/id", "-u", "hangar"] ? IsolationResult(exitCode: 0, output: "502") : nil }
        Self.freshMac(runner, sessionAfterPolls: 0)
        runner.on { command, _ in
            command.arguments.contains("check") ? IsolationResult(exitCode: 0, output: "mini-2") : nil
        }
        _ = try await Self.isolation(fixture, runner: runner).run()
        #expect(runner.changes.contains("/usr/bin/sudo /bin/test -f '/Users/hangar/Library/Application Support/Hangar/worker/config.json'"))
        #expect(!runner.changes.contains { $0.contains("-m 600") })
        #expect(runner.changes.contains {
            $0 == "/usr/bin/sudo -u hangar -H /Users/hangar/.local/bin/hangar-worker check --config '/Users/hangar/Library/Application Support/Hangar/worker/config.json'"
        })
    }

    @Test func noWaitStopsAtTheLoginWithTheWorkerInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        Self.freshMac(runner, sessionAfterPolls: 100)
        let outcome = try await Self.isolation(fixture, runner: runner, options: IsolationOptions(serverData: "", noWait: true)).run()
        #expect(!outcome.movedWorker)
        #expect(runner.changes.last?.contains("app.hangar.worker.plist") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.invoker.plist), "the old plist stays until the move is confirmed")
    }

    // MARK: Stops

    @Test func aRefusedTokenChangesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        await #expect(throws: IsolationError.self) {
            try await Self.isolation(fixture, runner: runner, check: { _, _ in .unauthorized }).run()
        }
        #expect(runner.commands.isEmpty)
    }

    @Test(arguments: [
        (name: "adam", uid: UInt32(0), admin: true, message: "without sudo"),
        (name: "hangar", uid: UInt32(502), admin: true, message: "already the hangar user"),
        (name: "guest", uid: UInt32(503), admin: false, message: "HANGAR_AS_CURRENT_USER=1"),
    ])
    func refusesTheWrongInvoker(name: String, uid: UInt32, admin: Bool, message: String) async throws {
        let fixture = try Fixture(isAdmin: admin, name: name, uid: uid)
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        do {
            _ = try await Self.isolation(fixture, runner: runner).run()
            Issue.record("expected a refusal")
        } catch let error as IsolationError {
            #expect(error.description.contains(message))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test func aReadableServerKeyStopsBeforeAnythingMoves() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let serverData = fixture.invoker.defaultServerData
        try FileManager.default.createDirectory(atPath: serverData, withIntermediateDirectories: true)
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments.contains("-r") ? IsolationResult(exitCode: 0) : nil }
        Self.freshMac(runner)
        do {
            _ = try await Self.isolation(fixture, runner: runner, options: IsolationOptions()).run()
            Issue.record("expected a stop")
        } catch let error as IsolationError {
            #expect(error.description.contains("chmod 700"))
        }
        #expect(runner.changes.contains("/usr/bin/sudo -u hangar /bin/test -r \(IsolationCommand.quote(serverData + "/master.key"))"))
        #expect(!runner.changes.contains { $0.contains("bootout") || $0.contains("/usr/bin/install") || $0.contains("/bin/mv") })
    }

    @Test func aPasswordThatDidNotTakeStops() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        Self.freshMac(runner)
        do {
            _ = try await Self.isolation(fixture, runner: runner, verifier: FixedVerifier(accepts: false)).run()
            Issue.record("expected a stop")
        } catch let error as IsolationError {
            #expect(error.description.contains("--reset-password"))
        }
        #expect(!runner.changes.contains { $0.contains("bootout") })
    }

    @Test func noHeartbeatFromTheAccountKeepsTheOldAgentsPlist() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        Self.freshMac(runner)
        do {
            _ = try await Self.isolation(
                fixture, runner: runner, check: { _, _ in .accepted(Self.machine(runningUser: "adam", lastSeen: Self.start)) }
            ).run()
            Issue.record("expected a stop")
        } catch let error as IsolationError {
            #expect(error.description.contains("launchctl bootstrap gui/501"))
        }
        #expect(!runner.changes.contains { $0.hasPrefix("/bin/rm -f") })
    }

    @Test func aHeartbeatFromAnOlderServerCountsOnlyAfterTheOldAgentStopped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        Self.freshMac(runner)
        _ = try await Self.isolation(
            fixture, runner: runner,
            check: { _, call in
                .accepted(Self.machine(runningUser: nil, lastSeen: call < 3 ? Self.start : Self.start.addingTimeInterval(30)))
            }
        ).run()
        #expect(runner.changes.contains { $0.hasPrefix("/bin/rm -f") })
    }

    @Test func aWorkerThatWillNotStopIsReported() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.on { command, _ in command.arguments.first == "/usr/bin/pgrep" ? IsolationResult(exitCode: 0, output: "123") : nil }
        Self.freshMac(runner)
        do {
            _ = try await Self.isolation(fixture, runner: runner).run()
            Issue.record("expected a stop")
        } catch let error as IsolationError {
            #expect(error.description.contains("still running"))
        }
        #expect(!runner.changes.contains { $0.contains("/usr/bin/install") })
    }

    @Test func theLoginWaitGivesUpAfterItsLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        Self.freshMac(runner, sessionAfterPolls: 1000)
        await #expect(throws: IsolationError.self) { try await Self.isolation(fixture, runner: runner).run() }
        #expect(FileManager.default.fileExists(atPath: fixture.invoker.plist))
    }

    // MARK: Dry run

    @Test func aDryRunOnlyRunsProbes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let live = ScriptedRunner()
        Self.freshMac(live)
        let printed = Lines()
        let store = MemoryPasswordStore()
        let isolation = WorkerIsolation(
            invoker: fixture.invoker, options: IsolationOptions(dryRun: true, serverData: ""),
            dependencies: .init(
                runner: DryRunRunner(live: live, print: { printed.append($0) }), passwords: store,
                verifier: FixedVerifier(accepts: false), generator: SequenceGenerator(),
                check: { _ in .unauthorized }, sleep: { _ in }, now: { Self.start }, say: { printed.append($0) },
                stagingDirectory: fixture.staging, ownExecutable: fixture.binary))
        let outcome = try await isolation.run()
        #expect(live.commands.allSatisfy { $0.kind == .probe && !$0.isPrivileged })
        #expect(store.saved.withLock { $0.isEmpty })
        #expect(printed.text.contains("would run: /usr/bin/sudo /usr/sbin/sysadminctl -addUser hangar"))
        #expect(printed.text.contains("would run: /usr/bin/sudo /bin/mv"))
        #expect(printed.text.contains("would save the generated password"))
        #expect(!printed.text.contains("pass-word"))
        #expect(printed.text.contains("End of the dry run"))
        #expect(outcome.movedWorker)
        // Nothing on disk changed.
        #expect(FileManager.default.fileExists(atPath: fixture.invoker.plist))
        #expect(FileManager.default.fileExists(atPath: fixture.oldWork + "/workspaces/legilo/DerivedData"))
        #expect(FileManager.default.fileExists(atPath: fixture.oldWork + "/jobs/old-job"))
        #expect(printed.text.contains("would run: /usr/bin/sudo /bin/rm -rf /Users/hangar/.hangar/worker/workspaces/legilo/DerivedData/Build"))
    }

    // MARK: Pieces

    @Test func generatedPasswordsAreLongGroupedAndUnambiguous() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let password = RandomPasswordGenerator().generate().value
            #expect(password.wholeMatch(of: /[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){4}/) != nil)
            seen.insert(password)
        }
        #expect(seen.count == 200)
        #expect(RandomPasswordGenerator.alphabet.count == 31)
        #expect("\(SensitiveText("x"))" == "<redacted>")
    }

    @Test func aSessionIsALoginwindowOrDockOwnedByTheUser() {
        let ps = """
              0 /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow
            501 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
            5020 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
            502 /usr/libexec/trustd
            """
        #expect(WorkerIsolation.hasGraphicalSession(psOutput: ps, uid: "501"))
        #expect(!WorkerIsolation.hasGraphicalSession(psOutput: ps, uid: "502"))
        #expect(WorkerIsolation.hasGraphicalSession(psOutput: ps + "\n  502 /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", uid: "502"))
    }

    @Test func runningMeansLaunchctlSaysSo() {
        #expect(WorkerIsolation.isRunning(launchctlPrint: "gui/502/app.hangar.worker = {\n\tactive count = 1\n\tstate = running\n}"))
        #expect(!WorkerIsolation.isRunning(launchctlPrint: "gui/502/app.hangar.worker = {\n\tstate = not running\n}"))
    }

    @Test func theLaunchAgentHasTheInstallScriptsKeys() throws {
        let text = WorkerLaunchAgent.plist(binary: "/Users/hangar/.local/bin/hangar-worker", logs: "/Users/hangar/Library/Logs/Hangar")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "app.hangar.worker")
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/hangar/.local/bin/hangar-worker", "run"])
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["UserName"] == nil)
        #expect(plist["StandardOutPath"] as? String == "/Users/hangar/Library/Logs/Hangar/worker.log")
    }

    @Test func theOldAgentsConfigComesFromItsArguments() throws {
        let root = NSTemporaryDirectory() + "hangar-agent-" + UUID().uuidString + ".plist"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plist: [String: Any] = ["Label": "app.hangar.worker", "ProgramArguments": ["/usr/local/bin/hangar-worker", "run", "--config", "/etc/w.json"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: root))
        #expect(WorkerIsolation.readOldAgent(at: root) == .init(program: "/usr/local/bin/hangar-worker", config: "/etc/w.json"))
        #expect(WorkerIsolation.readOldAgent(at: root + ".missing") == nil)
    }

    @Test func commandsQuoteAndRedact() {
        let command = IsolationCommand(["/bin/echo", "a b", "it's", "secret"], kind: .change, input: SensitiveText("x"), redactedArguments: ["secret"])
        #expect(command.description == #"/bin/echo 'a b' 'it'\''s' <redacted> <<< <redacted>"#)
        #expect(IsolationCommand.sudo("-v").isPrivileged)
        #expect(!IsolationCommand.probe("/usr/bin/id").isPrivileged)
    }

    @Test func theTerminalRunnerFeedsInputAndCapturesOutput() throws {
        let runner = TerminalRunner()
        let echoed = try runner.run(IsolationCommand(["/bin/cat"], kind: .probe, input: SensitiveText("hello\n"), capturesOutput: true))
        #expect(echoed == IsolationResult(exitCode: 0, output: "hello"))
        #expect(try runner.run(.probe("/usr/bin/false")).exitCode == 1)
        #expect(try runner.run(.probe("/bin/sh", "-c", "exit 7")).exitCode == 7)
    }
}
