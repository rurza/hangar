import Foundation
import Testing

@testable import HangarWorker

/// Legilo build 110, archived in a VM: App Store Connect refused it (ITMS-90284) because its SwiftPM resource bundles
/// kept the development signature of the VM's archive while the export re-signed everything else for distribution.
@Suite struct ResourceBundleSignatureRemovalTests {
    private struct Archive {
        let root = TestScratch.directory("resource-bundles").path
        var path: String { root + "/Legilo.xcarchive" }
        var app: String { path + "/Products/Applications/Legilo.app" }

        func make(_ relative: String) throws {
            let full = app + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: full))
        }

        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: app + "/" + relative) }
    }

    @Test func resourceBundlesLoseTheirSignatureAndCodeKeepsIt() throws {
        let archive = Archive()
        let resources = [
            "Contents/Resources/GRDB_GRDB.bundle",
            "Contents/Library/LoginItems/LegiloCapture.app/Contents/Resources/GRDB_GRDB.bundle",
            "Contents/PlugIns/LegiloShare.appex/Contents/Resources/Legilo_LegiloKit.bundle",
        ]
        for bundle in resources {
            try archive.make(bundle + "/Contents/Info.plist")
            try archive.make(bundle + "/Contents/_CodeSignature/CodeResources")
        }
        // Code keeps its signature: the app itself, a login item, and a bundle with an executable (a plug-in).
        try archive.make("Contents/_CodeSignature/CodeResources")
        try archive.make("Contents/Library/LoginItems/LegiloCapture.app/Contents/_CodeSignature/CodeResources")
        try archive.make("Contents/PlugIns/Loader.bundle/Contents/MacOS/Loader")
        try archive.make("Contents/PlugIns/Loader.bundle/Contents/_CodeSignature/CodeResources")
        // Unsigned already: nothing to do.
        try archive.make("Contents/Resources/Plain.bundle/Contents/Info.plist")

        let removed = try ResourceBundleSignatureRemoval.run(archivePath: archive.path, log: { _ in })

        #expect(Set(removed) == Set(resources.map { "Products/Applications/Legilo.app/" + $0 }))
        for bundle in resources {
            #expect(!archive.exists(bundle + "/Contents/_CodeSignature"))
            #expect(archive.exists(bundle + "/Contents/Info.plist"))
        }
        #expect(archive.exists("Contents/_CodeSignature/CodeResources"))
        #expect(archive.exists("Contents/Library/LoginItems/LegiloCapture.app/Contents/_CodeSignature/CodeResources"))
        #expect(archive.exists("Contents/PlugIns/Loader.bundle/Contents/_CodeSignature/CodeResources"))
    }

    @Test func anArchiveWithoutResourceBundlesIsLeftAlone() throws {
        let archive = Archive()
        try archive.make("Contents/_CodeSignature/CodeResources")
        #expect(try ResourceBundleSignatureRemoval.run(archivePath: archive.path, log: { _ in }).isEmpty)
        #expect(archive.exists("Contents/_CodeSignature/CodeResources"))
    }
}
