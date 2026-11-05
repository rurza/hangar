import Darwin
import Foundation
import HangarCore

/// Finds App Store Connect API key files (`AuthKey_<KEYID>.p8`) where Apple's tools look for them
/// (`$API_PRIVATE_KEYS_DIR`, `./private_keys`, `~/private_keys`, `~/.private_keys`,
/// `~/.appstoreconnect/private_keys`) and in `~/Downloads`. Only names and dates are read, never contents.
struct ASCKeyScanner {
    let environment: SetupEnvironment

    /// Key files bigger than this are not keys (a .p8 is about 250 bytes).
    static let maximumSize = 16 * 1024

    /// `~/Downloads`, where a browser names a second download of the same file `AuthKey_<ID> (1).p8`.
    var downloads: String { URL(fileURLWithPath: environment.homeDirectory).appendingPathComponent("Downloads").path }

    var directories: [String] {
        let home = URL(fileURLWithPath: environment.homeDirectory)
        var directories: [String] = []
        if let custom = environment.environment["API_PRIVATE_KEYS_DIR"], !custom.isEmpty {
            directories.append(URL(fileURLWithPath: custom, relativeTo: URL(fileURLWithPath: environment.currentDirectory)).path)
        }
        directories.append(URL(fileURLWithPath: environment.currentDirectory).appendingPathComponent("private_keys").path)
        for relative in ["private_keys", ".private_keys", ".appstoreconnect/private_keys", "Downloads"] {
            directories.append(home.appendingPathComponent(relative).path)
        }
        return directories
    }

    /// The key ID of an `AuthKey_<KEYID>.p8` name: 8 to 12 uppercase letters and digits; with `duplicates`, also
    /// a browser's `AuthKey_<KEYID> (1).p8`.
    static func keyID(fileName: String, duplicates: Bool = false) -> String? {
        if let match = fileName.wholeMatch(of: /AuthKey_([A-Z0-9]{8,12})\.p8/) { return String(match.1) }
        guard duplicates else { return nil }
        return fileName.wholeMatch(of: /AuthKey_([A-Z0-9]{8,12}) \(\d{1,3}\)\.p8/).map { String($0.1) }
    }

    /// Every key file found, newest first; one entry per file even when two directories are the same.
    func scan() -> [FoundASCKey] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var found: [FoundASCKey] = []
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names {
                guard let keyID = Self.keyID(fileName: name, duplicates: directory == downloads) else { continue }
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).standardizedFileURL.path
                let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().appendingPathComponent(name).path
                // The file itself must be a regular file: a symbolic link (to ~/.ssh, say) is skipped, not followed.
                guard seen.insert(resolved).inserted,
                    let attributes = try? fileManager.attributesOfItem(atPath: path),
                    attributes[.type] as? FileAttributeType == .typeRegular,
                    let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= Self.maximumSize
                else { continue }
                let modified = attributes[.modificationDate] as? Date ?? .distantPast
                found.append(FoundASCKey(keyID: keyID, path: path, displayPath: displayPath(path), modifiedAt: modified))
            }
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// `path` with the home directory written as `~`.
    func displayPath(_ path: String) -> String {
        let home = URL(fileURLWithPath: environment.homeDirectory).standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The contents of a scanned key file, read without following a symbolic link and never more than
    /// `maximumSize` bytes; nil when it is no longer a small regular file (or cannot be opened).
    static func read(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0,
            info.st_size <= maximumSize
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumSize + 1)
        var total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + total, $0.count - total) }
            if count <= 0 { break }
            total += count
        }
        guard total > 0, total <= maximumSize else { return nil }
        return String(decoding: buffer.prefix(total), as: UTF8.self)
    }
}
