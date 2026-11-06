import Foundation
import HangarCore
import Testing
@testable import HangarWorker

/// `sudo hangar-worker vm setup`: which worker it sets up, and what it does on a new Mac and on one set up already.
@Suite struct VMSetupTests {
    static let hangar = VMSetupTarget(
        user: "hangar", home: "/Users/hangar", binary: "/Users/hangar/.local/bin/hangar-worker",
        config: "/Users/hangar/Library/Application Support/Hangar/worker/config.json", kind: .daemon)
    static let xcode = VMSetupXcode(path: "/Applications/Xcode.app", version: "27.2", build: "17C52")

    static func facts(
        target: VMSetupTarget = hangar, current: VMSettings? = nil, storage: String? = nil, images: [VMImageMetadata] = [],
        filterProblem: String? = "not installed", licenseAccepted: Bool = false
    ) -> VMSetupFacts {
        let settings = VMSettings(storage: storage ?? VMSettings.defaultStorage(home: target.home))
        return VMSetupFacts(
            target: target, settings: settings, currentSettings: current, xcode: xcode, licenseAccepted: licenseAccepted,
            filterProblem: filterProblem, images: images, storageExists: false)
    }

    static func base() -> VMImageMetadata {
        VMImageMetadata(name: "vanilla-26.6.2", source: "ghcr.io/x", createdAt: Date(timeIntervalSince1970: 0))
    }

    static func job(build: String = "17C52") -> VMImageMetadata {
        VMImageMetadata(
            name: "xcode-27.2", xcode: "27.2", xcodeBuild: build, source: "vanilla-26.6.2",
            createdAt: Date(timeIntervalSince1970: 1), buildUser: "builder")
    }

    @Test func aNewMacGetsEveryStepWithImagesMadeByTheWorkersUser() {
        let steps = VMSetup.plan(Self.facts())
        #expect(steps.filter { $0.done != nil }.map(\.title) == ["VM storage at /Users/hangar/.hangar/vm"])
        let actions = steps.flatMap(\.actions)
        #expect(actions.first == .run(["/usr/bin/pmset", "-a", "sleep", "0", "disksleep", "0"]))
        #expect(actions.contains(.run(["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "-license", "accept"])))
        #expect(actions.contains(.installNetworkFilter))
        let asHangar = ["/usr/bin/sudo", "-u", "hangar", "-H", "/Users/hangar/.local/bin/hangar-worker"]
        let config = Self.hangar.config
        #expect(actions.contains(.run(asHangar + [
            "vm", "enable", "--config", config, "--storage", "/Users/hangar/.hangar/vm", "--slots", "1", "--cpus", "4",
            "--memory-gb", "8",
        ])))
        #expect(actions.contains(.run(asHangar + ["vm", "image", "import", "--config", config])))
        #expect(actions.contains(.run(asHangar + [
            "vm", "image", "build", "--config", config, "--from", "vanilla-26.6.2", "--xcode", "/Applications/Xcode.app",
            "--skip-slots",
        ])))
        // Restarted right after VM builds are on (no more host builds) and at the end (slot states).
        #expect(actions.filter { $0 == .restartWorker }.count == 2)
        // Storage in the worker's home is the worker's own to create.
        #expect(!actions.contains { if case .run(let a) = $0 { a.first == "/bin/mkdir" } else { false } })
    }

    @Test func aMacSetUpAlreadyIsLeftAloneAndItsWorkerKeepsRunning() {
        let settings = VMSettings(storage: "/Users/hangar/.hangar/vm")
        let steps = VMSetup.plan(Self.facts(
            current: settings, images: [Self.base(), Self.job()], filterProblem: nil, licenseAccepted: true))
        #expect(steps.dropFirst().allSatisfy { $0.done != nil })
        #expect(!steps.flatMap(\.actions).contains(.restartWorker))
    }

    @Test func aNewXcodeBuildGetsANewImageFromTheNewestBase() {
        let settings = VMSettings(storage: "/Users/hangar/.hangar/vm")
        let steps = VMSetup.plan(Self.facts(
            current: settings, images: [Self.base(), Self.job(build: "17C40")], filterProblem: nil, licenseAccepted: true))
        let actions = steps.flatMap(\.actions)
        #expect(!actions.contains { if case .run(let a) = $0 { a.contains("import") } else { false } })
        #expect(actions.contains { if case .run(let a) = $0 { a.contains("build") && a.contains("vanilla-26.6.2") } else { false } })
        #expect(actions.last == .restartWorker)
    }

    @Test func anExternalSSDIsGivenToTheWorkersUserWithOwnershipOn() {
        var facts = Self.facts(storage: "/Volumes/SSD/hangar-vm")
        facts.volumeIgnoringOwnership = "/Volumes/SSD"
        let actions = VMSetup.plan(facts).flatMap(\.actions)
        #expect(actions.contains(.run(["/usr/sbin/diskutil", "enableOwnership", "/Volumes/SSD"])))
        #expect(actions.contains(.run(["/bin/mkdir", "-p", "/Volumes/SSD/hangar-vm"])))
        #expect(actions.contains(.run(["/usr/sbin/chown", "hangar:staff", "/Volumes/SSD/hangar-vm"])))
        #expect(actions.contains(.run(["/bin/chmod", "700", "/Volumes/SSD/hangar-vm"])))
    }

    @Test func anOwnerRunWorkersStepsRunAsTheOwnerAndRestartItsAgent() {
        let owner = VMSetupTarget(
            user: "adam", home: "/Users/adam", binary: "/Users/adam/.local/bin/hangar-worker",
            config: "/Users/adam/Library/Application Support/Hangar/worker/config.json", kind: .agent(uid: 501))
        #expect(owner.launchdTarget == "gui/501/app.hangar.worker")
        #expect(Self.hangar.launchdTarget == "system/app.hangar.worker")
        let actions = VMSetup.plan(Self.facts(target: owner)).flatMap(\.actions)
        #expect(actions.contains { if case .run(let a) = $0 { a.starts(with: ["/usr/bin/sudo", "-u", "adam", "-H"]) } else { false } })
        #expect(owner.commands.vmSetup == "sudo /Users/adam/.local/bin/hangar-worker vm setup")
    }

    @Test func theBudgetCountsWhatIsStillToMake() {
        let settings = VMSettings(storage: "/x", slots: 2, memoryGB: 8)
        #expect(VMSetup.requiredFreeGB(settings: settings, needsBaseImage: true, needsJobImage: true) == 26 + 6 + 16 + 25 + 40)
        #expect(VMSetup.requiredFreeGB(settings: settings, needsBaseImage: false, needsJobImage: false) == 16 + 25 + 40)
    }

    @Test func theDaemonWinsOverTheInvokersAgent() throws {
        let root = NSTemporaryDirectory() + "hangar-setup-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let agents = root + "/adam/Library/LaunchAgents"
        try FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        func write(_ plist: [String: Any], to path: String) throws {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: path))
        }
        try write(["ProgramArguments": ["/Users/adam/.local/bin/hangar-worker", "run"]], to: agents + "/app.hangar.worker.plist")
        let invoker = (name: "adam", uid: UInt32(501), home: root + "/adam")
        let homes = ["hangar": "/Users/hangar"]

        let agent = try #require(VMSetupTarget.detect(
            daemonPlist: root + "/none.plist", invoker: invoker, config: nil, home: { homes[$0] }))
        #expect(agent.kind == .agent(uid: 501) && agent.user == "adam")
        #expect(agent.binary == "/Users/adam/.local/bin/hangar-worker")
        #expect(agent.config == root + "/adam/Library/Application Support/Hangar/worker/config.json")

        try write(
            ["UserName": "hangar", "ProgramArguments": ["/Users/hangar/.local/bin/hangar-worker", "run", "--config", "/c.json"]],
            to: root + "/daemon.plist")
        let daemon = try #require(VMSetupTarget.detect(
            daemonPlist: root + "/daemon.plist", invoker: invoker, config: nil, home: { homes[$0] }))
        #expect(daemon == VMSetupTarget(
            user: "hangar", home: "/Users/hangar", binary: "/Users/hangar/.local/bin/hangar-worker", config: "/c.json",
            kind: .daemon))

        #expect(VMSetupTarget.detect(daemonPlist: root + "/none.plist", invoker: nil, config: nil, home: { homes[$0] }) == nil)
    }

    @Test func xcodesNamedByXcodesAreFound() throws {
        let root = NSTemporaryDirectory() + "hangar-xcode-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        func make(_ name: String, _ version: String) throws {
            let contents = root + "/" + name + "/Contents"
            try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version, "ProductBuildVersion": "B" + version],
                format: .xml, options: 0
            ).write(to: URL(fileURLWithPath: contents + "/version.plist"))
        }
        #expect(VMSetupXcode.find(in: root) == nil)
        try make("Xcode-26.4.0.app", "26.4")
        try make("Xcode-27.2.0.app", "27.2")
        #expect(VMSetupXcode.find(in: root)?.version == "27.2")
        try make("Xcode.app", "26.0")
        #expect(VMSetupXcode.find(in: root)?.path == root + "/Xcode.app")
    }
}
