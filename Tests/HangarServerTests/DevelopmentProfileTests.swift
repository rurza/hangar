import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

/// A fake App Store Connect for the provisioning endpoints; records every call.
final class ProvisioningASC: AppStoreConnectClient, Sendable {
    struct State {
        var bundleIDs: [ASCBundleIdentifier] = []
        var profiles: [ASCProfile] = []
        var devices: [String: [String]] = ["IOS": ["DEV1", "DEV2"], "MAC_OS": ["MAC1"]]
        var certificatesBySerial: [String: String] = [:]
        var refuseCreate: Set<String> = []
        var listsUsers = false
        var bundleIDsStatus: Int?
        var calls: [String] = []
        var created: [(name: String, type: ASCDevelopmentProfileType, bundle: String, certificates: [String], devices: [String])] = []
    }

    let state: Mutex<State>
    let apps: [ASCApp]

    init(_ state: State = State(), apps: [ASCApp] = [ASCApp(id: "42", name: "Legilo", bundleID: "com.acme.legilo")]) {
        self.state = Mutex(state)
        self.apps = apps
    }

    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { apps }
    func appIconURL(appID: String) async throws -> String? { nil }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "g", name: name, isInternal: isInternal)
    }
    func submitForBetaReview(buildID: String) async throws {}

    func bundleIdentifiers() async throws -> [ASCBundleIdentifier] {
        try state.withLock {
            $0.calls.append("bundleIds")
            if let status = $0.bundleIDsStatus { throw ASCError.http(status: status, body: "FORBIDDEN") }
            return $0.bundleIDs
        }
    }

    func developmentProfiles(type: ASCDevelopmentProfileType) async throws -> [ASCProfile] {
        state.withLock {
            $0.calls.append("profiles \(type.rawValue)")
            return $0.profiles.filter { $0.type == type }
        }
    }

    func enabledDeviceIDs(platform: String) async throws -> [String] {
        state.withLock {
            $0.calls.append("devices \(platform)")
            return $0.devices[platform] ?? []
        }
    }

    func certificateID(serialNumber: String) async throws -> String? {
        state.withLock {
            $0.calls.append("certificate \(serialNumber)")
            return $0.certificatesBySerial[serialNumber]
        }
    }

    func canListUsers() async throws -> Bool { state.withLock { $0.listsUsers } }

    func createDevelopmentProfile(
        name: String, type: ASCDevelopmentProfileType, bundleIDResourceID: String, certificateIDs: [String],
        deviceIDs: [String]
    ) async throws -> ASCProfile {
        try state.withLock {
            $0.calls.append("create \(bundleIDResourceID)")
            if $0.refuseCreate.contains(bundleIDResourceID) {
                throw ASCError.http(status: 409, body: "ENTITY_ERROR.RELATIONSHIP.INVALID: no devices")
            }
            $0.created.append((name, type, bundleIDResourceID, certificateIDs, deviceIDs))
            return ASCProfile(
                id: "P-\(bundleIDResourceID)", name: name, type: type, uuid: "UUID-\(bundleIDResourceID)",
                content: Data("profile \(bundleIDResourceID)".utf8), expirationDate: nil, bundleIDResourceID: bundleIDResourceID,
                certificateIDs: certificateIDs)
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct DevelopmentProfileServiceTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let app = App(
        id: UUID(), slug: "legilo", name: "Legilo", repoURL: "r", appStoreConnectAppID: "42", createdAt: now)
    static let identity = SigningIdentityInfo(
        name: "Apple Development: Created via API", teamID: "TEAM", serialNumber: "5A1B",
        expiresAt: now.addingTimeInterval(300 * 86_400), createdAt: now, origin: .created, ascCertificateID: "CERT1")
    static let team = ASCCredentials(keyID: "ADMIN1", issuerID: "issuer", privateKeyPEM: "PEM")
    static let developmentKey = AppStoreConnectKey(keyID: "DEV1", issuerID: "issuer", privateKey: "DEVPEM")

    static func bundles() -> [ASCBundleIdentifier] {
        [
            ASCBundleIdentifier(id: "B1", identifier: "com.acme.legilo", platform: "UNIVERSAL"),
            ASCBundleIdentifier(id: "B2", identifier: "com.acme.legilo.widget", platform: "IOS"),
            ASCBundleIdentifier(id: "B3", identifier: "com.acme.legilo.mac-helper", platform: "MAC_OS"),
            // Not the app's: a prefix that is not a dot boundary, and another app.
            ASCBundleIdentifier(id: "B4", identifier: "com.acme.legiloextra", platform: "IOS"),
            ASCBundleIdentifier(id: "B5", identifier: "com.acme.batfi", platform: "IOS"),
        ]
    }

    static func profile(_ bundle: String, certificates: [String] = ["CERT1"], expires: Date? = nil, type: ASCDevelopmentProfileType = .iOS) -> ASCProfile {
        ASCProfile(
            id: "E-\(bundle)", name: "iOS Team Provisioning Profile: \(bundle)", type: type, uuid: "EXISTING-\(bundle)",
            content: Data("existing \(bundle)".utf8), expirationDate: expires, bundleIDResourceID: bundle, certificateIDs: certificates)
    }

    func service(
        _ asc: ProvisioningASC, credentials: ASCCredentials? = team, developmentKey: AppStoreConnectKey? = nil,
        identity: SigningIdentityInfo? = identity
    ) -> DevelopmentProfileService {
        DevelopmentProfileService(
            credentials: { credentials }, developmentKey: { developmentKey }, identity: { identity }, factory: { _ in asc },
            now: { Self.now })
    }

    @Test func itUsesExistingProfilesWithHangarsCertificateAndCreatesOnlyTheMissingOnes() async {
        var state = ProvisioningASC.State()
        state.bundleIDs = Self.bundles()
        state.profiles = [
            Self.profile("B1"),
            // Without Hangar's certificate, or about to expire: not usable.
            Self.profile("B2", certificates: ["OTHER"]),
            Self.profile("B2", expires: Self.now.addingTimeInterval(3_600)),
            // Another app's.
            Self.profile("B5"),
        ]
        let asc = ProvisioningASC(state)
        let result = await service(asc, developmentKey: Self.developmentKey).provision(
            app: Self.app, platform: .iOS, useServerIdentity: true)

        #expect(result.missing.isEmpty)
        #expect(result.developmentKey == nil, "the development key comes only when a profile is missing")
        #expect(result.profiles.map(\.bundleID) == ["com.acme.legilo", "com.acme.legilo.widget"])
        #expect(result.profiles.map(\.uuid) == ["EXISTING-B1", "UUID-B2"])
        #expect(result.profiles.allSatisfy { !$0.isMac })
        let created = asc.state.withLock { $0.created }
        #expect(created.count == 1)
        #expect(created.first?.bundle == "B2")
        #expect(created.first?.type == .iOS)
        #expect(created.first?.certificates == ["CERT1"])
        #expect(created.first?.devices == ["DEV1", "DEV2"])
        #expect(created.first?.name == "Hangar Development com.acme.legilo.widget 2027-01-15 0800")
        #expect(result.notes == [
            "created development profile “Hangar Development com.acme.legilo.widget 2027-01-15 0800” (UUID-B2) for com.acme.legilo.widget with Hangar’s signing certificate",
        ])
        // Only development profiles of the archive's platform are read; nothing else is asked for.
        let calls = asc.state.withLock { $0.calls }
        #expect(calls == ["bundleIds", "profiles IOS_APP_DEVELOPMENT", "devices IOS", "create B2"])
    }

    @Test func aMacArchiveUsesMacProfilesAndMacDevices() async {
        var state = ProvisioningASC.State()
        state.bundleIDs = Self.bundles()
        let asc = ProvisioningASC(state)
        let result = await service(asc).provision(app: Self.app, platform: .macOS, useServerIdentity: true)
        #expect(result.profiles.map(\.bundleID) == ["com.acme.legilo", "com.acme.legilo.mac-helper"])
        #expect(result.profiles.allSatisfy { $0.isMac })
        #expect(asc.state.withLock { $0.created.map(\.type) } == [.macOS, .macOS])
        #expect(asc.state.withLock { $0.created.map(\.devices) } == [["MAC1"], ["MAC1"]])
    }

    @Test func aProfileThatCannotBeCreatedIsMissingAndBringsTheDevelopmentKey() async {
        var state = ProvisioningASC.State()
        state.bundleIDs = Self.bundles()
        state.refuseCreate = ["B2"]
        let asc = ProvisioningASC(state)
        let result = await service(asc, developmentKey: Self.developmentKey).provision(
            app: Self.app, platform: .iOS, useServerIdentity: true)
        #expect(result.profiles.map(\.bundleID) == ["com.acme.legilo"])
        #expect(result.missing.map(\.bundleID) == ["com.acme.legilo.widget"])
        #expect(result.missing.first?.reason.contains("HTTP 409") == true)
        #expect(result.developmentKey == Self.developmentKey)
    }

    @Test func whatTheServerCannotDoIsMissingWithItsReason() async {
        var state = ProvisioningASC.State()
        state.bundleIDs = Self.bundles()
        let cases: [(DevelopmentProfileService, String)] = [
            (service(ProvisioningASC(state), credentials: nil), "Hangar has no App Store Connect key"),
            (service(ProvisioningASC(state), credentials: ASCCredentials(keyID: "I", issuerID: nil, privateKeyPEM: "P")), "individual key"),
            (service(ProvisioningASC(state), identity: nil), "Settings › Signing"),
            (service(ProvisioningASC(state, apps: [])), "no app 42"),
            (service(ProvisioningASC(ProvisioningASC.State())), "not registered"),
        ]
        for (service, reason) in cases {
            let result = await service.provision(app: Self.app, platform: .iOS, useServerIdentity: true)
            #expect(result.profiles.isEmpty)
            #expect(result.missing.first?.reason.contains(reason) == true, "\(result.missing)")
            #expect(result.developmentKey == nil)
        }
    }

    @Test func anImportedIdentityIsFoundBySerialNumber() async {
        var state = ProvisioningASC.State()
        state.bundleIDs = [ASCBundleIdentifier(id: "B1", identifier: "com.acme.legilo", platform: "IOS")]
        state.certificatesBySerial = ["5A1B": "CERT9"]
        let asc = ProvisioningASC(state)
        var identity = Self.identity
        identity.ascCertificateID = nil
        identity.origin = .imported
        let result = await service(asc, identity: identity).provision(app: Self.app, platform: .iOS, useServerIdentity: true)
        #expect(result.missing.isEmpty)
        #expect(asc.state.withLock { $0.created.first?.certificates } == ["CERT9"])
    }

    @Test func aWorkersOwnIdentityGetsNoProfilesOnlyTheDevelopmentKey() async {
        var state = ProvisioningASC.State()
        state.bundleIDs = Self.bundles()
        let asc = ProvisioningASC(state)
        let result = await service(asc, developmentKey: Self.developmentKey).provision(
            app: Self.app, platform: .iOS, useServerIdentity: false)
        #expect(result.profiles.isEmpty)
        #expect(result.developmentKey == Self.developmentKey)
        #expect(asc.state.withLock { $0.calls }.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ProvisioningRouteTests {
    private func vmReport() -> MachineReport {
        var report = WorkerAPITests.report()
        report.vm = VMReport(slots: 1, configuredSlots: 1, freeSlots: 1, storageFreeGB: 200, networkFilter: true)
        return report
    }

    private func archiveJob(_ setup: WorkerAPITests.Setup) throws -> Job {
        try #require(setup.build.jobs.first { $0.action.kind == .archive })
    }

    @Test func aVMMacGetsProfilesForItsArchiveAndNeverTheServersKey() async throws {
        var state = ProvisioningASC.State()
        state.bundleIDs = [ASCBundleIdentifier(id: "B1", identifier: "com.acme.legilo", platform: "UNIVERSAL")]
        let asc = ProvisioningASC(state)
        let setup = try await WorkerAPITests.Setup(workflow: "ci", appStoreConnectFactory: { _ in asc })
        let server = setup.fixture.server
        try setup.fixture.storeASCKey(keyID: "ADMIN1", issuerID: "issuer", privateKey: "ADMIN-PEM")
        try server.signing.repository.save(
            JobSigningIdentity(p12: Data("p12".utf8), password: "pw"), info: DevelopmentProfileServiceTests.identity)
        try server.machines.updateReport(id: setup.machine.id, report: vmReport(), seenAt: WorkerAPITests.t0)
        let archive = try archiveJob(setup)
        let test = try #require(setup.build.jobs.first { $0.action.kind == .test })
        try await setup.fixture.test { client in
            try await client.execute(
                uri: "/api/v1/worker/jobs/\(archive.id.uuidString)/provisioning", method: .post, headers: setup.auth,
                body: try body(JobProvisioningRequest())
            ) { response throws in
                #expect(response.status == .ok)
                let result = try decode(JobProvisioning.self, response)
                #expect(result.profiles.map(\.bundleID) == ["com.acme.legilo"], "\(result.missing)")
                #expect(!String(buffer: response.body).contains("ADMIN-PEM"))
            }
            try await client.execute(
                uri: "/api/v1/worker/jobs/\(test.id.uuidString)/provisioning", method: .post, headers: setup.auth,
                body: try body(JobProvisioningRequest())
            ) { response throws in
                #expect(try decode(APIError.self, response).code == "not_a_vm_archive")
            }
        }
    }

    @Test func aHostMacAndAJobTokenAreRefused() async throws {
        let setup = try await WorkerAPITests.Setup(workflow: "ci")
        let server = setup.fixture.server
        let archive = try archiveJob(setup)
        try server.machines.updateReport(id: setup.machine.id, report: WorkerAPITests.report(), seenAt: WorkerAPITests.t0)
        try await setup.fixture.test { client in
            try await client.execute(
                uri: "/api/v1/worker/jobs/\(archive.id.uuidString)/provisioning", method: .post, headers: setup.auth,
                body: try body(JobProvisioningRequest())
            ) { response throws in
                #expect(try decode(APIError.self, response).code == "not_a_vm_archive")
            }
        }
        try server.machines.updateReport(id: setup.machine.id, report: vmReport(), seenAt: WorkerAPITests.t0)
        let token = try server.jobTokens.issue(jobID: archive.id, machineID: setup.machine.id, now: WorkerAPITests.t0)
        try await setup.fixture.test { client in
            try await client.execute(
                uri: "/api/v1/worker/jobs/\(archive.id.uuidString)/provisioning", method: .post,
                headers: WorkerAPITests.auth(token), body: try body(JobProvisioningRequest())
            ) { response throws in
                #expect(response.status == .forbidden)
            }
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct DevelopmentKeySettingsTests {
    static let pem = "-----BEGIN PRIVATE KEY-----\nDEV\n-----END PRIVATE KEY-----\n"

    @Test func aDeveloperTeamKeyIsStoredAndShown() async throws {
        let asc = ProvisioningASC()
        let fixture = try APIFixture(appStoreConnectFactory: { _ in asc })
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/settings/development-key", method: .post, headers: jsonHeaders,
                body: try body(SaveASCKeyRequest(keyID: "DEV123", issuerID: "issuer", privateKey: Self.pem))
            ) { response throws in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                #expect(try decode(SettingsStatus.self, response).developmentKey == ASCKeyStatus(keyID: "DEV123", issuerID: "issuer"))
                #expect(!String(buffer: response.body).contains("PRIVATE"))
            }
            try await client.execute(uri: "/api/v1/settings/development-key", method: .delete) { response throws in
                #expect(response.status == .noContent)
            }
        }
        #expect(try fixture.server.ascKeys.key(.development) == nil)
        #expect(APITokenPolicy.required(method: .post, path: "settings/development-key") == nil)
    }

    @Test func anAdminKeyAnIndividualKeyAndTheServersOwnKeyAreRefused() async throws {
        var state = ProvisioningASC.State()
        state.listsUsers = true
        let asc = ProvisioningASC(state)
        let fixture = try APIFixture(appStoreConnectFactory: { _ in asc })
        try fixture.storeASCKey(keyID: "ADMIN1", issuerID: "issuer", privateKey: Self.pem)
        let cases: [(SaveASCKeyRequest, String)] = [
            (SaveASCKeyRequest(keyID: "DEV123", issuerID: "issuer", privateKey: Self.pem), "development_key_too_powerful"),
            (SaveASCKeyRequest(keyID: "DEV123", issuerID: nil, privateKey: Self.pem), "team_key_required"),
            (SaveASCKeyRequest(keyID: "ADMIN1", issuerID: "issuer", privateKey: Self.pem), "development_key_is_main_key"),
        ]
        try await fixture.test { client in
            for (request, code) in cases {
                try await client.execute(
                    uri: "/api/v1/settings/development-key", method: .post, headers: jsonHeaders, body: try body(request)
                ) { response throws in
                    #expect(try decode(APIError.self, response).code == code)
                }
            }
        }
        #expect(try fixture.server.ascKeys.key(.development) == nil)
    }

    @Test func aKeyWithoutProvisioningAccessIsRefused() async throws {
        var state = ProvisioningASC.State()
        state.bundleIDsStatus = 403
        let asc = ProvisioningASC(state)
        let fixture = try APIFixture(appStoreConnectFactory: { _ in asc })
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/settings/development-key", method: .post, headers: jsonHeaders,
                body: try body(SaveASCKeyRequest(keyID: "DEV123", issuerID: "issuer", privateKey: Self.pem))
            ) { response throws in
                #expect(try decode(APIError.self, response).code == "asc_key_forbidden")
            }
        }
    }
}
