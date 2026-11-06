import Foundation
import HangarCore

/// Readies a VM archive for a Developer ID export (VM builds design, *First slice as built*, decision 25).
///
/// The guest signs manually with Hangar's development profiles, so every bundle with a profile also carries the
/// entitlements a profile brings (`com.apple.application-identifier`, `com.apple.developer.team-identifier`). From
/// those, `-exportArchive` concludes the app needs a Developer ID profile, which an App Store Connect key cannot make
/// ("Cloud signing permission error", then "No profiles for … were found"). A host archive of the same app signs
/// automatically, and Xcode embeds no profile when the entitlements need none; its export then signs with the host's
/// Developer ID identity alone.
///
/// So, when no bundle's own entitlements need a profile, each bundle with one loses its profile and the
/// profile-derived entitlements and is re-signed ad hoc (the export re-signs it with Developer ID anyway); the archive
/// then looks like a host archive. When one does need a profile, nothing changes and the export runs as it is.
public struct DevelopmentProfileRemoval: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// No bundle in the archive has a profile.
        case nothingToRemove
        /// These bundles (paths inside the archive) lost their profile and were re-signed ad hoc.
        case removed([String])
        /// `bundle` (a path inside the archive) has entitlements that need a profile; the archive was left alone.
        case profileNeeded(bundle: String, entitlements: [String])
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadableEntitlements(bundle: String)
        case codesignFailed(bundle: String, exitCode: Int32)

        public var description: String {
            switch self {
            case .unreadableEntitlements(let bundle): "could not read the entitlements of \(bundle)"
            case .codesignFailed(let bundle, let exitCode): "codesign of \(bundle) exited with status \(exitCode)"
            }
        }
    }

    /// What signing with a profile adds, or a development build: never needed by a Developer ID export.
    static let profileEntitlements: Set<String> = [
        "com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.security.get-task-allow",
    ]

    /// Whether an entitlement needs a provisioning profile on macOS. Only the sandbox and hardened runtime family
    /// (`com.apple.security.…`) is known not to; app groups are counted as needing one, since macOS 15 checks
    /// `group.` identifiers against a profile. Anything else is assumed to need one.
    static func needsProfile(_ entitlement: String) -> Bool {
        !entitlement.hasPrefix("com.apple.security.") || entitlement == "com.apple.security.application-groups"
    }

    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    /// `scratchDirectory` takes the entitlements files for `codesign`; it must exist.
    public func run(
        archivePath: String, scratchDirectory: String, environment: [String: String],
        log: @escaping @Sendable (String) -> Void
    ) async throws -> Outcome {
        let bundles = Self.bundlesWithProfiles(in: archivePath)
        guard !bundles.isEmpty else { return .nothingToRemove }

        var kept: [(bundle: String, entitlements: [String: Any])] = []
        for bundle in bundles {
            let entitlements = try await entitlements(of: bundle, environment: environment)
                .filter { !Self.profileEntitlements.contains($0.key) }
            let needing = entitlements.keys.filter(Self.needsProfile).sorted()
            if !needing.isEmpty {
                let name = Self.relative(bundle, to: archivePath)
                log("\(name) has entitlements that need a provisioning profile (\(needing.joined(separator: ", "))), so its development profile stays; the Developer ID export needs a Developer ID profile for it, which Hangar does not create")
                return .profileNeeded(bundle: name, entitlements: needing)
            }
            kept.append((bundle, entitlements))
        }

        for (index, item) in kept.enumerated() {
            try SafeRemoval.removeItem(atPath: item.bundle + "/Contents/embedded.provisionprofile", within: archivePath)
            var arguments = ["--force", "--sign", "-", "--preserve-metadata=identifier,flags,runtime"]
            if !item.entitlements.isEmpty {
                let path = scratchDirectory + "/entitlements-\(index).plist"
                try PropertyListSerialization.data(fromPropertyList: item.entitlements, format: .xml, options: 0)
                    .write(to: URL(fileURLWithPath: path))
                arguments += ["--entitlements", path, "--generate-entitlement-der"]
            }
            let outcome = try await runner.run(
                ProcessCommand(executable: "/usr/bin/codesign", arguments: arguments + [item.bundle], environment: environment),
                onLine: log)
            guard outcome.exitCode == 0 else {
                throw Failure.codesignFailed(bundle: Self.relative(item.bundle, to: archivePath), exitCode: outcome.exitCode)
            }
        }
        let names = kept.map { Self.relative($0.bundle, to: archivePath) }
        log("removed Hangar's development profile from \(names.joined(separator: ", ")) and re-signed ad hoc, as a host archive would be: no entitlement needs a profile, and the export signs with this Mac's Developer ID identity")
        return .removed(names)
    }

    /// The signed entitlements of `bundle`; empty when it has none.
    private func entitlements(of bundle: String, environment: [String: String]) async throws -> [String: Any] {
        var command = ProcessCommand(
            executable: "/usr/bin/codesign", arguments: ["-d", "--entitlements", "-", "--xml", bundle], environment: environment)
        command.discardsStandardError = true
        let outcome = try await runner.run(command, onLine: { _ in })
        guard outcome.exitCode == 0 else { throw Failure.unreadableEntitlements(bundle: bundle) }
        let text = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any]
        else { throw Failure.unreadableEntitlements(bundle: bundle) }
        return plist
    }

    /// Every bundle under `Products` with a `Contents/embedded.provisionprofile` that is a regular file, deepest
    /// first, so a nested bundle is re-signed before the one that holds it. Symbolic links are not followed.
    static func bundlesWithProfiles(in archivePath: String) -> [String] {
        let products = archivePath + "/Products"
        guard let enumerator = FileManager.default.enumerator(atPath: products) else { return [] }
        var bundles: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let components = relative.split(separator: "/").map(String.init)
            guard components.count >= 3, components.last == "embedded.provisionprofile",
                components[components.count - 2] == "Contents",
                enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular
            else { continue }
            bundles.append(products + "/" + components.dropLast(2).joined(separator: "/"))
        }
        return bundles.sorted { ($0.split(separator: "/").count, $0) > ($1.split(separator: "/").count, $1) }
    }

    private static func relative(_ path: String, to archivePath: String) -> String {
        path.hasPrefix(archivePath + "/") ? String(path.dropFirst(archivePath.count + 1)) : path
    }
}
