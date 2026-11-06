import Foundation
import HangarCore
import Synchronization

public enum VMImageBuildError: Error, Equatable, CustomStringConvertible {
    case noBaseImage(String)
    case xcodeUnreadable(String)
    case exists(String)
    case lowDisk(freeGB: Int, floorGB: Int)
    case guestDidNotShutDown

    public var description: String {
        switch self {
        case .noBaseImage(let name): "no image \(name): import one with `\(WorkerCommandLine.current().asWorker("vm", "image", "import"))`"
        case .xcodeUnreadable(let path): "\(path) is not an Xcode (no version in Contents/version.plist)"
        case .exists(let name): "there is already an image named \(name); remove it first (`\(WorkerCommandLine.current().asWorker("vm", "image", "remove", name))`)"
        case .lowDisk(let free, let floor): "stopped: only \(free) GB free on the VM storage volume (the floor is \(floor) GB)"
        case .guestDidNotShutDown: "the VM did not shut down within 3 minutes"
        }
    }
}

/// Builds a job image from a vanilla one, over SSH as `admin` (VM builds design, *Base image pipeline*, layer 2), in
/// `images/.partial-<name>`: an APFS clone of the vanilla disk, so the two share blocks. Renamed when complete; a failed
/// build is deleted. A watchdog stops the VM when free space falls below the floor.
public struct VMImageBuilder: Sendable {
    public static let buildUser = "builder"
    /// The vanilla images' published login. It is replaced before anything else happens.
    static let vanillaPassword = "admin"

    public var host: VMHost
    public var progress: @Sendable (String) -> Void
    public var passwords: any PasswordGenerating

    public init(host: VMHost, progress: @escaping @Sendable (String) -> Void, passwords: any PasswordGenerating = RandomPasswordGenerator()) {
        self.host = host
        self.progress = progress
        self.passwords = passwords
    }

    /// "27.2" and "17C52" from an Xcode bundle's `version.plist`.
    public static func xcodeVersion(at path: String) throws -> (version: String, build: String) {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/version.plist"),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String,
            let build = plist["ProductBuildVersion"] as? String
        else { throw VMImageBuildError.xcodeUnreadable(path) }
        return (version, build)
    }

    /// The default size of a job image's disk. Clones share blocks with the image, so only what a job writes costs space.
    public static let defaultDiskGB = 120

    /// Makes a (sparse) disk file at least `gigabytes` long; a smaller request leaves it as it is.
    static func grow(_ disk: String, toGB gigabytes: Int) throws {
        let size = Int64(gigabytes) * 1_000_000_000
        let current = (try? FileManager.default.attributesOfItem(atPath: disk)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > current else { return }
        let descriptor = open(disk, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw SecretsError.io(path: disk, errno: errno) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, size) == 0 else { throw SecretsError.io(path: disk, errno: errno) }
    }

    public func build(
        from baseName: String, xcodePath: String, name: String?, platforms: [String], diskGB: Int = VMImageBuilder.defaultDiskGB, homebrew: Bool = false,
        metalToolchain: Bool = false, now: Date = Date()
    ) async throws -> VMImage {
        let storage = host.storage
        let base: VMImage
        do { base = try VMImage(directory: storage.image(baseName)) } catch { throw VMImageBuildError.noBaseImage(baseName) }
        let xcode = try Self.xcodeVersion(at: xcodePath)
        let name = name ?? "xcode-\(xcode.version)"
        guard VMStorage.isValidImageName(name) else { throw VMImageBuildError.exists(name) }
        guard !FileManager.default.fileExists(atPath: storage.image(name).path) else { throw VMImageBuildError.exists(name) }
        if let reason = host.engine.unavailableReason() { throw VMError.failed(reason) }
        try await GuestKeys.ensure(storage: storage, runner: host.runner)

        let partial = storage.partialImage(name)
        try? FileManager.default.removeItem(atPath: partial.path)
        try FileManager.default.createDirectory(atPath: partial.path + "/share", withIntermediateDirectories: true)
        do {
            let image = try await provision(base: base, into: partial, xcodePath: xcodePath, xcode: xcode, platforms: platforms,
                diskGB: diskGB, homebrew: homebrew, metalToolchain: metalToolchain, now: now)
            try FileManager.default.removeItem(atPath: partial.path + "/share")
            try? FileManager.default.removeItem(atPath: partial.path + "/askpass.sh")
            try FileManager.default.moveItem(atPath: partial.path, toPath: storage.image(name).path)
            return try VMImage(directory: storage.image(name)).with(metadata: image)
        } catch {
            try? FileManager.default.removeItem(atPath: partial.path)
            throw error
        }
    }

    private func provision(
        base: VMImage, into partial: VMImageDirectory, xcodePath: String, xcode: (version: String, build: String),
        platforms: [String], diskGB: Int, homebrew: Bool, metalToolchain: Bool, now: Date
    ) async throws -> VMImageMetadata {
        try VMVolume.clone(base.directory.disk, to: partial.disk)
        try Self.grow(partial.disk, toGB: diskGB)
        try VMVolume.clone(base.directory.nvram, to: partial.nvram)
        var config = base.config
        config.cpuCount = max(host.settings.cpus, config.cpuCountMin)
        config.memorySize = max(host.settings.memoryBytes, config.memorySizeMin)
        config.ecid = host.engine.newMachineIdentifier().base64EncodedString()
        config.macAddress = VMMACAddress.forSlot(0xb0, machine: host.machineName)
        try VMBundleFile.write(config, to: partial.config)
        try Self.askpass.write(toFile: partial.path + "/askpass.sh", atomically: true, encoding: .utf8)
        try WorkerPrivacy.setMode(0o700, at: partial.path + "/askpass.sh")

        let spec = VMSpec(
            hardwareModel: try base.hardwareModel(), machineIdentifier: Data(base64Encoded: config.ecid)!, disk: partial.disk,
            nvram: partial.nvram, cpus: config.cpuCount, memoryBytes: config.memorySize, macAddress: config.macAddress,
            share: partial.path + "/share")
        let machine = try host.engine.make(spec)
        progress("booting a clone of \(base.metadata.name)")
        let started = ContinuousClock.now
        try await machine.start()
        let shutDown = StopFlag()
        machine.onStop { shutDown.set($0) }
        let guard_ = FloorGuard(path: host.storage.root, floorGB: host.settings.floorGB) { [machine] in
            Task { await machine.stop() }
        }
        defer { guard_.cancel() }
        do {
            let address = try await waitForAddress(mac: config.macAddress, stopped: shutDown)
            progress("up at \(address) after \(VMLauncher.seconds(since: started))")
            let metadata = try await provisionGuest(
                address: address, partial: partial, base: base, xcodePath: xcodePath, xcode: xcode, platforms: platforms,
                homebrew: homebrew, metalToolchain: metalToolchain, now: now, floor: guard_)
            progress("shutting down")
            let ssh = keySSH(partial)
            _ = try? await ssh.run(user: "admin", host: address, "sudo -n shutdown -h now")
            let deadline = ContinuousClock.now + .seconds(180)
            while shutDown.value == nil, ContinuousClock.now < deadline { try await host.clock.sleep(for: .seconds(1)) }
            if shutDown.value == nil {
                await machine.stop()
                throw VMImageBuildError.guestDidNotShutDown
            }
            try VMBundleFile.write(metadata, to: partial.metadata)
            progress("image built in \(VMLauncher.seconds(since: started))")
            return metadata
        } catch {
            await machine.stop()
            if let floor = guard_.tripped { throw VMImageBuildError.lowDisk(freeGB: floor, floorGB: host.settings.floorGB) }
            throw error
        }
    }

    // MARK: Inside the guest

    private func provisionGuest(
        address: String, partial: VMImageDirectory, base: VMImage, xcodePath: String, xcode: (version: String, build: String),
        platforms: [String], homebrew: Bool, metalToolchain: Bool, now: Date, floor: FloorGuard
    ) async throws -> VMImageMetadata {
        let publicKey = try GuestKeys.publicKey(storage: host.storage)
        // 1. admin: the host's key in, the published password out, password logins off.
        let password = GuestSSH(
            runner: host.runner, privateKey: host.storage.privateKey, hostKeys: .record(knownHosts: partial.knownHosts),
            askpassScript: partial.path + "/askpass.sh")
        try await waitForSSH(password, address: address)
        try await step("install the host's key for admin") {
            try await password.require(
                "install admin's key", user: "admin", host: address,
                "mkdir -p -m 0700 .ssh && cat >> .ssh/authorized_keys && chmod 0600 .ssh/authorized_keys",
                input: SensitiveText(publicKey + "\n"))
        }
        let ssh = keySSH(partial)
        try await step("replace admin's password and turn off password logins") {
            try await ssh.require(
                "rotate admin's password", user: "admin", host: address,
                "read -r p && sudo -n dscl . -passwd /Users/admin \(Self.vanillaPassword) \"$p\" && printf 'PasswordAuthentication no\\nKbdInteractiveAuthentication no\\n' | sudo -n tee /etc/ssh/sshd_config.d/100-hangar.conf >/dev/null",
                input: SensitiveText(passwords.generate().value + "\n"))
        }
        // 2. builder: a standard user, no sudo, logged in automatically so the saved state holds its GUI session.
        let user = Self.buildUser
        try await step("create the build user \(user) (not an administrator) with automatic login") {
            // sysadminctl -autologin records the user but leaves the image's /etc/kcpassword (admin's) in place, so
            // the login window fails; the file is written here instead.
            let password = passwords.generate()
            try await ssh.require(
                "create \(user)", user: "admin", host: address,
                """
                read -r p && read -r k && \\
                (id \(user) >/dev/null 2>&1 || sudo -n sysadminctl -addUser \(user) -fullName Builder -password "$p" -home /Users/\(user) 2>&1) && \\
                sudo -n createhomedir -c -u \(user) >/dev/null && \\
                printf '%s' "$k" | base64 -d | sudo -n tee /etc/kcpassword >/dev/null && \\
                sudo -n chown root:wheel /etc/kcpassword && sudo -n chmod 0600 /etc/kcpassword && \\
                sudo -n defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser \(user) && \\
                (sudo -n dseditgroup -o edit -a \(user) -t user com.apple.access_ssh 2>/dev/null || true) && \\
                sudo -n mkdir -p -m 0700 /Users/\(user)/.ssh && \\
                printf '%s\\n' \(GuestSSH.quote(publicKey)) | sudo -n tee /Users/\(user)/.ssh/authorized_keys >/dev/null && \\
                sudo -n chmod 0600 /Users/\(user)/.ssh/authorized_keys && \\
                sudo -n chown -R \(user):staff /Users/\(user)/.ssh && \\
                ! dseditgroup -o checkmember -m \(user) admin >/dev/null
                """,
                input: SensitiveText(password.value + "\n" + Self.kcpassword(password.value).base64EncodedString() + "\n"))
        }
        // The disk file grew before boot. The recovery partition sits right after the system container and SIP will not
        // let it go, so the new space becomes its own APFS volume, /Volumes/workspace (Xcode Cloud's path), where a
        // job's checkout, DerivedData and TMPDIR go.
        try await step("add the workspace volume in the disk's free space") {
            try await ssh.require(
                "add /Volumes/workspace", user: "admin", host: address,
                """
                if ! diskutil info /Volumes/workspace >/dev/null 2>&1; then \\
                  disk=$(diskutil info / | awk -F': *' '/APFS Physical Store/ {print $2}' | sed -E 's/s[0-9]+$//') && \\
                  (yes | sudo -n diskutil repairDisk "$disk" >/dev/null 2>&1 || true) && \\
                  last=$(diskutil list "$disk" | awk '/^ *[0-9]+:/ {id=$NF} END {print id}') && \\
                  sudo -n diskutil addPartition "$last" APFS workspace 0 >/dev/null; \\
                fi && \\
                sudo -n diskutil enableOwnership /Volumes/workspace >/dev/null && \\
                sudo -n chown \(Self.buildUser):staff /Volumes/workspace && \\
                df -h /Volumes/workspace | tail -1
                """, onLine: progress)
        }
        // 3. /opt/homebrew, empty and builder's: a job's script can put Homebrew there without sudo (from its tarball)
        // and get bottles, as on Xcode Cloud. Homebrew itself goes in only when asked for.
        try await step("give \(user) an empty /opt/homebrew") {
            try await ssh.require(
                "own /opt/homebrew", user: "admin", host: address,
                "sudo -n mkdir -p /opt/homebrew && sudo -n chown -R \(user):admin /opt/homebrew")
        }
        if homebrew {
            try await step("install Homebrew into /opt/homebrew") {
                // `brew update` turns the tarball into a git checkout, so later updates work; its output is long.
                try await ssh.require(
                    "install Homebrew", user: user, host: address,
                    "export HOMEBREW_NO_ANALYTICS=1 && cd /opt/homebrew && ( [ -x bin/brew ] || curl -fsSL https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C /opt/homebrew ) && bin/brew update --force --quiet >/dev/null 2>&1; bin/brew --version | head -1",
                    onLine: progress)
            }
        }
        // 4. This Mac's Xcode, as a tar stream: ditto from a virtio-fs share hit symlink loops in the spike.
        try await step("copy \(xcodePath) (Xcode \(xcode.version)) into the VM") {
            try await streamXcode(xcodePath, address: address, ssh: ssh)
        }
        try floor.check()
        try await step("select Xcode, accept its license and run its first launch") {
            try await ssh.require(
                "set up Xcode", user: "admin", host: address,
                "sudo -n xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo -n xcodebuild -license accept && sudo -n xcodebuild -runFirstLaunch 2>&1 | tail -3",
                onLine: progress)
        }
        if metalToolchain {
            try await step("download the Metal toolchain") {
                try await ssh.require(
                    "download the Metal toolchain", user: "admin", host: address,
                    "set -o pipefail; sudo -n xcodebuild -downloadComponent MetalToolchain 2>&1 | tail -3", onLine: progress)
            }
            try floor.check()
        }
        for platform in platforms {
            try await step("download the \(platform) simulator platform") {
                try await ssh.require(
                    "download \(platform)", user: "admin", host: address,
                    "set -o pipefail; sudo -n xcodebuild -downloadPlatform \(GuestSSH.quote(platform)) 2>&1 | tail -3", onLine: progress)
            }
            try floor.check()
        }
        // 5. Quiet: no Spotlight (a fresh guest sat at a load of 50), no sleep, no updates.
        try await step("turn off Spotlight, sleep, the screen saver and software update") {
            try await ssh.require(
                "quiet the guest", user: "admin", host: address,
                """
                sudo -n mdutil -a -i off >/dev/null; \
                sudo -n pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null; \
                sudo -n softwareupdate --schedule off >/dev/null 2>&1; \
                sudo -n defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false; \
                sudo -n defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false; \
                sudo -n -u \(user) defaults -currentHost write com.apple.screensaver idleTime 0; true
                """)
        }
        // 6. What the image holds.
        let facts = try await ssh.run(
            user: user, host: address,
            "sw_vers -productVersion; sw_vers -buildVersion; xcodebuild -version | tail -1; xcrun simctl list runtimes -j 2>/dev/null")
        let lines = facts.output.split(separator: "\n", maxSplits: 3).map(String.init)
        let macOS = lines.count >= 2 ? "\(lines[0]) (\(lines[1]))" : ""
        let runtimes = lines.count >= 4 ? Self.runtimeNames(fromJSON: Data(lines[3].utf8)) : []
        let built = lines.count >= 3 ? lines[2].replacingOccurrences(of: "Build version ", with: "") : xcode.build
        progress("macOS \(macOS), Xcode \(xcode.version) (\(built)), runtimes: \(runtimes.isEmpty ? "none" : runtimes.joined(separator: ", "))")
        return VMImageMetadata(
            name: partial.name, macOS: macOS, xcode: xcode.version, xcodeBuild: built, simulatorRuntimes: runtimes,
            source: "\(base.metadata.name) (\(base.metadata.source))", createdAt: now, buildUser: user)
    }

    /// `tar -c` of the Xcode bundle on the host, `tar --hfsCompression -x` as root in the guest: the files stay
    /// compressed (8.9 GB of Xcode 27.2 is 3.7 GB on disk).
    private func streamXcode(_ path: String, address: String, ssh: GuestSSH) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let bundle = (path as NSString).lastPathComponent
        let remote = "sudo -n rm -rf /Applications/Xcode.app && sudo -n mkdir -p /Applications/.hangar-xcode && sudo -n tar -C /Applications/.hangar-xcode --hfsCompression -xpf - && sudo -n mv /Applications/.hangar-xcode/\(GuestSSH.quote(bundle)) /Applications/Xcode.app && sudo -n rmdir /Applications/.hangar-xcode"
        let sshCommand = (["/usr/bin/ssh"] + ssh.options() + ["admin@\(address)", "--", remote]).map(GuestSSH.quote).joined(separator: " ")
        let script = "/usr/bin/tar -C \(GuestSSH.quote(parent)) -cf - \(GuestSSH.quote(bundle)) | \(sshCommand)"
        let started = ContinuousClock.now
        let outcome = try await host.runner.run(
            ProcessCommand(executable: "/bin/sh", arguments: ["-c", "set -o pipefail; " + script], environment: ssh.environment),
            onLine: progress)
        guard outcome.exitCode == 0 else { throw GuestCommandError(what: "copy Xcode", exitCode: outcome.exitCode, output: outcome.output) }
        progress("copied in \(VMLauncher.seconds(since: started))")
    }

    static func runtimeNames(fromJSON data: Data) -> [String] {
        struct List: Decodable {
            struct Runtime: Decodable {
                var name: String
                var isAvailable: Bool?
            }
            var runtimes: [Runtime]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return list.runtimes.filter { $0.isAvailable ?? true }.map(\.name).sorted()
    }

    // MARK: Plumbing

    static let askpass = "#!/bin/sh\necho \(vanillaPassword)\n"

    /// `/etc/kcpassword`, which the login window reads for automatic login: the password, a zero, padding to a
    /// multiple of 12 bytes, XORed with Apple's fixed 11-byte key.
    static func kcpassword(_ password: String) -> Data {
        let key: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
        var bytes = Array(password.utf8) + [0]
        while bytes.count % 12 != 0 { bytes.append(0) }
        return Data(bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] })
    }

    private func keySSH(_ partial: VMImageDirectory) -> GuestSSH {
        GuestSSH(runner: host.runner, privateKey: host.storage.privateKey, hostKeys: .record(knownHosts: partial.knownHosts))
    }

    private func step(_ title: String, _ body: () async throws -> Void) async throws {
        progress("→ \(title)")
        let started = ContinuousClock.now
        try await body()
        progress("  done in \(VMLauncher.seconds(since: started))")
    }

    private func waitForAddress(mac: String, stopped: StopFlag) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < deadline {
            if let stop = stopped.value { throw VMError.failed("the VM stopped while booting: \(stop)") }
            if let address = DHCPLeases.address(for: mac, leasesFile: host.leasesFile) { return address }
            try await host.clock.sleep(for: .milliseconds(500))
        }
        throw VMError.failed("the VM got no network address within 5 minutes")
    }

    private func waitForSSH(_ ssh: GuestSSH, address: String) async throws {
        let deadline = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < deadline {
            if try await ssh.run(user: "admin", host: address, "true").exitCode == 0 { return }
            try await host.clock.sleep(for: .seconds(1))
        }
        throw VMError.failed("the VM did not answer SSH within 5 minutes")
    }
}

extension VMImage {
    func with(metadata: VMImageMetadata) -> VMImage {
        var copy = self
        copy.metadata = metadata
        return copy
    }
}

/// Watches free space on a volume every few seconds and calls `trip` once when it falls below the floor.
final class FloorGuard: Sendable {
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)
    private let trippedAt = Mutex<Int?>(nil)

    init(path: String, floorGB: Int, interval: Duration = .seconds(5), trip: @escaping @Sendable () -> Void) {
        let started = Task { [weak self] in
            while !Task.isCancelled {
                let free = VMVolume.freeGB(at: path)
                if free < Double(floorGB) {
                    self?.trippedAt.withLock { $0 = Int(free) }
                    trip()
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
        task.withLock { $0 = started }
    }

    var tripped: Int? { trippedAt.withLock { $0 } }

    func check() throws {
        if let free = tripped { throw VMImageBuildError.lowDisk(freeGB: free, floorGB: 0) }
    }

    func cancel() { task.withLock { $0?.cancel() } }
}
