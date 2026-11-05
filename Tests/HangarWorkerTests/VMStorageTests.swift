import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite struct VMSettingsTests {
    @Test func aConfigurationWithoutAVMSectionBuildsOnTheHost() throws {
        let json = #"{"serverURL":"http://mini:8787","token":"t","dataDirectory":"/tmp/w"}"#
        let configuration = try JSONCoding.decoder.decode(WorkerConfiguration.self, from: Data(json.utf8))
        #expect(configuration.vm == nil)
        let encoded = String(decoding: try JSONCoding.encoder.encode(configuration), as: UTF8.self)
        #expect(!encoded.contains("\"vm\""))
    }

    @Test func aVMSectionNeedsOnlyItsStorage() throws {
        let json = #"{"serverURL":"http://mini:8787","token":"t","dataDirectory":"/tmp/w","vm":{"storage":"/Volumes/SSD/vm"}}"#
        let vm = try #require(try JSONCoding.decoder.decode(WorkerConfiguration.self, from: Data(json.utf8)).vm)
        #expect(vm == VMSettings(storage: "/Volumes/SSD/vm"))
        #expect(vm.slots == 1 && vm.cpus == 4 && vm.memoryGB == 8 && vm.jobTimeoutMinutes == 120)
        #expect(vm.floorGB == 40 && vm.jobReserveGB == 25)
        #expect(vm.problem == nil)
    }

    @Test func settingsThatCannotWorkAreNamed() {
        #expect(VMSettings(storage: "relative").problem?.contains("absolute") == true)
        #expect(VMSettings(storage: "/Volumes/My SSD/vm").problem?.contains("spaces") == true)
        #expect(VMSettings(storage: "/vm", slots: 3).problem?.contains("two macOS VMs") == true)
        #expect(VMSettings(storage: "/vm", memoryGB: 2).problem?.contains("memoryGB") == true)
        #expect(VMSettings(storage: "/vm", cpus: 1).problem?.contains("cpus") == true)
    }

    @Test func theDefaultStorageIsInTheWorkersHome() {
        #expect(VMSettings.defaultStorage(home: "/Users/hangar") == "/Users/hangar/.hangar/vm")
    }
}

@Suite struct VMStorageTests {
    @Test func theLayoutIsTartsPlusSlotsAndJobs() {
        let storage = VMStorage(root: "/Volumes/SSD/vm/")
        let image = storage.image("xcode-27.2")
        #expect(image.config == "/Volumes/SSD/vm/images/xcode-27.2/config.json")
        #expect(image.disk == "/Volumes/SSD/vm/images/xcode-27.2/disk.img")
        #expect(image.nvram == "/Volumes/SSD/vm/images/xcode-27.2/nvram.bin")
        #expect(image.slot(1).state == "/Volumes/SSD/vm/images/xcode-27.2/slots/1/state.vzstate")
        #expect(storage.partialImage("xcode-27.2").path == "/Volumes/SSD/vm/images/.partial-xcode-27.2")
        let id = UUID()
        #expect(storage.job(id).share == "/Volumes/SSD/vm/jobs/\(id.uuidString)/share")
    }

    @Test func imageNamesAreSafeDirectoryNames() {
        #expect(VMStorage.isValidImageName("xcode-27.2"))
        #expect(VMStorage.isValidImageName("vanilla_26.6.2"))
        #expect(!VMStorage.isValidImageName(".partial-x"))
        #expect(!VMStorage.isValidImageName("../etc"))
        #expect(!VMStorage.isValidImageName("a b"))
        #expect(!VMStorage.isValidImageName(""))
    }

    @Test func createMakesPrivateDirectoriesAndListsOnlyCompleteImages() throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let storage = fixture.storage
        for path in [storage.root, storage.keys, storage.images, storage.jobs] {
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
        try FileManager.default.createDirectory(atPath: storage.partialImage("next").path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: storage.image("empty").path, withIntermediateDirectories: true)
        #expect(storage.imageNames() == ["xcode-27.2"])
    }

    @Test func sweepDeletesEveryLeftoverJobClone() throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let job = fixture.storage.job(UUID())
        try FileManager.default.createDirectory(atPath: job.share, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: job.disk))
        #expect(fixture.storage.sweepJobs().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.storage.jobs).isEmpty)
    }

    @Test func sweepRemovesWhatAnInterruptedInstallerLeft() throws {
        let temporary = NSTemporaryDirectory() + "hangar-vz-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        try FileManager.default.createDirectory(
            atPath: temporary + "/com.apple.Virtualization.Installation.ABC", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: temporary + "/other", withIntermediateDirectories: true)
        #expect(VMStorage.sweepInstallerLeftovers(temporaryDirectory: temporary) == ["com.apple.Virtualization.Installation.ABC"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary) == ["other"])
    }

    @Test func clonesAreCopiesThatShareNothingVisible() throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let image = fixture.storage.image("xcode-27.2")
        let copy = fixture.root + "/clone.img"
        try VMVolume.clone(image.disk, to: copy)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: copy))
        #expect(FileManager.default.contents(atPath: image.disk) == Data("disk".utf8))
        #expect(throws: VMStorageError.self) { try VMVolume.clone(image.disk, to: copy) }
    }

    @Test func theTemporaryVolumeIsAPFSWithOwnership() {
        #expect(VMVolume.fileSystemType(of: NSTemporaryDirectory() + "does/not/exist/yet") == "apfs")
        #expect(VMVolume.ownershipEnabled(at: NSTemporaryDirectory()))
        #expect(VMVolume.problem(at: NSTemporaryDirectory()) == nil)
        #expect(VMVolume.freeGB(at: NSTemporaryDirectory()) > 0)
    }

    @Test func storageProblemsSayWhatToDo() {
        #expect(VMStorageError.notAPFS(path: "/Volumes/X", type: "exfat").description.contains("APFS"))
        #expect(VMStorageError.ownershipIgnored(path: "/Volumes/X").description.contains("diskutil enableOwnership"))
        #expect(VMStorageError.cloneFailed(from: "a", to: "b", errno: EXDEV).description.contains("different volumes"))
    }
}

@Suite struct VMBundleFilesTests {
    /// The config of ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2, as pulled.
    static let cirrusConfig = #"{"os":"darwin","ecid":"YnBsaXN0MDDRAQJURUNJRBQAAAAAAAAAAPV1i7BDhWpaCAsQAAAAAAAAAQEAAAAAAAAAAwAAAAAAAAAAAAAAAAAAACE=","diskFormat":"raw","version":1,"macAddress":"72:76:f4:5e:d8:14","cpuCountMin":2,"cpuCount":4,"memorySizeMin":4294967296,"hardwareModel":"YnBsaXN0MDDTAQIDBAQFXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxACowYHBxANEAAIDys9UlRYWgAAAAAAAAEBAAAAAAAAAAgAAAAAAAAAAAAAAAAAAABc","arch":"arm64","memorySize":8589934592,"display":{"width":1024,"height":768}}"#

    @Test func tartsConfigReadsAndKeepsItsFields() throws {
        let config = try JSONCoding.decoder.decode(TartConfig.self, from: Data(Self.cirrusConfig.utf8))
        #expect(config.cpuCount == 4 && config.cpuCountMin == 2)
        #expect(config.memorySize == 8 << 30 && config.memorySizeMin == 4 << 30)
        #expect(config.hardwareModelData?.isEmpty == false)
        #expect(config.machineIdentifierData?.isEmpty == false)
        let again = try JSONCoding.decoder.decode(TartConfig.self, from: try JSONCoding.encoder.encode(config))
        #expect(again == config)
    }

    @Test func aSlotStateIsStaleWhenItsImageItsSizeOrTheHostChanged() {
        let image = VMImageMetadata(name: "x", source: "s", createdAt: Date(), buildUser: "builder")
        let slot = VMSlotMetadata(
            macAddress: "02:68:67:aa:00:00", machineIdentifier: "", cpus: 4, memoryGB: 8, imageID: image.id,
            hostBuild: "25G83", savedAt: Date())
        let settings = VMSettings(storage: "/vm")
        #expect(slot.staleness(settings: settings, image: image, hostBuild: "25G83") == nil)
        #expect(slot.staleness(settings: settings, image: image, hostBuild: "25H12") == "macOS on this Mac was updated")
        #expect(slot.staleness(settings: VMSettings(storage: "/vm", memoryGB: 14), image: image, hostBuild: "25G83") != nil)
        var rebuilt = image
        rebuilt.id = UUID()
        #expect(slot.staleness(settings: settings, image: rebuilt, hostBuild: "25G83") == "the image was rebuilt")
    }

    @Test func slotMACsAreLocallyAdministeredAndPerSlot() {
        let zero = VMMACAddress.forSlot(0, machine: "rurzobuk-max")
        let one = VMMACAddress.forSlot(1, machine: "rurzobuk-max")
        #expect(zero.hasPrefix("02:68:67:") && zero.hasSuffix(":00:00"))
        #expect(one.hasSuffix(":01:00"))
        #expect(zero != one)
        #expect(VMMACAddress.forSlot(0, machine: "rurzobuk-max") == zero)
        #expect(VMMACAddress.leaseForm("02:68:67:0A:00:00") == "2:68:67:a:0:0")
    }

    @Test func aVanillaImportIsNotAJobImage() {
        #expect(!VMImageMetadata(name: "v", source: "s", createdAt: Date()).isJobImage)
        #expect(VMImageMetadata(name: "x", xcode: "27.2", source: "s", createdAt: Date(), buildUser: "builder").isJobImage)
    }
}

@Suite struct DHCPLeasesTests {
    static let leases = """
        {
        \tname=admins-Virtual-Machine
        \tip_address=192.168.64.2
        \thw_address=1,2:68:67:a:0:0
        \tidentifier=1,2:68:67:a:0:0
        \tlease=0x690b9abc
        }
        {
        \tname=admins-Virtual-Machine
        \tip_address=192.168.64.7
        \thw_address=1,2:68:67:a:0:0
        \tidentifier=1,2:68:67:a:0:0
        \tlease=0x690b9fff
        }
        {
        \tname=other
        \tip_address=192.168.64.3
        \thw_address=1,2:68:67:a:1:0
        \tlease=0x690b9abc
        }
        """

    @Test func theLatestLeaseOfTheMACWins() {
        #expect(DHCPLeases.address(for: "02:68:67:0a:00:00", in: Self.leases) == "192.168.64.7")
        #expect(DHCPLeases.address(for: "02:68:67:0a:01:00", in: Self.leases) == "192.168.64.3")
        #expect(DHCPLeases.address(for: "02:68:67:0a:02:00", in: Self.leases) == nil)
    }

    @Test func aMissingFileIsNoAddress() {
        #expect(DHCPLeases.address(for: "02:00:00:00:00:01", leasesFile: "/nonexistent/leases") == nil)
    }
}
