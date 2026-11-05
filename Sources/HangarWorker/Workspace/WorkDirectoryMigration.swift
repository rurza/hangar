import Foundation

/// Moves the cached per-app workspaces (git checkout and DerivedData) from the data directory into the work
/// directory the first time a worker runs with a separate one, so the next build fetches instead of cloning and keeps
/// its Swift package clones. A rename on the same volume, so it is instant whatever the size.
///
/// DerivedData records absolute paths (SwiftPM's `workspace-state.json` names its checkouts and artifact bundles, the
/// build's PIF cache names the sources), so a moved one fails with "artifact bundle info.json not found at <old path>".
/// Those path-bound parts are dropped after the move; the git mirrors in `SourcePackages/repositories` are kept.
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
            for name in (try? fileManager.contentsOfDirectory(atPath: new)) ?? [] where !name.hasPrefix(".") {
                dropPathBoundCaches(inWorkspace: new + "/" + name)
            }
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
                dropPathBoundCaches(inWorkspace: destination)
                lines.append("moved the workspace \(name) from \(old) to \(new)")
            }
        }
        if (try? fileManager.contentsOfDirectory(atPath: old).filter { !$0.hasPrefix(".") }.isEmpty) == true {
            try? fileManager.removeItem(atPath: old)
        }
        return lines
    }

    /// The parts of a workspace's DerivedData that name absolute paths, relative to the workspace.
    static let pathBoundCaches = [
        "DerivedData/Build",
        "DerivedData/SourcePackages/workspace-state.json",
        "DerivedData/SourcePackages/artifacts",
        "DerivedData/SourcePackages/checkouts",
    ]

    /// The file in DerivedData naming the workspace it was built in.
    static let ownerFile = "DerivedData/.hangar-workspace"

    /// Drops the path-bound caches unless DerivedData records that it belongs to this workspace: a workspace moved by
    /// a worker without the drop above (0.6.0), or by hand. SwiftPM's state alone can't tell, since a package
    /// resolution rewrites it while the build's PIF cache keeps the old paths. Then records this workspace. Returns
    /// whether it dropped anything.
    @discardableResult
    public static func dropStaleCaches(inWorkspace workspace: String) -> Bool {
        let fileManager = FileManager.default
        let owner = workspace + "/" + ownerFile
        if (try? String(contentsOfFile: owner, encoding: .utf8)) == workspace { return false }
        let stale = pathBoundCaches.contains { fileManager.fileExists(atPath: workspace + "/" + $0) }
        if stale { dropPathBoundCaches(inWorkspace: workspace) }
        try? fileManager.createDirectory(atPath: workspace + "/DerivedData", withIntermediateDirectories: true)
        try? workspace.write(toFile: owner, atomically: true, encoding: .utf8)
        return stale
    }

    static func dropPathBoundCaches(inWorkspace workspace: String) {
        for path in pathBoundCaches {
            try? FileManager.default.removeItem(atPath: workspace + "/" + path)
        }
    }
}
