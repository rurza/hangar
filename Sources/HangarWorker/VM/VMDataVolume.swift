import Foundation
import HangarCore
import Security

/// The encrypted APFS volume `vm setup` gives VM storage on the Mac's own disk. On the system's Data volume, Time
/// Machine's local snapshots (hourly, kept a day) hold the blocks of every deleted job clone and every re-saved slot
/// state: tens of GB of "System Data" that only shrinks when macOS runs short. Time Machine takes no snapshots of a
/// volume it does not back up, so on a volume of its own, excluded, a deleted clone frees its space at once. The volume
/// shares its container's free space, so nothing is set aside for it.
///
/// FileVault covers only the Data volume, so this one is encrypted too: with a random passphrase in a root-only file
/// on the Data volume (where FileVault covers it), which a LaunchDaemon (`app.hangar.vm-volume`) uses to unlock the
/// volume at every boot. Spotlight does not index it.
public enum VMDataVolume {
    public static let name = "HangarVM"
    public static let mountPoint = "/Volumes/" + name
    /// The storage directory on it, the worker's user's (mode 0700); the volume's root stays root's.
    public static let storage = mountPoint + "/vm"
    public static let keyPath = "/Library/Application Support/Hangar/vm-volume.key"
    public static let unlockerPath = "/Library/Application Support/Hangar/vm-volume.sh"
    public static let daemonLabel = "app.hangar.vm-volume"
    public static let daemonPath = "/Library/LaunchDaemons/app.hangar.vm-volume.plist"

    /// Whether `path` is the volume's storage.
    public static func holds(_ path: String) -> Bool { path == storage }

    /// Whether the volume is set up: its storage directory is there (so it is unlocked and mounted) and so is the
    /// daemon that unlocks it after a restart.
    public static var isReady: Bool {
        FileManager.default.fileExists(atPath: storage) && FileManager.default.fileExists(atPath: daemonPath)
    }

    /// Waits for the storage to appear, the daemon unlocking the volume at boot while the worker starts at login.
    /// False when it did not within `timeout`.
    public static func waitForStorage(timeout: Duration = .seconds(120)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !FileManager.default.fileExists(atPath: storage) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .seconds(2))
        }
        return true
    }

    /// What the LaunchDaemon runs as root at boot: unlock (which mounts) the volume, retrying while the disks come up.
    /// Nothing to do when it is mounted already.
    public static func unlockerScript(volumeUUID: String) -> String {
        """
        #!/bin/sh
        # Unlocks Hangar's VM volume (\(daemonLabel)). Runs as root at boot; written by hangar-worker vm setup.
        set -u
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            [ -d '\(storage)' ] && exit 0
            /usr/sbin/diskutil apfs unlockVolume '\(volumeUUID)' -user disk -stdinpassphrase < '\(keyPath)' >/dev/null 2>&1 \\
                || /usr/sbin/diskutil mount '\(volumeUUID)' >/dev/null 2>&1
            [ -d '\(storage)' ] && exit 0
            sleep 3
        done
        echo "cannot unlock the \(name) volume (\(volumeUUID))" >&2
        exit 1

        """
    }

    public static var daemonPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>\(unlockerPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>

        """
    }

    /// The volume's UUID in `container` (`diskutil apfs list -plist`), nil when there is none by that name.
    static func volumeUUID(inAPFSList plist: [String: Any], container: String) -> String? {
        let containers = plist["Containers"] as? [[String: Any]] ?? []
        let volumes = containers.first { $0["ContainerReference"] as? String == container }?["Volumes"] as? [[String: Any]] ?? []
        return volumes.first { $0["Name"] as? String == name }?["APFSVolumeUUID"] as? String
    }

    // MARK: Setting it up (root)

    /// Creates the volume in the container of the Data volume, or unlocks the one an earlier run made; installs the
    /// daemon; turns ownership on, Spotlight and Time Machine off; makes the storage directory `user`'s. Root only;
    /// safe to run again.
    public static func setUp(user: String, say: (String) -> Void) throws {
        let support = (keyPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        let container = try diskutilPlist(["info", "-plist", "/System/Volumes/Data"])["APFSContainerReference"] as? String
        guard let container else { throw VMDataVolumeError("cannot find the APFS container of /System/Volumes/Data") }

        var uuid = volumeUUID(inAPFSList: try diskutilPlist(["apfs", "list", "-plist"]), container: container)
        let haveKey = FileManager.default.fileExists(atPath: keyPath)
        if uuid != nil, !haveKey {
            throw VMDataVolumeError("""
                a \(name) volume exists but its passphrase (\(keyPath)) is gone: delete the volume (`sudo diskutil \
                apfs deleteVolume \(uuid!)`, which deletes its images) and run this again
                """)
        }
        if !haveKey {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw VMDataVolumeError("cannot make a passphrase")
            }
            let passphrase = bytes.map { String(format: "%02x", $0) }.joined()
            guard FileManager.default.createFile(atPath: keyPath, contents: Data(passphrase.utf8), attributes: [.posixPermissions: 0o600])
            else { throw VMDataVolumeError("cannot write \(keyPath)") }
        }
        if uuid == nil {
            say("creating the encrypted \(name) volume in \(container)")
            try run(["/usr/sbin/diskutil", "apfs", "addVolume", container, "APFS", name, "-stdinpassphrase"], stdin: keyPath)
            uuid = volumeUUID(inAPFSList: try diskutilPlist(["apfs", "list", "-plist"]), container: container)
        }
        guard let uuid else { throw VMDataVolumeError("diskutil made no \(name) volume in \(container)") }
        if !FileManager.default.fileExists(atPath: mountPoint) {
            try run(["/usr/sbin/diskutil", "apfs", "unlockVolume", uuid, "-user", "disk", "-stdinpassphrase"], stdin: keyPath)
        }

        try unlockerScript(volumeUUID: uuid).write(toFile: unlockerPath, atomically: true, encoding: .utf8)
        try daemonPlist.write(toFile: daemonPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unlockerPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: daemonPath)
        _ = try? run(["/bin/launchctl", "bootout", "system/" + daemonLabel])
        try run(["/bin/launchctl", "bootstrap", "system", daemonPath])

        try run(["/usr/sbin/diskutil", "enableOwnership", mountPoint])
        // Spotlight only wastes time on disk images; not worth failing the setup over.
        _ = try? run(["/usr/bin/mdutil", "-i", "off", mountPoint])
        try run(["/usr/bin/tmutil", "addexclusion", "-v", mountPoint])
        try run(["/bin/mkdir", "-p", storage])
        try run(["/usr/sbin/chown", user + ":staff", storage])
        try run(["/bin/chmod", "700", storage])
    }

    static func diskutilPlist(_ arguments: [String]) throws -> [String: Any] {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw VMDataVolumeError("diskutil \(arguments.joined(separator: " ")) failed") }
        return plist
    }

    /// Runs a command with this terminal's output, `stdin` (a file) as its input.
    static func run(_ arguments: [String], stdin: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        if let stdin { process.standardInput = FileHandle(forReadingAtPath: stdin) }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VMDataVolumeError("\(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }
    }
}

public struct VMDataVolumeError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}
