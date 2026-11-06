import Foundation
import HangarCore
import Testing

@testable import HangarWorker

/// BatFi (build 259) archived in a VM with Hangar's development profile and failed its Developer ID export with "No
/// profiles for 'software.micropixels.BatFi' were found". These are the entitlements its app was signed with there.
@Suite struct DevelopmentProfileRemovalTests {
    private static let batFiEntitlements = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.application-identifier</key><string>YL78V8PY6H.software.micropixels.BatFi</string><key>com.apple.developer.team-identifier</key><string>YL78V8PY6H</string><key>com.apple.security.personal-information.location</key><true/></dict></plist>
        """
    private static let iCloudEntitlements = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.application-identifier</key><string>T.com.acme.app</string><key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array></dict></plist>
        """

    private struct Archive {
        let root = NSTemporaryDirectory() + "hangar-profile-removal-" + UUID().uuidString
        var path: String { root + "/BatFi Beta.xcarchive" }
        var scratch: String { root + "/tmp" }
        var app: String { path + "/Products/Applications/BatFi.app" }
        var updater: String { app + "/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" }

        init() throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(atPath: scratch, withIntermediateDirectories: true)
            for bundle in [app, updater] {
                try fileManager.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true)
            }
        }

        func hasProfile(_ bundle: String) -> Bool {
            FileManager.default.fileExists(atPath: bundle + "/Contents/embedded.provisionprofile")
        }

        func remove() { try? FileManager.default.removeItem(atPath: root) }
    }

    private func runner(entitlements: [String: String]) -> RecordingProcessRunner {
        let runner = RecordingProcessRunner()
        for (bundle, xml) in entitlements {
            runner.script({ $0.arguments.first == "-d" && $0.arguments.last == bundle }, lines: [xml])
        }
        return runner
    }

    @Test func aBundleWhoseEntitlementsNeedNoProfileLosesItAndIsReSignedAdHocWithItsOwnEntitlements() async throws {
        let archive = try Archive()
        defer { archive.remove() }
        FileManager.default.createFile(atPath: archive.app + "/Contents/embedded.provisionprofile", contents: Data())
        let runner = runner(entitlements: [archive.app: Self.batFiEntitlements])
        let lines = LineSink()

        let outcome = try await DevelopmentProfileRemoval(runner: runner).run(
            archivePath: archive.path, scratchDirectory: archive.scratch, environment: ["PATH": "/usr/bin"], log: lines.append)

        #expect(outcome == .removed(["Products/Applications/BatFi.app"]))
        #expect(!archive.hasProfile(archive.app))
        let sign = try #require(runner.commands.last)
        #expect(sign.executable == "/usr/bin/codesign")
        #expect(Array(sign.arguments.prefix(4)) == ["--force", "--sign", "-", "--preserve-metadata=identifier,flags,runtime"])
        #expect(sign.arguments.last == archive.app)
        let file = try #require(sign.arguments.firstIndex(of: "--entitlements").map { sign.arguments[$0 + 1] })
        let written = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: file)), format: nil)
                as? [String: Bool])
        #expect(written == ["com.apple.security.personal-information.location": true])
        #expect(lines.all.contains { $0.contains("removed Hangar's development profile from Products/Applications/BatFi.app") })
    }

    @Test func nestedBundlesAreReSignedBeforeTheBundleThatHoldsThem() async throws {
        let archive = try Archive()
        defer { archive.remove() }
        for bundle in [archive.app, archive.updater] {
            FileManager.default.createFile(atPath: bundle + "/Contents/embedded.provisionprofile", contents: Data())
        }
        // The updater has no entitlements at all: codesign prints nothing.
        let runner = runner(entitlements: [archive.app: Self.batFiEntitlements])

        let outcome = try await DevelopmentProfileRemoval(runner: runner).run(
            archivePath: archive.path, scratchDirectory: archive.scratch, environment: [:], log: { _ in })

        guard case .removed(let bundles) = outcome else { Issue.record("\(outcome)"); return }
        #expect(bundles.count == 2)
        let signed = runner.commands.filter { $0.arguments.first == "--force" }
        #expect(signed.map { $0.arguments.last } == [archive.updater, archive.app])
        #expect(!signed[0].arguments.contains("--entitlements"))
        #expect(!archive.hasProfile(archive.updater) && !archive.hasProfile(archive.app))
    }

    @Test func anEntitlementThatNeedsAProfileLeavesTheWholeArchiveAlone() async throws {
        let archive = try Archive()
        defer { archive.remove() }
        for bundle in [archive.app, archive.updater] {
            FileManager.default.createFile(atPath: bundle + "/Contents/embedded.provisionprofile", contents: Data())
        }
        let runner = runner(entitlements: [archive.app: Self.iCloudEntitlements])
        let lines = LineSink()

        let outcome = try await DevelopmentProfileRemoval(runner: runner).run(
            archivePath: archive.path, scratchDirectory: archive.scratch, environment: [:], log: lines.append)

        #expect(outcome == .profileNeeded(bundle: "Products/Applications/BatFi.app", entitlements: ["com.apple.developer.icloud-services"]))
        #expect(archive.hasProfile(archive.app) && archive.hasProfile(archive.updater))
        #expect(!runner.commands.contains { $0.arguments.first == "--force" })
        #expect(lines.all.contains { $0.contains("com.apple.developer.icloud-services") && $0.contains("Developer ID profile") })
    }

    @Test func anArchiveWithoutProfilesIsNotTouched() async throws {
        let archive = try Archive()
        defer { archive.remove() }
        let runner = RecordingProcessRunner()
        let outcome = try await DevelopmentProfileRemoval(runner: runner).run(
            archivePath: archive.path, scratchDirectory: archive.scratch, environment: [:], log: { _ in })
        #expect(outcome == .nothingToRemove)
        #expect(runner.commands.isEmpty)
    }

    @Test func aProfileThatIsASymbolicLinkIsNotABundlesProfile() throws {
        let archive = try Archive()
        defer { archive.remove() }
        try FileManager.default.createDirectory(atPath: archive.app + "/Contents", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: archive.app + "/Contents/embedded.provisionprofile", withDestinationPath: "/etc/hosts")
        #expect(DevelopmentProfileRemoval.bundlesWithProfiles(in: archive.path).isEmpty)
    }

    @Test func aFailedReSignFailsTheStep() async throws {
        let archive = try Archive()
        defer { archive.remove() }
        FileManager.default.createFile(atPath: archive.app + "/Contents/embedded.provisionprofile", contents: Data())
        let runner = runner(entitlements: [archive.app: Self.batFiEntitlements])
        runner.script({ $0.arguments.first == "--force" }, lines: ["errSecInternalComponent"], exitCode: 1)
        await #expect(throws: DevelopmentProfileRemoval.Failure.codesignFailed(bundle: "Products/Applications/BatFi.app", exitCode: 1)) {
            try await DevelopmentProfileRemoval(runner: runner).run(
                archivePath: archive.path, scratchDirectory: archive.scratch, environment: [:], log: { _ in })
        }
    }

    @Test func onlyTheSandboxAndRuntimeFamilyIsKnownToNeedNoProfile() {
        #expect(!DevelopmentProfileRemoval.needsProfile("com.apple.security.personal-information.location"))
        #expect(!DevelopmentProfileRemoval.needsProfile("com.apple.security.cs.allow-jit"))
        #expect(DevelopmentProfileRemoval.needsProfile("com.apple.security.application-groups"))
        #expect(DevelopmentProfileRemoval.needsProfile("com.apple.developer.associated-domains"))
        #expect(DevelopmentProfileRemoval.needsProfile("keychain-access-groups"))
    }
}
