import Foundation

/// The VM storage directory (VM builds design, *Image storage*), all on one APFS volume:
///
/// ```
/// keys/                       id_ed25519, id_ed25519.pub: the host's key into every guest
/// images/<name>/              config.json disk.img nvram.bin (Tart's layout), image.json, known_hosts
/// images/<name>/slots/<n>/    disk.img nvram.bin (clones), state.vzstate, slot.json
/// images/.partial-<name>/     an import or image build in progress, renamed to <name> when complete
/// jobs/<job-id>/              disk.img nvram.bin (clones), share/; deleted when the job ends
/// ```
///
/// Everything is private to the worker's user (0700 directories): a running job's clone holds its secrets.
public struct VMStorage: Sendable, Equatable {
    public var root: String

    public init(root: String) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
    }

    public var keys: String { root + "/keys" }
    public var privateKey: String { keys + "/id_ed25519" }
    public var publicKey: String { privateKey + ".pub" }
    public var images: String { root + "/images" }
    public var jobs: String { root + "/jobs" }

    public func image(_ name: String) -> VMImageDirectory { VMImageDirectory(path: images + "/" + name, name: name) }
    /// Where an import or a build of `name` is assembled.
    public func partialImage(_ name: String) -> VMImageDirectory {
        VMImageDirectory(path: images + "/" + Self.partialPrefix + name, name: name)
    }
    public func job(_ id: UUID) -> VMJobDirectory { VMJobDirectory(path: jobs + "/" + id.uuidString) }

    static let partialPrefix = ".partial-"

    /// Image names are directory names: letters, digits, `.`, `-` and `_`, not starting with a dot.
    public static func isValidImageName(_ name: String) -> Bool {
        guard let first = name.first, first != ".", name.count <= 64 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Creates the root, `keys`, `images` and `jobs` at mode 0700.
    public func create() throws {
        for directory in [root, keys, images, jobs] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try WorkerPrivacy.setMode(0o700, at: directory)
        }
    }

    /// The complete images, by name; partial ones are skipped.
    public func imageNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: images)) ?? []
        return names.filter { !$0.hasPrefix(".") && FileManager.default.fileExists(atPath: images + "/" + $0 + "/" + VMImageDirectory.metadataName) }
            .sorted()
    }

    /// Deletes every job clone: no VM outlives the process that ran it (`kill -9` of the owner ends its VM), so
    /// whatever is in `jobs/` at start-up is a leftover. Returns the names removed.
    @discardableResult
    public func sweepJobs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: jobs)) ?? []
        var removed: [String] = []
        for name in names.sorted() {
            if (try? SafeRemoval.removeItem(atPath: jobs + "/" + name, within: jobs)) != nil { removed.append(name) }
        }
        return removed
    }

    /// What an interrupted `VZMacOSInstaller` leaves in the temporary directory (the spike found 1 GiB there).
    @discardableResult
    public static func sweepInstallerLeftovers(temporaryDirectory: String = NSTemporaryDirectory()) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)) ?? []
        var removed: [String] = []
        for name in names where name.hasPrefix("com.apple.Virtualization.Installation.") {
            if (try? FileManager.default.removeItem(atPath: (temporaryDirectory as NSString).appendingPathComponent(name))) != nil {
                removed.append(name)
            }
        }
        return removed
    }
}

/// One image: Tart's `config.json`, `disk.img` and `nvram.bin`, plus Hangar's `image.json`.
public struct VMImageDirectory: Sendable, Equatable {
    public var path: String
    public var name: String

    static let metadataName = "image.json"

    public var config: String { path + "/config.json" }
    public var disk: String { path + "/disk.img" }
    public var nvram: String { path + "/nvram.bin" }
    public var metadata: String { path + "/" + Self.metadataName }
    /// The guest's SSH host keys, recorded when the image was built: every clone has the same ones.
    public var knownHosts: String { path + "/known_hosts" }
    public var slots: String { path + "/slots" }
    public func slot(_ index: Int) -> VMSlotDirectory { VMSlotDirectory(path: slots + "/\(index)", index: index) }
}

/// A slot of an image: its own disk and NVRAM clones and the state saved from them.
public struct VMSlotDirectory: Sendable, Equatable {
    public var path: String
    public var index: Int

    public var disk: String { path + "/disk.img" }
    public var nvram: String { path + "/nvram.bin" }
    public var state: String { path + "/state.vzstate" }
    public var metadata: String { path + "/slot.json" }
    /// The empty directory the slot's share device pointed at when its state was saved.
    public var share: String { path + "/share" }
}

/// A job's clone; the whole directory goes when the job ends.
public struct VMJobDirectory: Sendable, Equatable {
    public var path: String

    public var disk: String { path + "/disk.img" }
    public var nvram: String { path + "/nvram.bin" }
    /// Mounted read-only in the guest (tag `hangar`). Never holds a secret.
    public var share: String { path + "/share" }
}

public enum VMStorageError: Error, Equatable, CustomStringConvertible {
    case notAPFS(path: String, type: String)
    case ownershipIgnored(path: String)
    case cloneFailed(from: String, to: String, errno: Int32)
    case unreadable(String)

    public var description: String {
        switch self {
        case .notAPFS(let path, let type):
            "\(path) is on a \(type) volume; VM storage must be on APFS, where disks clone in an instant"
        case .ownershipIgnored(let path):
            "the volume of \(path) ignores ownership, so every local user could read a running job's clone; run `sudo diskutil enableOwnership <volume>`"
        case .cloneFailed(let from, let to, let code):
            code == EXDEV
                ? "cannot clone \(from) to \(to): they are on different volumes"
                : "cannot clone \(from) to \(to): \(String(cString: strerror(code)))"
        case .unreadable(let path): "cannot read \(path)"
        }
    }
}

/// Volume facts and APFS clones.
public enum VMVolume {
    /// An APFS clone: instant, and it shares blocks until either copy changes. Fails across volumes.
    public static func clone(_ source: String, to destination: String) throws {
        guard clonefile(source, destination, 0) == 0 else {
            throw VMStorageError.cloneFailed(from: source, to: destination, errno: errno)
        }
    }

    /// The file system type ("apfs", "hfs", "exfat") of the volume holding `path`, or of its nearest existing parent.
    public static func fileSystemType(of path: String) -> String? {
        volumeInfo(of: path).map { info in
            withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    /// False on a volume mounted with "Ignore ownership" (external drives by default).
    public static func ownershipEnabled(at path: String) -> Bool {
        guard let info = volumeInfo(of: path) else { return false }
        return info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
    }

    /// The mount point of the volume holding `path` ("/Volumes/SSD"), or nil.
    public static func mountPoint(of path: String) -> String? {
        volumeInfo(of: path).map { info in
            withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    public static func freeGB(at path: String) -> Double {
        guard let info = volumeInfo(of: path) else { return 0 }
        return Double(info.f_bavail) * Double(info.f_bsize) / 1_000_000_000
    }

    /// Nil when `path` can hold VM storage, else why not.
    public static func problem(at path: String) -> VMStorageError? {
        guard let type = fileSystemType(of: path) else { return .unreadable(path) }
        guard type == "apfs" else { return .notAPFS(path: path, type: type) }
        guard ownershipEnabled(at: path) else { return .ownershipIgnored(path: path) }
        return nil
    }

    private static func volumeInfo(of path: String) -> Darwin.statfs? {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        while true {
            var info = Darwin.statfs()
            if statfs(candidate, &info) == 0 { return info }
            guard candidate != "/" else { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }
}
