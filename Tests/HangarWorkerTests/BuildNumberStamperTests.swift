import Foundation
import Testing

@testable import HangarWorker

/// Builds synthetic `.xcarchive` trees on disk; plists are written with `PropertyListSerialization`.
private struct ArchiveFixture {
    let root: String
    var applications: String { root + "/Products/Applications" }

    init() throws {
        root = NSTemporaryDirectory() + "hangar-stamper-" + UUID().uuidString + ".xcarchive"
        try FileManager.default.createDirectory(atPath: applications, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }

    /// Writes `<bundle>/Contents/Info.plist` when `macOS`, `<bundle>/Info.plist` otherwise.
    func bundle(
        _ relativePath: String, version: String?, macOS: Bool = true, format: PropertyListSerialization.PropertyListFormat = .xml,
        extra: [String: Any] = [:]
    ) throws {
        let bundle = applications + "/" + relativePath
        let directory = macOS ? bundle + "/Contents" : bundle
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "app.test." + (relativePath as NSString).lastPathComponent]
        if let version { plist["CFBundleVersion"] = version }
        plist.merge(extra) { $1 }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try data.write(to: URL(fileURLWithPath: directory + "/Info.plist"))
    }

    func archivePlist(_ properties: [String: Any]?) throws {
        let plist: [String: Any] = properties.map { ["ApplicationProperties": $0, "SchemeName": "Legilo"] } ?? ["SchemeName": "Legilo"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: root + "/Info.plist"))
    }

    func plist(_ relativePath: String, macOS: Bool = true) throws -> [String: Any] {
        try Self.read(applications + "/" + relativePath + (macOS ? "/Contents/Info.plist" : "/Info.plist")).plist
    }

    func version(_ relativePath: String, macOS: Bool = true) throws -> String? {
        try plist(relativePath, macOS: macOS)["CFBundleVersion"] as? String
    }

    static func read(_ path: String) throws -> (plist: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let data = try #require(FileManager.default.contents(atPath: path))
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return (try #require(object as? [String: Any]), format)
    }
}

@Suite struct BuildNumberStamperTests {
    @Test func stampsLegiloMacArchive() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Legilo.app", version: "1")
        try archive.bundle("Legilo.app/Contents/PlugIns/LegiloShare.appex", version: "1")
        try archive.bundle("Legilo.app/Contents/Extensions/LegiloModelDownloader.appex", version: "1")
        try archive.bundle("Legilo.app/Contents/Library/LoginItems/LegiloCapture.app", version: "1")
        try archive.archivePlist(["CFBundleVersion": "1"])

        let lines = LineSink()
        let stamped = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: lines.append)

        #expect(
            stamped == [
                StampedBundle(relativePath: "Legilo.app", previous: "1"),
                StampedBundle(relativePath: "Legilo.app/Contents/Extensions/LegiloModelDownloader.appex", previous: "1"),
                StampedBundle(relativePath: "Legilo.app/Contents/PlugIns/LegiloShare.appex", previous: "1"),
            ])
        #expect(try archive.version("Legilo.app") == "311")
        #expect(try archive.version("Legilo.app/Contents/PlugIns/LegiloShare.appex") == "311")
        #expect(try archive.version("Legilo.app/Contents/Extensions/LegiloModelDownloader.appex") == "311")
        #expect(try archive.version("Legilo.app/Contents/Library/LoginItems/LegiloCapture.app") == "1")
        #expect(
            lines.all == [
                "stamp: Legilo.app CFBundleVersion 1 → 311",
                "stamp: Legilo.app/Contents/Extensions/LegiloModelDownloader.appex CFBundleVersion 1 → 311",
                "stamp: Legilo.app/Contents/PlugIns/LegiloShare.appex CFBundleVersion 1 → 311",
            ])
    }

    @Test func stampsIOSArchiveWithWatchAndClip() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Trip.app", version: "7", macOS: false)
        try archive.bundle("Trip.app/PlugIns/Widget.appex", version: "7", macOS: false)
        try archive.bundle("Trip.app/Extensions/Intents.appex", version: "7", macOS: false)
        try archive.bundle("Trip.app/Watch/TripWatch.app", version: "7", macOS: false)
        try archive.bundle("Trip.app/Watch/TripWatch.app/PlugIns/Complication.appex", version: "7", macOS: false)
        try archive.bundle("Trip.app/AppClips/TripClip.app", version: "7", macOS: false)
        try archive.bundle("Trip.app/Frameworks/Kit.framework", version: "7", macOS: false)
        try archive.bundle("Trip.app/XPCServices/Svc.xpc", version: "7", macOS: false)

        let stamped = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })

        #expect(
            stamped.map(\.relativePath) == [
                "Trip.app",
                "Trip.app/AppClips/TripClip.app",
                "Trip.app/Extensions/Intents.appex",
                "Trip.app/PlugIns/Widget.appex",
                "Trip.app/Watch/TripWatch.app",
                "Trip.app/Watch/TripWatch.app/PlugIns/Complication.appex",
            ])
        for bundle in stamped {
            #expect(try archive.version(bundle.relativePath, macOS: false) == "311")
        }
        #expect(try archive.version("Trip.app/Frameworks/Kit.framework", macOS: false) == "7")
        #expect(try archive.version("Trip.app/XPCServices/Svc.xpc", macOS: false) == "7")
    }

    @Test func helperAndXPCServicesUntouched() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("BatFi.app", version: "99999")
        try archive.bundle("BatFi.app/Contents/Library/LaunchServices/helper", version: "49")
        try archive.bundle("BatFi.app/Contents/XPCServices/Agent.xpc", version: "5")
        try archive.bundle("BatFi.app/Contents/Frameworks/Sparkle.framework", version: "2")

        let stamped = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })

        #expect(stamped == [StampedBundle(relativePath: "BatFi.app", previous: "99999")])
        #expect(try archive.version("BatFi.app") == "311")
        #expect(try archive.version("BatFi.app/Contents/Library/LaunchServices/helper") == "49")
        #expect(try archive.version("BatFi.app/Contents/XPCServices/Agent.xpc") == "5")
        #expect(try archive.version("BatFi.app/Contents/Frameworks/Sparkle.framework") == "2")
    }

    @Test func hardCodedPlistValueIsReplaced() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Hourly Beep.app", version: "3")

        let stamped = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })

        #expect(stamped == [StampedBundle(relativePath: "Hourly Beep.app", previous: "3")])
        #expect(try archive.version("Hourly Beep.app") == "311")
    }

    @Test func binaryPlistStaysBinaryAndKeepsOtherKeys() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle(
            "Legilo.app", version: "1", format: .binary,
            extra: ["CFBundleShortVersionString": "2.4", "LSUIElement": true, "Nested": ["a": 1]])
        try archive.bundle("Legilo.app/Contents/PlugIns/Share.appex", version: "1", format: .xml)

        _ = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })

        let app = try ArchiveFixture.read(archive.applications + "/Legilo.app/Contents/Info.plist")
        #expect(app.format == .binary)
        #expect(app.plist["CFBundleVersion"] as? String == "311")
        #expect(app.plist["CFBundleShortVersionString"] as? String == "2.4")
        #expect(app.plist["LSUIElement"] as? Bool == true)
        #expect((app.plist["Nested"] as? [String: Int]) == ["a": 1])
        #expect(app.plist["CFBundleIdentifier"] as? String == "app.test.Legilo.app")
        let share = try ArchiveFixture.read(archive.applications + "/Legilo.app/Contents/PlugIns/Share.appex/Contents/Info.plist")
        #expect(share.format == .xml)
    }

    @Test func bundleWithoutVersionGetsOne() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Legilo.app", version: nil)
        try archive.archivePlist(["CFBundleVersion": "1"])

        let lines = LineSink()
        let stamped = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: lines.append)

        #expect(stamped == [StampedBundle(relativePath: "Legilo.app", previous: nil)])
        #expect(try archive.version("Legilo.app") == "311")
        #expect(lines.all == ["stamp: Legilo.app CFBundleVersion (none) → 311"])
    }

    @Test func archiveInfoPlistUpdated() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Legilo.app", version: "1")
        try archive.archivePlist(["CFBundleVersion": "1", "CFBundleShortVersionString": "2.4", "ApplicationPath": "Applications/Legilo.app"])

        let stamped = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })

        #expect(stamped.map(\.relativePath) == ["Legilo.app"])
        let info = try ArchiveFixture.read(archive.root + "/Info.plist").plist
        let properties = try #require(info["ApplicationProperties"] as? [String: Any])
        #expect(properties["CFBundleVersion"] as? String == "311")
        #expect(properties["CFBundleShortVersionString"] as? String == "2.4")
        #expect(properties["ApplicationPath"] as? String == "Applications/Legilo.app")
        #expect(info["SchemeName"] as? String == "Legilo")
    }

    @Test func archiveInfoPlistWithoutApplicationPropertiesIsSkipped() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Legilo.app", version: "1")
        try archive.archivePlist(nil)

        let lines = LineSink()
        let stamped = try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: lines.append)

        #expect(stamped.count == 1)
        #expect(try ArchiveFixture.read(archive.root + "/Info.plist").plist["ApplicationProperties"] == nil)
        #expect(lines.all.contains { $0.contains("ApplicationProperties") })
    }

    @Test func missingAppThrows() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }

        #expect(throws: StampError.noApplication(archivePath: archive.root)) {
            try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })
        }
    }

    @Test func multipleAppsThrow() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("B.app", version: "1")
        try archive.bundle("A.app", version: "1")

        #expect(throws: StampError.multipleApplications(archivePath: archive.root, names: ["A.app", "B.app"])) {
            try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })
        }
        #expect(try archive.version("A.app") == "1")
    }

    @Test func unreadablePlistThrows() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Legilo.app", version: "1")
        let path = archive.applications + "/Legilo.app/Contents/Info.plist"
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: path))

        #expect(throws: StampError.unreadablePlist(path)) {
            try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })
        }
    }

    @Test func unlistableNestedDirectoryThrowsInsteadOfSkippingIt() throws {
        let archive = try ArchiveFixture()
        defer { archive.cleanUp() }
        try archive.bundle("Legilo.app", version: "1")
        try archive.bundle("Legilo.app/Contents/PlugIns/Share.appex", version: "1")
        let plugIns = archive.applications + "/Legilo.app/Contents/PlugIns"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: plugIns)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plugIns) }

        #expect(throws: (any Error).self) {
            try BuildNumberStamper().stamp(archivePath: archive.root, buildNumber: 311, log: { _ in })
        }
        #expect(try archive.version("Legilo.app") == "1")
    }
}
