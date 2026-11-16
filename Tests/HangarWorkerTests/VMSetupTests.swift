import Foundation
import HangarCore
import Testing
@testable import HangarWorker

/// `sudo hangar-worker vm setup`: which worker it sets up, and what it does on a new Mac and on one set up already.
@Suite struct VMSetupTests {
    static let owner = VMSetupTarget(
        user: "adam", uid: 501, home: "/Users/adam", binary: "/Users/adam/.local/bin/hangar-worker",
        config: "/Users/adam/Library/Application Support/Hangar/worker/config.json")
    static let xcode = VMSetupXcode(path: "/Applications/Xcode.app", version: "27.2", build: "17C52")

    static func facts(
        target: VMSetupTarget = owner, current: VMSettings? = nil, storage: String? = nil, images: [VMImageMetadata] = [],
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
        #expect(steps.filter { $0.done != nil }.map(\.title) == ["VM storage at /Users/adam/.hangar/vm"])
        let actions = steps.flatMap(\.actions)
        #expect(actions.first == .run(["/usr/bin/pmset", "-a", "sleep", "0", "disksleep", "0"]))
        #expect(actions.contains(.run(["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "-license", "accept"])))
        #expect(actions.contains(.installNetworkFilter))
        let asOwner = ["/usr/bin/sudo", "-u", "adam", "-H", "/Users/adam/.local/bin/hangar-worker"]
        let config = Self.owner.config
        #expect(actions.contains(.run(asOwner + [
            "vm", "enable", "--config", config, "--storage", "/Users/adam/.hangar/vm", "--slots", "1", "--cpus", "4",
            "--memory-gb", "8", "--floor-gb", "20", "--job-reserve-gb", "15",
        ])))
        #expect(actions.contains(.run(asOwner + ["vm", "image", "import", "--config", config])))
        #expect(actions.contains(.run(asOwner + [
            "vm", "image", "build", "--config", config, "--from", "vanilla-26.6.2", "--xcode", "/Applications/Xcode.app",
            "--skip-slots",
        ])))
        // Restarted right after VM builds are on (no more host builds) and at the end (slot states).
        #expect(actions.filter { $0 == .restartWorker }.count == 2)
        // Storage in the worker's home is the worker's own to create.
        #expect(!actions.contains { if case .run(let a) = $0 { a.first == "/bin/mkdir" } else { false } })
    }

    @Test func aMacSetUpAlreadyIsLeftAloneAndItsWorkerKeepsRunning() {
        let settings = VMSettings(storage: "/Users/adam/.hangar/vm")
        let steps = VMSetup.plan(Self.facts(
            current: settings, images: [Self.base(), Self.job()], filterProblem: nil, licenseAccepted: true))
        #expect(steps.dropFirst().allSatisfy { $0.done != nil })
        #expect(!steps.flatMap(\.actions).contains(.restartWorker))
    }

    @Test func aNewXcodeBuildGetsANewImageFromTheNewestBase() {
        let settings = VMSettings(storage: "/Users/adam/.hangar/vm")
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
        #expect(actions.contains(.run(["/usr/sbin/chown", "adam:staff", "/Volumes/SSD/hangar-vm"])))
        #expect(actions.contains(.run(["/bin/chmod", "700", "/Volumes/SSD/hangar-vm"])))
    }

    @Test func onTheMacsOwnDiskTheVMsGetTheEncryptedVolume() {
        let steps = VMSetup.plan(Self.facts(storage: VMDataVolume.storage))
        let actions = steps.flatMap(\.actions)
        #expect(actions.contains(.setUpDataVolume))
        // Root makes the volume's storage directory, not `vm enable`; nothing in the home to delete.
        #expect(!actions.contains { if case .run(let a) = $0 { a.first == "/bin/mkdir" || a.first == "/bin/rm" } else { false } })
        #expect(actions.firstIndex(of: .setUpDataVolume)! < actions.firstIndex { if case .run(let a) = $0 { a.contains("enable") } else { false } }!)
    }

    @Test func aMacWithVMsInItsHomeMovesThemToTheVolumeAndDeletesTheOldStorage() {
        var facts = Self.facts(
            current: VMSettings(storage: "/Users/adam/.hangar/vm"), storage: VMDataVolume.storage,
            images: [], filterProblem: nil, licenseAccepted: true)
        facts.homeStorageExists = true
        let actions = VMSetup.plan(facts).flatMap(\.actions)
        let enable = actions.firstIndex { if case .run(let a) = $0 { a.contains("enable") && a.contains(VMDataVolume.storage) } else { false } }
        let remove = actions.firstIndex(of: .run(["/bin/rm", "-rf", "/Users/adam/.hangar/vm"]))
        #expect(actions.first { $0 == .setUpDataVolume } != nil)
        // Deleted only once the restarted worker uses the volume; the images are made again there.
        #expect(enable! < remove!)
        #expect(actions[enable! + 1] == .restartWorker)
        #expect(actions.contains { if case .run(let a) = $0 { a.contains("import") } else { false } })
        #expect(actions.last == .restartWorker)
    }

    @Test func aStorageTheOwnerChoseIsNeverDeleted() {
        var facts = Self.facts(current: VMSettings(storage: "/Volumes/SSD/vm"), storage: "/Volumes/SSD/vm")
        facts.homeStorageExists = true
        #expect(facts.storageToRemove == nil)
        #expect(!VMSetup.plan(facts).flatMap(\.actions).contains { if case .run(let a) = $0 { a.first == "/bin/rm" } else { false } })
    }

    @Test func aReadyVolumeIsLeftAlone() {
        var facts = Self.facts(
            current: VMSettings(storage: VMDataVolume.storage), storage: VMDataVolume.storage,
            images: [Self.base(), Self.job()], filterProblem: nil, licenseAccepted: true)
        facts.dataVolumeReady = true
        let steps = VMSetup.plan(facts)
        #expect(steps.dropFirst().allSatisfy { $0.done != nil })
    }

    @Test func theVolumeIsUnlockedAtBootWithTheRootOnlyPassphrase() {
        let script = VMDataVolume.unlockerScript(volumeUUID: "7F89609D-B71E-4D70-8FA3-2282CE502A65")
        #expect(script.contains(
            "/usr/sbin/diskutil apfs unlockVolume '7F89609D-B71E-4D70-8FA3-2282CE502A65' -user disk -stdinpassphrase < '/Library/Application Support/Hangar/vm-volume.key'"))
        #expect(script.contains("[ -d '/Volumes/HangarVM/vm' ] && exit 0"))
        #expect(VMDataVolume.daemonPlist.contains("<string>/Library/Application Support/Hangar/vm-volume.sh</string>"))
        #expect(VMSettings(storage: VMDataVolume.storage).problem == nil)
    }

    @Test func theVolumeIsFoundByNameInItsContainer() {
        let list: [String: Any] = ["Containers": [
            ["ContainerReference": "disk9", "Volumes": [["Name": "HangarVM", "APFSVolumeUUID": "OTHER"]]],
            ["ContainerReference": "disk3", "Volumes": [
                ["Name": "Data", "APFSVolumeUUID": "DATA"], ["Name": "HangarVM", "APFSVolumeUUID": "VM"],
            ]],
        ]]
        #expect(VMDataVolume.volumeUUID(inAPFSList: list, container: "disk3") == "VM")
        #expect(VMDataVolume.volumeUUID(inAPFSList: list, container: "disk5") == nil)
    }

    @Test func aLockedVolumeIsAStorageProblem() {
        // The storage on a volume that is not mounted: the check must not fall back to the system volume's "/".
        guard !FileManager.default.fileExists(atPath: VMDataVolume.storage) else { return }
        #expect(VMVolume.problem(at: VMDataVolume.storage) == .volumeLocked)
    }

    @Test func theOwnersAgentIsRestartedAndItsCommandsAreTypedByPath() {
        #expect(Self.owner.launchdTarget == "gui/501/app.hangar.worker")
        #expect(Self.owner.commands.vmSetup == "sudo /Users/adam/.local/bin/hangar-worker vm setup")
    }

    @Test func theBudgetCountsWhatIsStillToMake() {
        let settings = VMSettings(storage: "/x", slots: 2, memoryGB: 8)
        #expect(VMSetup.requiredFreeGB(settings: settings, needsBaseImage: true, needsJobImage: true) == 26 + 6 + 16 + 15 + 20)
        #expect(VMSetup.requiredFreeGB(settings: settings, needsBaseImage: false, needsJobImage: false) == 16 + 15 + 20)
    }

    @Test func theTargetIsTheInvokersLaunchAgent() throws {
        let root = NSTemporaryDirectory() + "hangar-setup-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let agents = root + "/adam/Library/LaunchAgents"
        try FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        let invoker = (name: "adam", uid: UInt32(501), home: root + "/adam")
        #expect(VMSetupTarget.detect(invoker: invoker, config: nil) == nil, "no agent, no worker")

        try PropertyListSerialization.data(
            fromPropertyList: ["ProgramArguments": ["/Users/adam/.local/bin/hangar-worker", "run"]], format: .xml, options: 0
        ).write(to: URL(fileURLWithPath: agents + "/app.hangar.worker.plist"))
        let agent = try #require(VMSetupTarget.detect(invoker: invoker, config: nil))
        #expect(agent == VMSetupTarget(
            user: "adam", uid: 501, home: root + "/adam", binary: "/Users/adam/.local/bin/hangar-worker",
            config: root + "/adam/Library/Application Support/Hangar/worker/config.json"))
        #expect(VMSetupTarget.detect(invoker: invoker, config: "/c.json")?.config == "/c.json")
        #expect(VMSetupTarget.detect(invoker: nil, config: nil) == nil)
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

    @Test func theNewestBaseImageIsBuiltFrom() {
        var newer = Self.base()
        newer.name = "vanilla-26.7"
        newer.createdAt = Date(timeIntervalSince1970: 5)
        #expect(VMSetupFacts.newestBaseImage(in: [Self.base(), newer, Self.job()])?.name == "vanilla-26.7")
        #expect(VMSetupFacts.newestBaseImage(in: [Self.job()]) == nil)
    }
}
