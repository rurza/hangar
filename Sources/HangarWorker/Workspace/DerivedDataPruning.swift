import Foundation

/// Empties a workspace's DerivedData after a job: build products, intermediates, the compilation and module caches,
/// logs and package checkouts take tens of GB per app and grow with every build. Only the package git mirrors
/// (`SourcePackages/repositories`, small) and the record of whose DerivedData it is are kept, so the next build fetches
/// its packages instead of cloning them, and compiles from scratch.
public enum DerivedDataPruning {
    static let kept: Set<String> = ["SourcePackages", (WorkDirectoryMigration.ownerFile as NSString).lastPathComponent]
    static let keptInSourcePackages: Set<String> = ["repositories"]

    public static func prune(_ derivedData: String) throws {
        try removeAll(in: derivedData, except: kept)
        try removeAll(in: derivedData + "/SourcePackages", except: keptInSourcePackages)
    }

    private static func removeAll(in directory: String, except kept: Set<String>) throws {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in names where !kept.contains(name) {
            try SafeRemoval.removeItem(atPath: directory + "/" + name, within: directory)
        }
    }
}
