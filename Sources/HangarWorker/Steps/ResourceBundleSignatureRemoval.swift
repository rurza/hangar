import Foundation
import HangarCore

/// Readies a VM's macOS archive for its export on the host: resource bundles (a SwiftPM target's `*.bundle`, with no
/// executable) lose their own signature.
///
/// The guest signs the archive with Hangar's development identity, and Xcode signs a macOS resource bundle as well.
/// `-exportArchive` re-signs the app, its extensions and login items for distribution, but leaves those bundles as they
/// were, so App Store Connect refuses the build (ITMS-90284: "must be signed with the certificate that is contained
/// in the provisioning profile"). A resource bundle holds no code: unsigned, it is sealed as a resource by the
/// signature the export gives the bundle that contains it.
public enum ResourceBundleSignatureRemoval {
    /// Removes `Contents/_CodeSignature` from every `.bundle` under the archive's `Products` that has no
    /// `Contents/MacOS`; returns their paths inside the archive. Symbolic links are not followed.
    @discardableResult
    public static func run(archivePath: String, log: @escaping @Sendable (String) -> Void) throws -> [String] {
        let products = archivePath + "/Products"
        guard let enumerator = FileManager.default.enumerator(atPath: products) else { return [] }
        let fileManager = FileManager.default
        var removed: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".bundle"), enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            else { continue }
            let bundle = products + "/" + relative
            let signature = bundle + "/Contents/_CodeSignature"
            guard fileManager.fileExists(atPath: signature), !fileManager.fileExists(atPath: bundle + "/Contents/MacOS")
            else { continue }
            try SafeRemoval.removeItem(atPath: signature, within: bundle)
            removed.append("Products/" + relative)
        }
        if !removed.isEmpty {
            let names = removed.map { ($0 as NSString).lastPathComponent }
            log("removed the development signature of \(removed.count) resource bundle\(removed.count == 1 ? "" : "s") (\(Set(names).sorted().joined(separator: ", "))): the export seals them in the app's own signature")
        }
        return removed
    }
}
