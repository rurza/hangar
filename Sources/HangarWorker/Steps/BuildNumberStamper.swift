import Foundation

/// One bundle whose `CFBundleVersion` was rewritten. `relativePath` is relative to the archive's
/// `Products/Applications`; `previous` is the old value, or nil when the plist had none.
public struct StampedBundle: Equatable, Sendable {
    public let relativePath: String
    public let previous: String?

    public init(relativePath: String, previous: String?) {
        self.relativePath = relativePath
        self.previous = previous
    }
}

public enum StampError: Error, Equatable, CustomStringConvertible {
    case noApplication(archivePath: String)
    case multipleApplications(archivePath: String, names: [String])
    case unreadablePlist(String)
    case verificationFailed(bundle: String, found: String?)

    public var description: String {
        switch self {
        case .noApplication(let archivePath): "no .app in \(archivePath)/Products/Applications"
        case .multipleApplications(let archivePath, let names):
            "\(archivePath)/Products/Applications holds more than one app: \(names.joined(separator: ", "))"
        case .unreadablePlist(let path): "cannot read or rewrite the property list at \(path)"
        case .verificationFailed(let bundle, let found):
            "CFBundleVersion of \(bundle) reads back as \(found ?? "(none)") after stamping"
        }
    }
}

/// Sets `CFBundleVersion` to Hangar's assigned build number inside a finished archive, the way Xcode Cloud does:
/// the app, its app extensions, App Clips and watch apps (recursively) are stamped; login items, privileged helpers,
/// XPC services and frameworks keep their own versions. `CURRENT_PROJECT_VERSION` is never overridden, so a project
/// that hard-codes its plist value (or pins a helper's version) is handled the same way as any other.
///
/// Rewriting the Info.plists invalidates the archive's code signature by design; `-exportArchive` re-signs.
public struct BuildNumberStamper {
    /// Bundle directories searched inside every stamped bundle, relative to the bundle root, covering the flat (iOS)
    /// and `Contents/` (macOS) layouts. `Watch` and `AppClips` hold apps, the others app extensions.
    private static let nestedLocations: [(directory: String, pathExtension: String)] = [
        ("PlugIns", "appex"), ("Extensions", "appex"),
        ("Contents/PlugIns", "appex"), ("Contents/Extensions", "appex"),
        ("Watch", "app"), ("AppClips", "app"),
    ]

    private struct Pending {
        let relativePath: String
        let plistPath: String
        let previous: String?
        let data: Data
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Stamps every eligible bundle under `Products/Applications` and returns them depth-first, sorted by name. The
    /// archive's own `Info.plist` (`ApplicationProperties.CFBundleVersion`) is stamped too but is not part of the
    /// result: the list is for app bundles. Nothing is written unless every plist can be read and re-encoded first.
    @discardableResult
    public func stamp(archivePath: String, buildNumber: Int, log: @Sendable (String) -> Void) throws -> [StampedBundle] {
        let version = "\(buildNumber)"
        let applications = archivePath + "/Products/Applications"
        let apps = ((try? fileManager.contentsOfDirectory(atPath: applications)) ?? [])
            .filter { $0.hasSuffix(".app") }.sorted()
        guard let app = apps.first else { throw StampError.noApplication(archivePath: archivePath) }
        guard apps.count == 1 else { throw StampError.multipleApplications(archivePath: archivePath, names: apps) }

        var pending: [Pending] = []
        try collect(relativePath: app, root: applications, version: version, into: &pending)
        let archiveUpdate = try archivePlistUpdate(archivePath: archivePath, version: version, log: log)

        for item in pending {
            try write(item.data, to: item.plistPath)
            log("stamp: \(item.relativePath) CFBundleVersion \(item.previous ?? "(none)") → \(version)")
        }
        if let archiveUpdate { try write(archiveUpdate.data, to: archiveUpdate.path) }

        for item in pending {
            let found = try readPlist(at: item.plistPath).plist["CFBundleVersion"] as? String
            guard found == version else { throw StampError.verificationFailed(bundle: item.relativePath, found: found) }
        }
        if let archiveUpdate {
            let properties = try readPlist(at: archiveUpdate.path).plist["ApplicationProperties"] as? [String: Any]
            let found = properties?["CFBundleVersion"] as? String
            guard found == version else { throw StampError.verificationFailed(bundle: "Info.plist", found: found) }
        }
        return pending.map { StampedBundle(relativePath: $0.relativePath, previous: $0.previous) }
    }

    // MARK: - Planning

    /// Reads and re-encodes the bundle's plist, then recurses into its nested bundles in name order.
    private func collect(relativePath: String, root: String, version: String, into pending: inout [Pending]) throws {
        let bundle = root + "/" + relativePath
        let macPlist = bundle + "/Contents/Info.plist"
        let plistPath = fileManager.fileExists(atPath: macPlist) ? macPlist : bundle + "/Info.plist"
        var (plist, format) = try readPlist(at: plistPath)
        let previous = plist["CFBundleVersion"] as? String
        plist["CFBundleVersion"] = version
        pending.append(
            Pending(relativePath: relativePath, plistPath: plistPath, previous: previous, data: try encode(plist, format: format, path: plistPath)))

        var children: [String] = []
        for location in Self.nestedLocations {
            let names = (try? fileManager.contentsOfDirectory(atPath: bundle + "/" + location.directory)) ?? []
            children += names.filter { $0.hasSuffix("." + location.pathExtension) }.map { relativePath + "/" + location.directory + "/" + $0 }
        }
        for child in children.sorted() {
            try collect(relativePath: child, root: root, version: version, into: &pending)
        }
    }

    /// The re-encoded archive `Info.plist`, or nil (with a log line) when it has no `ApplicationProperties` to stamp.
    private func archivePlistUpdate(archivePath: String, version: String, log: @Sendable (String) -> Void) throws -> (path: String, data: Data)? {
        let path = archivePath + "/Info.plist"
        guard fileManager.fileExists(atPath: path) else {
            log("stamp: archive Info.plist not found, skipping its ApplicationProperties")
            return nil
        }
        var (plist, format) = try readPlist(at: path)
        guard var properties = plist["ApplicationProperties"] as? [String: Any] else {
            log("stamp: archive Info.plist has no ApplicationProperties, skipping it")
            return nil
        }
        properties["CFBundleVersion"] = version
        plist["ApplicationProperties"] = properties
        return (path, try encode(plist, format: format, path: path))
    }

    // MARK: - Plist I/O

    private func readPlist(at path: String) throws -> (plist: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = fileManager.contents(atPath: path),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
            let plist = object as? [String: Any]
        else { throw StampError.unreadablePlist(path) }
        return (plist, format)
    }

    private func encode(_ plist: [String: Any], format: PropertyListSerialization.PropertyListFormat, path: String) throws -> Data {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0) else {
            throw StampError.unreadablePlist(path)
        }
        return data
    }

    private func write(_ data: Data, to path: String) throws {
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { throw StampError.unreadablePlist(path) }
    }
}
