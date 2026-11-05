import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite struct VMImageImporterTests {
    @Test func referencesMustBeParseableAndArePinnedByDigest() throws {
        let reference = try #require(OCIReference(VMImageImporter.defaultVanilla))
        #expect(reference.registry == "ghcr.io")
        #expect(reference.repository == "cirruslabs/macos-tahoe-vanilla")
        #expect(reference.tag == "26.6.2")
        #expect(reference.digest?.hasPrefix("sha256:eeec54bf") == true)
        #expect(reference.description == VMImageImporter.defaultVanilla)
        #expect(OCIReference("ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2")?.digest == nil)
        #expect(OCIReference("no-registry") == nil)
        #expect(OCIReference("ghcr.io/x@sha256:short") == nil)
    }

    @Test func anUnpinnedReferenceIsRefusedBeforeAnyDownload() async throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let importer = VMImageImporter(floorGB: 40, progress: { _ in })
        await #expect(throws: VMImportError.notPinned("ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2")) {
            try await importer.importImage(
                OCIReference("ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2")!, as: "v", into: fixture.storage)
        }
        await #expect(throws: VMImportError.exists("xcode-27.2")) {
            try await importer.importImage(OCIReference(VMImageImporter.defaultVanilla)!, as: "xcode-27.2", into: fixture.storage)
        }
    }

    @Test func theRegistrysChallengeNamesWhereToGetAToken() {
        let fields = Registry.challengeFields(#"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:cirruslabs/x:pull""#)
        #expect(fields == ["realm": "https://ghcr.io/token", "service": "ghcr.io", "scope": "repository:cirruslabs/x:pull"])
        #expect(Registry.challengeFields("Basic realm=x").isEmpty)
    }

    @Test func aChunkDecompressesIntoPlaceLeavingZerosAsHoles() throws {
        let directory = NSTemporaryDirectory() + "hangar-oci-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // 4 MiB: a marker, zeros, a marker.
        var plain = Data(count: 4 << 20)
        plain.replaceSubrange(0..<5, with: Data("start".utf8))
        plain.replaceSubrange((plain.count - 3)..<plain.count, with: Data("end".utf8))
        let compressed = try (plain as NSData).compressed(using: .lz4) as Data
        let blob = URL(fileURLWithPath: directory + "/blob")
        try compressed.write(to: blob)
        let disk = directory + "/disk.img"
        FileManager.default.createFile(atPath: disk, contents: nil)
        let descriptor = open(disk, O_RDWR)
        defer { close(descriptor) }
        let offset: Int64 = 1 << 20
        ftruncate(descriptor, offset + Int64(plain.count))
        let layer = OCIManifest.Layer(
            mediaType: OCIManifest.diskType, digest: "sha256:" + SHA256File.hex(of: compressed), size: Int64(compressed.count),
            annotations: [OCIManifest.uncompressedDigest: "sha256:" + SHA256File.hex(of: plain)])
        try VMImageImporter.decompress(file: blob, layer: layer, offset: offset, into: descriptor)

        let written = try #require(FileManager.default.contents(atPath: disk))
        #expect(written.count == Int(offset) + plain.count)
        #expect(written[Int(offset)..<Int(offset) + 5] == Data("start".utf8))
        #expect(written.suffix(3) == Data("end".utf8))
        // Only the two marker blocks were written.
        var info = stat()
        stat(disk, &info)
        #expect(Int(info.st_blocks) * 512 <= 4 * 64 * 1024)

        let corrupt = OCIManifest.Layer(mediaType: layer.mediaType, digest: "sha256:" + String(repeating: "0", count: 64), size: layer.size)
        #expect(throws: VMImportError.self) { try VMImageImporter.decompress(file: blob, layer: corrupt, offset: 0, into: descriptor) }
    }

    @Test func zeroDetectionLooksAtEveryByte() {
        var bytes = [UInt8](repeating: 0, count: 100)
        bytes.withUnsafeBytes { #expect(VMImageImporter.isZero($0)) }
        bytes[99] = 1
        bytes.withUnsafeBytes { #expect(!VMImageImporter.isZero($0)) }
    }
}

@Suite struct VMImageBuilderTests {
    @Test func runtimesAreReadFromSimctlsJSON() {
        let json = #"{"runtimes":[{"name":"iOS 27.2","isAvailable":true},{"name":"watchOS 27.0","isAvailable":false},{"name":"visionOS 27.1"}]}"#
        #expect(VMImageBuilder.runtimeNames(fromJSON: Data(json.utf8)) == ["iOS 27.2", "visionOS 27.1"])
        #expect(VMImageBuilder.runtimeNames(fromJSON: Data("nope".utf8)).isEmpty)
    }

    @Test func theXcodeVersionComesFromItsVersionPlist() throws {
        let path = NSTemporaryDirectory() + "Xcode-\(UUID().uuidString).app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plist: [String: Any] = ["CFBundleShortVersionString": "27.2", "ProductBuildVersion": "17C52"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/version.plist"))
        let version = try VMImageBuilder.xcodeVersion(at: path)
        #expect(version.version == "27.2" && version.build == "17C52")
        #expect(throws: VMImageBuildError.self) { try VMImageBuilder.xcodeVersion(at: "/nonexistent") }
    }

    @Test func theVanillaPasswordIsOnlyInTheAskpassScript() {
        #expect(VMImageBuilder.askpass == "#!/bin/sh\necho admin\n")
    }

    @Test func buildingNeedsABaseImage() async throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let builder = VMImageBuilder(host: fixture.host(FakeEngine()), progress: { _ in })
        await #expect(throws: VMImageBuildError.noBaseImage("vanilla-26.6.2")) {
            _ = try await builder.build(from: "vanilla-26.6.2", xcodePath: "/Applications/Xcode.app", name: nil, platforms: [])
        }
    }
}
