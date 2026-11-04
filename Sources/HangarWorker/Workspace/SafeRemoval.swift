import Foundation

public enum SafeRemovalError: Error, Equatable, CustomStringConvertible {
    case outsideRoot(path: String, root: String)

    public var description: String {
        switch self {
        case .outsideRoot(let path, let root): "refusing to remove '\(path)': not strictly inside '\(root)'"
        }
    }
}

/// Recursive removal confined to one directory, for outputs whose paths are partly derived from untrusted input
/// (scheme names from `.hangar.yml`) or from the caller.
public enum SafeRemoval {
    /// Removes `path` only if it is absolute, already standardized (no `..`, `.` or doubled slashes) and strictly
    /// inside `root`. A path that does not exist is fine; any other removal error is thrown.
    public static func removeItem(atPath path: String, within root: String) throws {
        guard isStrictlyInside(path, root: root) else { throw SafeRemovalError.outsideRoot(path: path, root: root) }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing to remove.
        }
    }

    static func isStrictlyInside(_ path: String, root: String) -> Bool {
        func standard(_ value: String) -> Bool {
            value.hasPrefix("/") && URL(fileURLWithPath: value).standardizedFileURL.path == value
        }
        guard standard(path), standard(root), root != "/" else { return false }
        return path.hasPrefix(root + "/")
    }
}
