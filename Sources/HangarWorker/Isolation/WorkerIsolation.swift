import Foundation
import HangarCore

/// Where the dedicated build account keeps the worker. Defaults are the `hangar` user's.
public struct IsolationLayout: Sendable, Equatable {
    public var user: String
    public var home: String
    /// Where the worker's LaunchDaemon plist goes; another directory only in tests.
    public var launchDaemons: String

    public init(
        user: String = WorkerPrivacy.dedicatedUser, home: String = WorkerPrivacy.dedicatedHome,
        launchDaemons: String = WorkerLaunchDaemon.directory
    ) {
        self.user = user
        self.home = home
        self.launchDaemons = launchDaemons
    }

    public var binDirectory: String { home + "/.local/bin" }
    public var binary: String { binDirectory + "/hangar-worker" }
    public var supportDirectory: String { home + "/Library/Application Support/Hangar" }
    public var dataDirectory: String { supportDirectory + "/worker" }
    public var config: String { dataDirectory + "/config.json" }
    /// Checkouts, DerivedData, job directories and each job's `TMPDIR`: the work directory a worker with the
    /// default data directory uses (`WorkerConfiguration.defaultWorkDirectory`), without spaces.
    public var workDirectory: String { home + "/.hangar/worker" }
    public var workspaces: String { workDirectory + "/workspaces" }
    public var logs: String { home + "/Library/Logs/Hangar" }
    public var keychains: String { home + "/Library/Keychains" }
    /// The CI keychain and its password file (in `dataDirectory`).
    public var keychain: CIKeychain { CIKeychain(home: home) }
    /// The launch agent an older `isolate` installed in the account (0.8 and before); the daemon replaces it.
    public var legacyAgentPlist: String { home + "/Library/LaunchAgents/" + WorkerLaunchAgent.label + ".plist" }
    public var daemonPlist: String { launchDaemons + "/" + WorkerLaunchDaemon.label + ".plist" }
}

/// The user running `hangar-worker isolate`: the administrator at the Mac, whose worker (if any) moves.
public struct IsolationInvoker: Sendable, Equatable {
    public var name: String
    public var uid: UInt32
    public var home: String
    public var isAdmin: Bool

    public init(name: String, uid: UInt32, home: String, isAdmin: Bool) {
        self.name = name
        self.uid = uid
        self.home = home
        self.isAdmin = isAdmin
    }

    public var plist: String { home + "/Library/LaunchAgents/" + WorkerLaunchAgent.label + ".plist" }
    public var defaultConfig: String { home + "/Library/Application Support/Hangar/worker/config.json" }
    public var defaultServerData: String { home + "/Library/Application Support/Hangar/server" }
}

public struct IsolationOptions: Sendable, Equatable {
    /// Print the changes instead of making them.
    public var dryRun = false
    /// The configuration (with the machine token) to move into the account; nil means the invoker's own worker
    /// configuration when it exists. The install script passes the one it just enrolled.
    public var sourceConfig: String?
    /// The `hangar-worker` to copy into the account; nil means the invoker's agent's program, or else this
    /// executable.
    public var binary: String?
    /// The server's data directory on this Mac, checked to be unreadable by the account; nil means the invoker's
    /// default, and that is skipped when it does not exist. Empty skips the check.
    public var serverData: String?
    /// Give an existing account a new generated password.
    public var resetPassword = false

    public init(
        dryRun: Bool = false, sourceConfig: String? = nil, binary: String? = nil, serverData: String? = nil,
        resetPassword: Bool = false
    ) {
        self.dryRun = dryRun
        self.sourceConfig = sourceConfig
        self.binary = binary
        self.serverData = serverData
        self.resetPassword = resetPassword
    }
}

public struct IsolationError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// `hangar-worker isolate`: moves this Mac's worker onto the dedicated, unprivileged `hangar` user, as automatically
/// as macOS allows (worker isolation design).
///
/// Run by an administrator in Terminal, without sudo; it asks sudo for each privileged step. In order: create the
/// account with a generated password (stored in the administrator's login keychain and shown once; nobody logs in
/// with it), install a copy of the worker, the configuration (same machine token, data and work directories
/// rewritten) and the build cache (checkouts and DerivedData, moved into the account's work directory as
/// `WorkDirectoryMigration` would) into that account, lock its home to 0700, create its CI keychain (`CIKeychain`),
/// and install and start the worker as a LaunchDaemon that runs as `hangar` from boot without a login. It then
/// confirms the daemon runs and the server sees the machine heartbeat from it, and removes the old agent and
/// configuration. An account set up by an older version (a launch agent in its login session) loses that agent on the
/// way. Each step is idempotent, so running it again resumes.
public struct WorkerIsolation: Sendable {
    public struct Dependencies: Sendable {
        public var runner: any IsolationRunner
        public var passwords: any AccountPasswordStore
        public var verifier: any AccountPasswordVerifier
        public var generator: any PasswordGenerating
        public var check: @Sendable (WorkerConfiguration) async -> WorkerCheck.Outcome
        public var sleep: @Sendable (Duration) async -> Void
        public var now: @Sendable () -> Date
        public var say: @Sendable (String) -> Void
        /// Where the configuration and plist are staged before `sudo install` puts them in place; private to the
        /// invoker.
        public var stagingDirectory: String
        /// The executable running `isolate`, the binary copied when nothing else is given.
        public var ownExecutable: String?

        public init(
            runner: any IsolationRunner, passwords: any AccountPasswordStore, verifier: any AccountPasswordVerifier,
            generator: any PasswordGenerating, check: @escaping @Sendable (WorkerConfiguration) async -> WorkerCheck.Outcome,
            sleep: @escaping @Sendable (Duration) async -> Void, now: @escaping @Sendable () -> Date,
            say: @escaping @Sendable (String) -> Void, stagingDirectory: String, ownExecutable: String?
        ) {
            self.runner = runner
            self.passwords = passwords
            self.verifier = verifier
            self.generator = generator
            self.check = check
            self.sleep = sleep
            self.now = now
            self.say = say
            self.stagingDirectory = stagingDirectory
            self.ownExecutable = ownExecutable
        }
    }

    /// How often and how long the waits poll.
    public struct Timing: Sendable {
        public var poll: Duration = .seconds(3)
        /// Waiting for the old agent's process to exit after bootout, and for a restarted worker's new process.
        public var oldAgentPolls = 20
        /// Waiting for the daemon to be running.
        public var workerRunningPolls = 20
        /// Waiting for the server to see a heartbeat from the account.
        public var heartbeatPolls = 30
        public init() {}
    }

    /// What a finished run did.
    public struct Outcome: Sendable, Equatable {
        public var createdAccount: Bool
        /// The password shown to the operator in this run, if one was generated.
        public var generatedPassword: SensitiveText?
        public var movedWorker: Bool
        public var machineName: String?
    }

    public let layout: IsolationLayout
    public let invoker: IsolationInvoker
    public let options: IsolationOptions
    public let dependencies: Dependencies
    public var timing = Timing()

    public init(
        layout: IsolationLayout = IsolationLayout(), invoker: IsolationInvoker, options: IsolationOptions,
        dependencies: Dependencies
    ) {
        self.layout = layout
        self.invoker = invoker
        self.options = options
        self.dependencies = dependencies
    }

    private var runner: any IsolationRunner { dependencies.runner }
    private func say(_ line: String) { dependencies.say(line) }
    private var dryRun: Bool { options.dryRun }

    /// The old agent, read from the invoker's plist.
    struct OldAgent: Equatable {
        var program: String
        var config: String?
    }

    // MARK: Run

    public func run() async throws -> Outcome {
        // 1. Preflight: nothing changes until everything that can be checked as the invoker passes.
        guard invoker.uid != 0 else {
            throw IsolationError("Run hangar-worker isolate as yourself, without sudo. It asks for your password when it needs sudo.")
        }
        guard invoker.name != layout.user else {
            throw IsolationError("This is already the \(layout.user) user. Run hangar-worker isolate from an administrator's account.")
        }
        guard invoker.isAdmin else {
            throw IsolationError("\(invoker.name) is not an administrator, and creating the \(layout.user) user needs one. Run this from an administrator's account, or install as the current user with HANGAR_AS_CURRENT_USER=1.")
        }
        let oldAgent = Self.readOldAgent(at: invoker.plist)
        let sourcePath = options.sourceConfig ?? oldAgent?.config ?? invoker.defaultConfig
        let source: WorkerConfiguration?
        if FileManager.default.fileExists(atPath: sourcePath) {
            source = try WorkerConfiguration.load(from: sourcePath)
        } else if options.sourceConfig != nil {
            throw IsolationError("No worker configuration at \(sourcePath).")
        } else {
            source = nil
        }
        let binary = try resolveBinary(oldAgent: oldAgent)
        var machineName: String?
        if let source {
            switch await dependencies.check(source) {
            case .accepted(let machine):
                machineName = machine.name
                say("\(source.serverURL.absoluteString) accepts this Mac as \(machine.name); the same machine moves to the \(layout.user) user.")
            case let outcome where dryRun:
                say("warning: " + outcome.message(server: source.serverURL) + " A real run stops here.")
            case let outcome:
                throw IsolationError(outcome.message(server: source.serverURL) + " Nothing was changed.")
            }
        }
        if dryRun { say("Dry run: nothing is changed. These are the steps:") }

        // 2. sudo, once up front so its prompt comes with an explanation.
        say("Creating and setting up the \(layout.user) user needs an administrator. macOS asks for your (\(invoker.name)'s) password.")
        try require(.sudo("-v"), "sudo")

        // 3. The account.
        var uid = probeUID()
        var password: SensitiveText?
        var createdAccount = false
        if uid == nil {
            password = try createAccount()
            createdAccount = true
            uid = dryRun ? "<\(layout.user)-uid>" : probeUID()
            guard uid != nil else {
                throw IsolationError("sysadminctl did not create the \(layout.user) user. Check System Settings › Users & Groups, then run this again.")
            }
        } else if options.resetPassword {
            password = try setNewPassword()
        } else {
            say("The \(layout.user) user exists (uid \(uid!)).")
        }
        if let password, !dryRun { showPassword(password) }
        let accountUID = uid!
        try require(.sudo("/usr/sbin/createhomedir", "-c", "-u", layout.user), "create the \(layout.user) home")

        // 4. The server's data must not be readable by the account, checked before anything moves.
        try checkServerData()

        // 5. Xcode's first launch is system-wide; done once per Mac as root.
        try xcodeFirstLaunch()

        // 6. Move the worker into the account.
        if let oldAgent { try await stopOldAgent(oldAgent) }
        try removeLegacyAgent(uid: accountUID)
        let stoppedAt = dependencies.now()
        try makeDirectories()
        try require(
            .sudo("/usr/bin/install", "-o", layout.user, "-g", "staff", "-m", "755", binary, layout.binary),
            "copy hangar-worker into \(layout.binDirectory)")
        if let source {
            try installConfiguration(source)
            try moveCache(from: source)
        } else {
            guard dryRun || runner.succeeds(.sudo("/bin/test", "-f", layout.config)) else {
                throw IsolationError("There is no worker configuration to move and \(layout.user) has none either. Install with the curl command from Hangar › Machines › Add Mac; it enrolls this Mac and runs this step.")
            }
            say("Keeping \(layout.user)'s worker configuration.")
        }
        try lockDownHome()
        try setUpKeychain()

        // 7. The LaunchDaemon: the worker runs as the account from boot, with no login.
        let plistChanged = try installDaemon()
        try await startDaemon(plistChanged: plistChanged)

        // 8. The server must see the machine heartbeat from the daemon; then the old agent goes.
        try await confirmHeartbeat(source: source, since: stoppedAt)
        if oldAgent != nil {
            try require(.change("/bin/rm", "-f", invoker.plist), "remove the old launch agent")
        }
        if source != nil, options.sourceConfig == nil {
            try require(.change("/bin/rm", "-f", sourcePath), "remove the old worker configuration (it holds the token)")
        }
        printFollowUps()
        return Outcome(createdAccount: createdAccount, generatedPassword: password, movedWorker: true, machineName: machineName)
    }

    // MARK: Steps

    private func resolveBinary(oldAgent: OldAgent?) throws -> String {
        let candidates = [options.binary, dependencies.ownExecutable, oldAgent?.program].compactMap { $0 }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw IsolationError("No hangar-worker binary to copy. Pass --binary PATH.")
        }
        return URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
    }

    private func probeUID() -> String? {
        guard let result = try? runner.run(.probe("/usr/bin/id", "-u", layout.user)), result.succeeded,
            let uid = UInt32(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return String(uid)
    }

    /// Creates the account with a generated password. The password reaches the system on standard input (dscl)
    /// and is verified through Open Directory; `sysadminctl` only ever sees a throwaway value it is replaced with.
    private func createAccount() throws -> SensitiveText {
        let password = dependencies.generator.generate()
        // Saved first: if anything after this fails, the operator can still look the password up.
        try savePassword(password)
        let throwaway = dependencies.generator.generate().value
        say("Creating the \(layout.user) user (standard account, not an administrator)...")
        try require(
            IsolationCommand(
                [
                    "/usr/bin/sudo", "/usr/sbin/sysadminctl", "-addUser", layout.user, "-fullName", "Hangar",
                    "-shell", "/bin/zsh", "-home", layout.home, "-password", throwaway,
                ], kind: .change, redactedArguments: [throwaway]),
            "create the \(layout.user) user")
        try applyPassword(password)
        return password
    }

    private func setNewPassword() throws -> SensitiveText {
        let password = dependencies.generator.generate()
        try savePassword(password)
        say("Setting a new password for \(layout.user)...")
        try applyPassword(password)
        return password
    }

    private func savePassword(_ password: SensitiveText) throws {
        if dryRun {
            say("  would save the generated password in your login keychain (service \(AccountPasswordItem.service), account \(layout.user))")
            return
        }
        try dependencies.passwords.save(password, account: layout.user, service: AccountPasswordItem.service)
    }

    private func applyPassword(_ password: SensitiveText) throws {
        try require(
            IsolationCommand(
                ["/usr/bin/sudo", "/usr/bin/dscl", "."], kind: .change,
                input: SensitiveText("passwd /Users/\(layout.user) \(password.value)\nquit\n"), quiet: true),
            "set the \(layout.user) password")
        guard dryRun || dependencies.verifier.verify(password, user: layout.user) else {
            throw IsolationError("The \(layout.user) password could not be set. Set one in System Settings › Users & Groups, or run hangar-worker isolate --reset-password.")
        }
    }

    private func checkServerData() throws {
        let directory = options.serverData ?? invoker.defaultServerData
        guard !directory.isEmpty else { return }
        if options.serverData == nil, !FileManager.default.fileExists(atPath: directory) { return }
        let key = directory + "/master.key"
        let readable = !dryRun && runner.succeeds(.sudo("-u", layout.user, "/bin/test", "-r", key))
        if dryRun { say("  would run: sudo -u \(layout.user) /bin/test -r \(IsolationCommand.quote(key)) (must fail)") }
        if readable {
            throw IsolationError("""
                The \(layout.user) user can read the server's master.key. Make the server's data private, then run this again:
                  chmod 700 \(IsolationCommand.quote(directory))
                """)
        }
    }

    private func xcodeFirstLaunch() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild") else { return }
        if (try? runner.run(.probe("/usr/bin/xcodebuild", "-checkFirstLaunchStatus")))?.succeeded == true { return }
        say("Running Xcode's first launch (once per Mac)...")
        try require(.sudo("/usr/bin/xcodebuild", "-runFirstLaunch"), "run xcodebuild -runFirstLaunch")
    }

    private func stopOldAgent(_ agent: OldAgent) async throws {
        say("Stopping this user's worker agent; a build in flight stops with it.")
        _ = try runner.run(.change("/bin/launchctl", "bootout", "gui/\(invoker.uid)/\(WorkerLaunchAgent.label)"))
        if dryRun { return }
        for _ in 0..<timing.oldAgentPolls {
            if !runner.succeeds(.probe("/usr/bin/pgrep", "-U", String(invoker.uid), "-f", "hangar-worker run")) { return }
            await dependencies.sleep(timing.poll)
        }
        throw IsolationError("""
            The old worker (\(agent.program)) is still running as \(invoker.name). Quit it and run this again. To start it again instead:
              launchctl bootstrap gui/\(invoker.uid) \(IsolationCommand.quote(invoker.plist))
            """)
    }

    private func makeDirectories() throws {
        let owner = ["-o", layout.user, "-g", "staff"]
        let privateDirectories = [
            layout.home + "/Library/Application Support", layout.supportDirectory, layout.dataDirectory,
            layout.home + "/.hangar", layout.workDirectory, layout.workspaces, layout.home + "/Library/Logs", layout.logs,
            layout.keychains,
        ]
        try require(
            IsolationCommand(["/usr/bin/sudo", "/usr/bin/install", "-d"] + owner + ["-m", "700"] + privateDirectories, kind: .change),
            "create \(layout.user)'s worker directories")
        try require(
            IsolationCommand(
                ["/usr/bin/sudo", "/usr/bin/install", "-d"] + owner
                    + ["-m", "755", layout.home + "/.local", layout.binDirectory], kind: .change),
            "create \(layout.binDirectory)")
    }

    /// The same machine token and server; the data and work directories are rewritten into the account's home (a
    /// custom one outside it is how files stayed readable, so it is not kept).
    private func installConfiguration(_ source: WorkerConfiguration) throws {
        var moved = source
        moved.dataDirectory = layout.dataDirectory
        moved.workDirectory = layout.workDirectory
        let staged = try stage("config.json") { try moved.write(to: $0) }
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try require(
            .sudo("/usr/bin/install", "-o", layout.user, "-g", "staff", "-m", "600", staged, layout.config),
            "install the worker configuration")
    }

    /// The work directory the invoker's worker used: its configured one, else the default for its data directory
    /// under the invoker's home (`~/.hangar/worker` for the usual one).
    static func oldWorkDirectory(of source: WorkerConfiguration, home: String) -> String {
        if let work = source.workDirectory, !work.isEmpty { return URL(fileURLWithPath: work).standardizedFileURL.path }
        return WorkerConfiguration.defaultWorkDirectory(for: source.dataDirectory, home: home)
    }

    /// Moves the build cache (each app's checkout and DerivedData) into the account's work directory so the next
    /// build fetches instead of cloning. Like `WorkDirectoryMigration` within one user: from the old work directory,
    /// and from the old data directory for a worker that never ran with a separate one; an app the account already
    /// has keeps its copy; after the move the parts of DerivedData that name the old absolute path are dropped
    /// (`WorkDirectoryMigration.pathBoundCaches`; the git mirrors in `SourcePackages/repositories` stay). Then all of
    /// it is given to the account. Leftover `jobs/` and `tmp/` are removed.
    private func moveCache(from source: WorkerConfiguration) throws {
        let oldData = URL(fileURLWithPath: source.dataDirectory).standardizedFileURL.path
        let oldWork = Self.oldWorkDirectory(of: source, home: invoker.home)
        let roots = oldWork == oldData ? [oldWork] : [oldWork, oldData]
        let files = FileManager.default
        var present = Set<String>()
        var moved: [String] = []
        for root in roots where root + "/workspaces" != layout.workspaces {
            let workspaces = root + "/workspaces"
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: workspaces, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let names = ((try? files.contentsOfDirectory(atPath: workspaces)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            let sameVolume = Self.sameVolume(workspaces, (layout.home as NSString).deletingLastPathComponent)
            for name in names {
                let from = workspaces + "/" + name
                let to = layout.workspaces + "/" + name
                if present.contains(name) || (!dryRun && runner.succeeds(.sudo("/bin/test", "-e", to))) {
                    say("\(layout.user) already has \(to); leaving \(from) where it is.")
                    present.insert(name)
                    continue
                }
                if moved.isEmpty { say("Moving the build cache (checkouts and DerivedData) to \(layout.workDirectory)...") }
                if sameVolume {
                    try require(.sudo("/bin/mv", from, to), "move the build cache of \(name)")
                } else {
                    say("Copying \(name) to another volume; it takes twice its size until the copy is removed.")
                    try require(.sudo("/usr/bin/ditto", from, to), "copy the build cache of \(name)")
                    try require(.sudo("/bin/rm", "-rf", from), "remove the old build cache of \(name)")
                }
                present.insert(name)
                moved.append(to)
            }
            // Gone when everything moved; an app left in place keeps it.
            _ = try runner.run(IsolationCommand(["/bin/rmdir", workspaces], kind: .change, quiet: true))
        }
        if !moved.isEmpty {
            say("Dropping the parts of DerivedData that name the old path; the next build redoes them once.")
            let pathBound = moved.flatMap { workspace in WorkDirectoryMigration.pathBoundCaches.map { workspace + "/" + $0 } }
            try require(
                IsolationCommand(["/usr/bin/sudo", "/bin/rm", "-rf"] + pathBound, kind: .change),
                "drop the path-bound DerivedData caches")
            try require(
                .sudo("/usr/sbin/chown", "-R", "\(layout.user):staff", layout.workspaces),
                "give the build cache to \(layout.user)")
        }
        var leftovers = [oldWork + "/jobs", oldWork + "/tmp"]
        if oldData != oldWork { leftovers.append(oldData + "/jobs") }
        for path in leftovers where files.fileExists(atPath: path) {
            try require(.sudo("/bin/rm", "-rf", path), "remove leftover job files in \(path)")
        }
        if oldWork != oldData, files.fileExists(atPath: oldWork) {
            _ = try runner.run(IsolationCommand(["/bin/rmdir", oldWork], kind: .change, quiet: true))
        }
    }

    private func lockDownHome() throws {
        // chmod -N fails when there is no ACL to remove; that is fine.
        _ = try runner.run(IsolationCommand(["/usr/bin/sudo", "/bin/chmod", "-N", layout.home], kind: .change, quiet: true))
        try require(.sudo("/bin/chmod", "700", layout.home), "set \(layout.home) to mode 0700")
        if !dryRun, access(layout.home, X_OK) == 0 {
            throw IsolationError("\(invoker.name) can still open \(layout.home) after chmod 700; check its ACL with ls -le /Users.")
        }
    }

    /// A `hangar` set up by an older version runs the worker as a launch agent in its login session. The daemon
    /// replaces it: the agent is booted out (SIGTERM: a build in flight stops and reports why) and its plist removed,
    /// so a later login as `hangar` does not start a second worker with the same token.
    private func removeLegacyAgent(uid: String) throws {
        let target = "gui/\(uid)/\(WorkerLaunchAgent.label)"
        if dryRun {
            say("  if \(layout.user) has an older version's launch agent (\(IsolationCommand.quote(layout.legacyAgentPlist))):")
            say("    would run: /usr/bin/sudo /bin/launchctl bootout \(target)")
            say("    would run: /usr/bin/sudo /bin/rm -f \(IsolationCommand.quote(layout.legacyAgentPlist))")
            return
        }
        guard runner.succeeds(.sudo("/bin/test", "-f", layout.legacyAgentPlist)) else { return }
        say("\(layout.user) runs the worker as a launch agent in its login session (an older version); it moves to a LaunchDaemon, which needs no login.")
        let print = IsolationCommand(["/usr/bin/sudo", "/bin/launchctl", "print", target], kind: .probe, capturesOutput: true, quiet: true)
        if runner.succeeds(print) {
            try require(.sudo("/bin/launchctl", "bootout", target), "stop \(layout.user)'s launch agent")
        }
        try require(.sudo("/bin/rm", "-f", layout.legacyAgentPlist), "remove \(layout.user)'s launch agent")
    }

    /// The CI keychain (`CIKeychain`): a generated password in a 0600 file inside the 0700 home, then the keychain,
    /// without automatic locking, both made as `hangar`. The password reaches `security` on standard input only. A
    /// keychain that exists and unlocks with its stored password is kept, with the signing identity in it; any other
    /// is replaced (the next archive creates the identity again). The worker makes it the default keychain itself.
    private func setUpKeychain() throws {
        let keychain = layout.keychain
        let asUser = ["/usr/bin/sudo", "-u", layout.user, "-H"]
        let hasKeychain = !dryRun && runner.succeeds(.sudo("/bin/test", "-f", keychain.path))
        if hasKeychain, runner.succeeds(.sudo("/bin/test", "-f", keychain.passwordFile)) {
            let read = IsolationCommand(["/usr/bin/sudo", "/bin/cat", keychain.passwordFile], kind: .probe, capturesOutput: true, quiet: true)
            let stored = (try? runner.run(read)).flatMap { $0.succeeded ? $0.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            if let stored, !stored.isEmpty,
                runner.succeeds(IsolationCommand(
                    asUser + ["/usr/bin/security", "-i"], kind: .probe,
                    input: CIKeychain.unlockInput(password: SensitiveText(stored), path: keychain.path), quiet: true))
            {
                say("\(layout.user)'s CI keychain exists and unlocks with its stored password.")
                return
            }
            say("\(layout.user)'s CI keychain does not unlock with its stored password; making a new one. The next archive creates the signing identity again.")
        }
        if hasKeychain {
            try require(IsolationCommand(asUser + ["/bin/rm", "-f", keychain.path], kind: .change), "remove \(layout.user)'s old CI keychain")
        }
        say("Creating \(layout.user)'s CI keychain (\(keychain.path)), which codesign uses without a login...")
        let password = dependencies.generator.generate()
        let staged = try stage(CIKeychain.passwordFileName) {
            try (password.value + "\n").write(toFile: $0, atomically: true, encoding: .utf8)
            try WorkerPrivacy.setMode(0o600, at: $0)
        }
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try require(
            .sudo("/usr/bin/install", "-o", layout.user, "-g", "staff", "-m", "600", staged, keychain.passwordFile),
            "save the CI keychain's password")
        try require(
            IsolationCommand(
                asUser + ["/usr/bin/security", "-i"], kind: .change,
                input: CIKeychain.createInput(password: password, path: keychain.path)),
            "create \(layout.user)'s CI keychain")
        try require(
            IsolationCommand(asUser + ["/usr/bin/security", "set-keychain-settings", keychain.path], kind: .change),
            "turn off the CI keychain's automatic locking")
    }

    /// Installs the LaunchDaemon plist (root:wheel 0644). Returns whether it differs from the one in place, which
    /// launchd only reads when the job is bootstrapped.
    private func installDaemon() throws -> Bool {
        let plist = WorkerLaunchDaemon.plist(binary: layout.binary, user: layout.user, home: layout.home, logs: layout.logs)
        let current = try? String(contentsOfFile: layout.daemonPlist, encoding: .utf8)
        let staged = try stage("daemon.plist") { try plist.write(toFile: $0, atomically: true, encoding: .utf8) }
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try require(
            .sudo("/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "644", staged, layout.daemonPlist),
            "install the worker's LaunchDaemon")
        return current != plist
    }

    // MARK: The daemon

    /// Bootstraps the daemon into the system domain. One already loaded (a rerun or an update) is restarted onto the
    /// new binary the way launchd stops it; when its plist changed it is booted out and bootstrapped again instead,
    /// so launchd reads the new one. Then waits until launchd says it runs.
    private func startDaemon(plistChanged: Bool) async throws {
        let target = "system/\(WorkerLaunchDaemon.label)"
        let print = IsolationCommand(["/bin/launchctl", "print", target], kind: .probe, capturesOutput: true, quiet: true)
        let loaded = runner.succeeds(print)
        if loaded, !plistChanged {
            if dryRun {
                say("  would run: /usr/bin/sudo /bin/launchctl kill SIGTERM \(target) (launchd starts the new binary)")
                return
            }
            try await restartGracefully(print: print, target: target)
        } else {
            if loaded {
                say("Restarting \(layout.user)'s worker with its new LaunchDaemon settings; a build in flight stops and reports why.")
                try require(.sudo("/bin/launchctl", "bootout", target), "stop \(layout.user)'s worker")
            }
            try require(.sudo("/bin/launchctl", "bootstrap", "system", layout.daemonPlist), "start \(layout.user)'s worker")
        }
        if dryRun {
            say("  would wait until /bin/launchctl print \(target) says state = running")
            return
        }
        for _ in 0..<timing.workerRunningPolls {
            if let result = try? runner.run(print), result.succeeded, Self.isRunning(launchctlPrint: result.output) {
                say("The worker runs as \(layout.user), from boot, with no login.")
                return
            }
            await dependencies.sleep(timing.poll)
        }
        throw IsolationError("""
            \(layout.user)'s worker did not start. Its log is \(layout.logs)/worker.log (readable with sudo), and \
            sudo launchctl print \(target) says what launchd saw. The old agent's plist is still in place:
              launchctl bootstrap gui/\(invoker.uid) \(IsolationCommand.quote(invoker.plist))
            starts it again.
            """)
    }

    /// Restarts a running worker onto the new binary the way launchd stops it: SIGTERM, which the worker handles by
    /// cancelling a running build with the reason and cleaning up. Once the old process (its pid in `launchctl print`)
    /// is gone, launchd's KeepAlive starts the new binary; `kickstart` only nudges it when it is not running yet. Only
    /// a worker that does not exit in time is killed with `kickstart -k`.
    private func restartGracefully(print: IsolationCommand, target: String) async throws {
        let oldPID = (try? runner.run(print)).flatMap { Self.pid(launchctlPrint: $0.output) }
        say("Restarting \(layout.user)'s worker on the new binary; a build in flight stops and reports why.")
        try require(.sudo("/bin/launchctl", "kill", "SIGTERM", target), "stop \(layout.user)'s worker")
        for _ in 0..<timing.oldAgentPolls {
            let result = try? runner.run(print)
            let pid = result.flatMap { $0.succeeded ? Self.pid(launchctlPrint: $0.output) : nil }
            if oldPID == nil || pid != oldPID {
                if !(result.map { $0.succeeded && Self.isRunning(launchctlPrint: $0.output) } ?? false) {
                    _ = try runner.run(IsolationCommand(["/usr/bin/sudo", "/bin/launchctl", "kickstart", target], kind: .change, quiet: true))
                }
                return
            }
            await dependencies.sleep(timing.poll)
        }
        say("warning: \(layout.user)'s worker did not stop after SIGTERM; restarting it forcibly.")
        try require(.sudo("/bin/launchctl", "kickstart", "-k", target), "restart \(layout.user)'s worker")
    }

    static func pid(launchctlPrint output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") { return Int(trimmed.dropFirst("pid = ".count)) }
        }
        return nil
    }

    static func isRunning(launchctlPrint output: String) -> Bool {
        output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "state = running" }
    }

    private func showPassword(_ password: SensitiveText) {
        say("")
        say("  The \(layout.user) user's password (shown once):  \(password.value)")
        say("  Nothing needs it: the worker runs without a login. It is for emergencies, and saved in your login")
        say("  keychain. To see it again:")
        say("    \(AccountPasswordItem.lookupCommand(account: layout.user))")
        say("")
    }

    /// Whether `machine`'s last heartbeat came from the new daemon: the worker reports `headless` and the account.
    /// A server before 0.9 drops `headless` (and one before 0.7 `runningUser`); then only a heartbeat after the old
    /// workers stopped counts, since an older version's agent in the account also reported `hangar`.
    static func isDaemonHeartbeat(_ machine: Machine, user: String, since: Date) -> Bool {
        guard let report = machine.report else { return false }
        if report.headless == true { return report.runningUser == user }
        return (report.runningUser ?? user) == user && (machine.lastSeenAt ?? .distantPast) > since
    }

    private func confirmHeartbeat(source: WorkerConfiguration?, since: Date) async throws {
        if dryRun {
            say("  would wait for the server to see a heartbeat from \(layout.user) (GET /api/v1/worker/me)")
            return
        }
        guard let source else {
            let check = IsolationCommand(
                ["/usr/bin/sudo", "-u", layout.user, "-H", layout.binary, "check", "--config", layout.config], kind: .probe,
                capturesOutput: true)
            let result = try runner.run(check)
            guard result.succeeded else {
                throw IsolationError("The server does not accept \(layout.user)'s worker configuration (hangar-worker check exited \(result.exitCode)).")
            }
            return
        }
        for _ in 0..<timing.heartbeatPolls {
            if case .accepted(let machine) = await dependencies.check(source),
                Self.isDaemonHeartbeat(machine, user: layout.user, since: since)
            {
                say("Hangar sees \(machine.name) heartbeat as \(machine.report?.runningUser ?? layout.user).")
                if let problem = machine.report?.keychainProblem {
                    say("warning: \(layout.user)'s worker cannot sign yet: \(problem). Hangar › Machines shows it until it can.")
                }
                return
            }
            await dependencies.sleep(timing.poll)
        }
        throw IsolationError("""
            The server has not heard from \(layout.user)'s worker. Its log is \(layout.logs)/worker.log. The old agent's plist is still in place; \
            to go back, run sudo launchctl bootout system/\(WorkerLaunchDaemon.label), then: launchctl bootstrap gui/\(invoker.uid) \(IsolationCommand.quote(invoker.plist))
            """)
    }

    private func printFollowUps() {
        if dryRun {
            say("End of the dry run. Run without --dry-run to do this.")
            return
        }
        say("""
            Done. This Mac's builds run as \(layout.user), from boot, with no login; nobody needs to log in as \(layout.user).
            Good to know:
              - Signing needs a team App Store Connect key (Settings, with its issuer ID): \(layout.user) has no Xcode account. \
            With an individual key, archives wait for another Mac and say why.
              - The first archive creates \(layout.user)'s signing identity in its CI keychain; the worker lets codesign use it.
              - If a workflow's tool (xcodegen, rclone...) is missing as \(layout.user), make the Homebrew prefix readable to it; do not install a second Homebrew.
            """)
    }

    // MARK: Helpers

    @discardableResult
    private func require(_ command: IsolationCommand, _ what: String) throws -> IsolationResult {
        let result = try runner.run(command)
        guard result.succeeded else { throw IsolationError("Could not \(what): \(command) exited \(result.exitCode).") }
        return result
    }

    private func stage(_ name: String, write: (String) throws -> Void) throws -> String {
        try FileManager.default.createDirectory(
            atPath: dependencies.stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try WorkerPrivacy.setMode(0o700, at: dependencies.stagingDirectory)
        let path = dependencies.stagingDirectory + "/" + name
        try write(path)
        return path
    }

    static func readOldAgent(at path: String) -> OldAgent? {
        guard let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String], let program = arguments.first
        else { return nil }
        var config: String?
        if let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count { config = arguments[index + 1] }
        return OldAgent(program: program, config: config)
    }

    static func sameVolume(_ a: String, _ b: String) -> Bool {
        func device(_ path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: path)[.systemNumber] as? NSNumber)?.intValue
        }
        guard let first = device(a), let second = device(b) else { return true }
        return first == second
    }
}

extension IsolationRunner {
    /// Whether the command exits 0; a launch failure counts as no.
    func succeeds(_ command: IsolationCommand) -> Bool {
        (try? run(command))?.succeeded ?? false
    }
}

/// The worker's launchd agent: the keys of scripts/worker/app.hangar.worker.plist.
public enum WorkerLaunchAgent {
    public static let label = "app.hangar.worker"

    public static func plist(binary: String, logs: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(escape(binary))</string>
                    <string>run</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>LimitLoadToSessionType</key>
                <string>Aqua</string>
                <key>ProcessType</key>
                <string>Standard</string>
                <key>StandardOutPath</key>
                <string>\(escape(logs))/worker.log</string>
                <key>StandardErrorPath</key>
                <string>\(escape(logs))/worker.log</string>
            </dict>
            </plist>

            """
    }
}

/// The worker's LaunchDaemon on an isolated Mac: `hangar-worker run` as the dedicated user from boot, without a login
/// (worker isolation design, *revised: LaunchDaemon*). Installed root:wheel 0644 in `/Library/LaunchDaemons` and
/// bootstrapped into the `system` domain. A daemon gets no login environment, so HOME, USER, LOGNAME and the PATH a
/// launch agent gets are set here; `SessionCreate` gives it a security session of its own for the CI keychain, and
/// `InitGroups` the user's groups. KeepAlive starts it again after an exit; the idle self-update re-execs in place.
public enum WorkerLaunchDaemon {
    public static let label = WorkerLaunchAgent.label
    public static let directory = "/Library/LaunchDaemons"

    public static func plist(binary: String, user: String, home: String, logs: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(escape(binary))</string>
                    <string>run</string>
                </array>
                <key>UserName</key>
                <string>\(escape(user))</string>
                <key>GroupName</key>
                <string>staff</string>
                <key>InitGroups</key>
                <true/>
                <key>EnvironmentVariables</key>
                <dict>
                    <key>HOME</key>
                    <string>\(escape(home))</string>
                    <key>USER</key>
                    <string>\(escape(user))</string>
                    <key>LOGNAME</key>
                    <string>\(escape(user))</string>
                    <key>PATH</key>
                    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
                </dict>
                <key>SessionCreate</key>
                <true/>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>ProcessType</key>
                <string>Standard</string>
                <key>StandardOutPath</key>
                <string>\(escape(logs))/worker.log</string>
                <key>StandardErrorPath</key>
                <string>\(escape(logs))/worker.log</string>
            </dict>
            </plist>

            """
    }
}
