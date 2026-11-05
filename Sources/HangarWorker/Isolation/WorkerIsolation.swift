import Foundation
import HangarCore

/// Where the dedicated build account keeps the worker. Defaults are the `hangar` user's.
public struct IsolationLayout: Sendable, Equatable {
    public var user: String
    public var home: String

    public init(user: String = WorkerPrivacy.dedicatedUser, home: String = WorkerPrivacy.dedicatedHome) {
        self.user = user
        self.home = home
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
    public var launchAgents: String { home + "/Library/LaunchAgents" }
    public var plist: String { launchAgents + "/" + WorkerLaunchAgent.label + ".plist" }
    public var logs: String { home + "/Library/Logs/Hangar" }
    public var loginKeychain: String { home + "/Library/Keychains/login.keychain-db" }
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
    /// Give an existing account a new generated password (its login keychain then asks for the old one once).
    public var resetPassword = false
    /// Stop after the account is ready instead of waiting for its graphical login.
    public var noWait = false

    public init(
        dryRun: Bool = false, sourceConfig: String? = nil, binary: String? = nil, serverData: String? = nil,
        resetPassword: Bool = false, noWait: Bool = false
    ) {
        self.dryRun = dryRun
        self.sourceConfig = sourceConfig
        self.binary = binary
        self.serverData = serverData
        self.resetPassword = resetPassword
        self.noWait = noWait
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
/// account with a generated password (stored in the administrator's login keychain and shown once), install a copy
/// of the worker, the configuration (same machine token, data and work directories rewritten) and the build cache
/// (checkouts and DerivedData, moved into the account's work directory as `WorkDirectoryMigration` would) into that
/// account, lock its home to 0700, write its launch agent, then wait for the one step macOS does not allow a
/// script to do: a graphical login as `hangar` (fast user switching). That login unlocks the account's login keychain
/// and starts the agent; `isolate` then confirms the agent runs and the server sees the machine heartbeat as `hangar`,
/// and removes the old agent and configuration. Each step is idempotent, so running it again resumes.
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
        /// Waiting for the old agent's process to exit after bootout.
        public var oldAgentPolls = 20
        /// After the login, before `isolate` bootstraps the agent itself.
        public var agentLoadPolls = 7
        /// Waiting for the agent to be running.
        public var agentRunningPolls = 20
        /// Waiting for the server to see a heartbeat from the account.
        public var heartbeatPolls = 30
        /// Waiting for the graphical login; nil waits until interrupted.
        public var loginPolls: Int? = nil
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
        let accountUID = uid!
        try require(.sudo("/usr/sbin/createhomedir", "-c", "-u", layout.user), "create the \(layout.user) home")

        // 4. The server's data must not be readable by the account, checked before anything moves.
        try checkServerData()

        // 5. Xcode's first launch is system-wide; done once per Mac as root.
        try xcodeFirstLaunch()

        // 6. Move the worker into the account.
        let stoppedAt = dependencies.now()
        if let oldAgent { try await stopOldAgent(oldAgent) }
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
        try installLaunchAgent()

        // 7. The graphical login, and the agent it starts.
        let sessionExisted = hasSession(uid: accountUID)
        if !sessionExisted {
            showLoginInstructions(password: password)
            if options.noWait {
                say("Not waiting (--no-wait). Run hangar-worker isolate again after logging in as \(layout.user) to finish.")
                return Outcome(createdAccount: createdAccount, generatedPassword: password, movedWorker: false, machineName: machineName)
            }
            try await waitForSession(uid: accountUID)
        } else if let password, !dryRun {
            showPassword(password)
        }
        try await waitForAgent(uid: accountUID, sessionExisted: sessionExisted)
        reportKeychain()

        // 8. The server must see the machine heartbeat from the account; then the old agent goes.
        try await confirmHeartbeat(source: source, since: stoppedAt, uid: accountUID)
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
        ]
        try require(
            IsolationCommand(["/usr/bin/sudo", "/usr/bin/install", "-d"] + owner + ["-m", "700"] + privateDirectories, kind: .change),
            "create \(layout.user)'s worker directories")
        try require(
            IsolationCommand(
                ["/usr/bin/sudo", "/usr/bin/install", "-d"] + owner
                    + ["-m", "755", layout.home + "/.local", layout.binDirectory, layout.launchAgents], kind: .change),
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

    private func installLaunchAgent() throws {
        let plist = WorkerLaunchAgent.plist(binary: layout.binary, logs: layout.logs)
        let staged = try stage("agent.plist") { try plist.write(toFile: $0, atomically: true, encoding: .utf8) }
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try require(
            .sudo("/usr/bin/install", "-o", layout.user, "-g", "staff", "-m", "644", staged, layout.plist),
            "install \(layout.user)'s launch agent")
    }

    // MARK: The login and the agent

    /// A graphical session exists when the account owns a loginwindow or Dock process (every Aqua session has both).
    private func hasSession(uid: String) -> Bool {
        if dryRun { return false }
        guard let result = try? runner.run(.probe("/bin/ps", "-axo", "uid=,comm=")), result.succeeded else { return false }
        return Self.hasGraphicalSession(psOutput: result.output, uid: uid)
    }

    static func hasGraphicalSession(psOutput: String, uid: String) -> Bool {
        psOutput.split(separator: "\n").contains { line in
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0] == uid else { return false }
            let name = (String(fields[1]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            return name == "loginwindow" || name == "Dock"
        }
    }

    private func showPassword(_ password: SensitiveText) {
        say("")
        say("  The \(layout.user) user's password (shown once):  \(password.value)")
        say("  It is saved in your login keychain. To see it again:")
        say("    \(AccountPasswordItem.lookupCommand(account: layout.user))")
        say("")
    }

    private func showLoginInstructions(password: SensitiveText?) {
        if let password, !dryRun { showPassword(password) }
        if password == nil {
            say("The \(layout.user) password is the one in your login keychain (\(AccountPasswordItem.lookupCommand(account: layout.user))), or the one you set.")
        }
        say("""
            One step is left that macOS only lets a person do: log in as \(layout.user) once.
              1. Open the user menu in the menu bar (or Control Center › Fast User Switching) and choose Hangar.
                 No user menu? Apple menu › Lock Screen, then Switch User.
              2. Enter the password above and click through the welcome screens.
              3. Switch back to \(invoker.name). Do not log out of \(layout.user): builds run in that session.
            This unlocks \(layout.user)'s login keychain (codesign needs it) and starts the worker. Waiting for the login...
            """)
    }

    private func waitForSession(uid: String) async throws {
        if dryRun {
            say("  would wait until \(layout.user) owns a loginwindow or Dock process (ps -axo uid=,comm=)")
            return
        }
        var polls = 0
        while !hasSession(uid: uid) {
            if let limit = timing.loginPolls, polls >= limit {
                throw IsolationError("\(layout.user) has not logged in. Run hangar-worker isolate again after logging in; it picks up where it stopped.")
            }
            polls += 1
            await dependencies.sleep(timing.poll)
        }
        say("\(layout.user) is logged in.")
    }

    /// A new login loads the agent from the account's LaunchAgents; if it does not, the agent is bootstrapped into the
    /// account's GUI domain. When the session was already there, a loaded agent is restarted onto the new binary and
    /// an unloaded one bootstrapped right away.
    private func waitForAgent(uid: String, sessionExisted: Bool) async throws {
        let target = "gui/\(uid)/\(WorkerLaunchAgent.label)"
        let print = IsolationCommand(["/usr/bin/sudo", "/bin/launchctl", "print", target], kind: .probe, capturesOutput: true, quiet: true)
        if dryRun {
            say("  would run: sudo /bin/launchctl bootstrap gui/\(uid) \(IsolationCommand.quote(layout.plist)) (only if the login did not load it)")
            return
        }
        var bootstrapped = false
        if sessionExisted {
            if runner.succeeds(print) {
                try await restartGracefully(print: print, target: target)
            } else {
                try require(.sudo("/bin/launchctl", "bootstrap", "gui/\(uid)", layout.plist), "start \(layout.user)'s worker agent")
            }
            bootstrapped = true
        }
        for attempt in 0..<timing.agentRunningPolls {
            let result = try runner.run(print)
            if result.succeeded, Self.isRunning(launchctlPrint: result.output) {
                say("The worker agent runs as \(layout.user).")
                return
            }
            if !result.succeeded, !bootstrapped, attempt >= timing.agentLoadPolls {
                try require(.sudo("/bin/launchctl", "bootstrap", "gui/\(uid)", layout.plist), "start \(layout.user)'s worker agent")
                bootstrapped = true
            }
            await dependencies.sleep(timing.poll)
        }
        throw IsolationError("""
            \(layout.user)'s worker agent did not start. Its log is \(layout.logs)/worker.log (readable with sudo). The old agent's plist is still in place:
              launchctl bootstrap gui/\(invoker.uid) \(IsolationCommand.quote(invoker.plist))
            starts it again.
            """)
    }

    /// Restarts a running agent onto the new binary the way launchd stops it: SIGTERM, which the worker handles by
    /// cancelling a running build with the reason and cleaning up. Once the old process (its pid in `launchctl print`)
    /// is gone, launchd's KeepAlive starts the new binary; `kickstart` only nudges it when it is not running yet. Only
    /// a worker that does not exit in time is killed with `kickstart -k`.
    private func restartGracefully(print: IsolationCommand, target: String) async throws {
        let oldPID = (try? runner.run(print)).flatMap { Self.pid(launchctlPrint: $0.output) }
        say("Restarting \(layout.user)'s worker on the new binary; a build in flight stops and reports why.")
        try require(.sudo("/bin/launchctl", "kill", "SIGTERM", target), "stop \(layout.user)'s worker agent")
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
        try require(.sudo("/bin/launchctl", "kickstart", "-k", target), "restart \(layout.user)'s worker agent")
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

    private func reportKeychain() {
        if dryRun { return }
        if runner.succeeds(.sudo("/bin/test", "-f", layout.loginKeychain)) {
            say("\(layout.user)'s login keychain exists and is unlocked by the login.")
        } else {
            say("warning: \(layout.user) has no login keychain yet (\(layout.loginKeychain)); signing needs one. Log in as \(layout.user) through the login window, not over SSH.")
        }
    }

    private func confirmHeartbeat(source: WorkerConfiguration?, since: Date, uid: String) async throws {
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
            // The old agent never reports the account's name; an older server drops the field, and then only a
            // heartbeat after the old agent stopped counts.
            if case .accepted(let machine) = await dependencies.check(source),
                machine.report?.runningUser == layout.user
                    || (machine.report?.runningUser == nil && (machine.lastSeenAt ?? .distantPast) > since)
            {
                say("Hangar sees \(machine.name) heartbeat as \(machine.report?.runningUser ?? layout.user).")
                return
            }
            await dependencies.sleep(timing.poll)
        }
        throw IsolationError("""
            The server has not heard from \(layout.user)'s worker. Its log is \(layout.logs)/worker.log. The old agent's plist is still in place; \
            to go back, boot out gui/\(uid)/\(WorkerLaunchAgent.label) and run: launchctl bootstrap gui/\(invoker.uid) \(IsolationCommand.quote(invoker.plist))
            """)
    }

    private func printFollowUps() {
        if dryRun {
            say("End of the dry run. Run without --dry-run to do this.")
            return
        }
        say("""
            Done. This Mac's builds run as \(layout.user).
            Left for you, once:
              - The first archive creates \(layout.user)'s signing identity. If Hangar › Machines says it cannot sign without a prompt, \
            switch to \(layout.user), open Keychain Access and allow codesign for the Apple Development key.
              - With an individual App Store Connect key, sign in to Xcode as \(layout.user) (Xcode › Settings › Accounts).
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
