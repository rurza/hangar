import Foundation
import HangarCore

/// Finds installed Xcodes: every `Xcode*.app` in the applications directory plus the one `xcode-select` points at.
public struct XcodeLocator: Sendable {
    private let runner: any ProcessRunner
    private let applicationsDirectory: String

    public init(runner: any ProcessRunner, applicationsDirectory: String = "/Applications") {
        self.runner = runner
        self.applicationsDirectory = applicationsDirectory
    }

    /// Newest version first. Bundles without a readable `version.plist` are skipped.
    public func installed() async throws -> [InstalledXcode] {
        var paths = Self.scan(applicationsDirectory)
        if let selected = await selectedApp(), !paths.contains(selected) { paths.append(selected) }
        return paths.compactMap(Self.read).sorted { Self.components($1.version).lexicographicallyPrecedes(Self.components($0.version)) }
    }

    private static func scan(_ directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().map { directory + "/" + $0 }
    }

    /// `xcode-select -p` prints `<app>/Contents/Developer`; the Command Line Tools path is not an Xcode.
    private func selectedApp() async -> String? {
        let command = ProcessCommand(executable: "/usr/bin/xcode-select", arguments: ["-p"])
        guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0 else { return nil }
        let suffix = "/Contents/Developer"
        let path = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasSuffix(suffix) else { return nil }
        return String(path.dropLast(suffix.count))
    }

    private static func read(_ app: String) -> InstalledXcode? {
        guard let data = FileManager.default.contents(atPath: app + "/Contents/version.plist"),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return InstalledXcode(version: version, build: plist["ProductBuildVersion"] as? String ?? "", path: app)
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
