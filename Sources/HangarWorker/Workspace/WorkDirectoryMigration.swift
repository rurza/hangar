import Foundation

/// Moves the cached per-app workspaces (git checkout and DerivedData) from the data directory into the work
/// directory the first time a worker runs with a separate one, so the next build fetches instead of cloning and keeps
/// its resolved Swift packages. A rename on the same volume, so it is instant whatever the size.
///
/// An app whose workspace already exists in the work directory keeps that one; the old copy is left where it was and
/// named in the log. Job directories are not moved: whatever a crashed run left there is swept at start.
public enum WorkDirectoryMigration {
    /// Returns a line for the log per thing it moved or left; nothing when there was nothing to move.
    @discardableResult
    public static func run(from dataDirectory: String, to workDirectory: String) throws -> [String] {
        let fileManager = FileManager.default
        let old = URL(fileURLWithPath: dataDirectory).standardizedFileURL.path + "/workspaces"
        let new = URL(fileURLWithPath: workDirectory).standardizedFileURL.path + "/workspaces"
        guard old != new else { return [] }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: old, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        try fileManager.createDirectory(
            atPath: (new as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard fileManager.fileExists(atPath: new) else {
            try fileManager.moveItem(atPath: old, toPath: new)
            return ["moved the workspaces from \(old) to \(new)"]
        }
        var lines: [String] = []
        for name in try fileManager.contentsOfDirectory(atPath: old).sorted() where !name.hasPrefix(".") {
            let source = old + "/" + name
            let destination = new + "/" + name
            if fileManager.fileExists(atPath: destination) {
                lines.append("kept \(destination); the older \(source) was left in place")
            } else {
                try fileManager.moveItem(atPath: source, toPath: destination)
                lines.append("moved the workspace \(name) from \(old) to \(new)")
            }
        }
        if (try? fileManager.contentsOfDirectory(atPath: old).filter { !$0.hasPrefix(".") }.isEmpty) == true {
            try? fileManager.removeItem(atPath: old)
        }
        return lines
    }
}
