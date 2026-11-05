import Foundation
import GRDB
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

/// Runs `/usr/bin/openssl` for the test's own certificates; fails the test when it fails.
private func openssl(_ arguments: [String], input: String? = nil) async throws -> String {
    let outcome = try await LiveProcessRunner().run(
        ProcessCommand(
            executable: "/usr/bin/openssl", arguments: arguments, environment: ["PATH": "/usr/bin:/bin"],
            discardsStandardError: true, standardInput: input.map { SensitiveText($0 + "\n") }),
        onLine: { _ in })
    guard outcome.exitCode == 0 else { throw SigningTestError.openssl(arguments.first ?? "") }
    return outcome.output
}

private enum SigningTestError: Error { case openssl(String) }

private func scratch() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-signing-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// App Store Connect as far as certificates go, and nothing else: a local CA signs each CSR, so the server's real
/// key, CSR and `.p12` code runs end to end without the network. Records every creation and revocation.
final class FakeCertificateASC: AppStoreConnectClient, Sendable {
    struct State {
        var created: [String] = []
        var revoked: [String] = []
        var csrs: [String] = []
        /// The next creations answer with these HTTP statuses instead.
        var refusals: [Int] = []
    }

    let state = Mutex(State())
    let directory: String

    init() async throws {
        directory = try scratch()
        _ = try await openssl(["genrsa", "-out", directory + "/ca.key", "2048"])
        _ = try await openssl([
            "req", "-x509", "-new", "-key", directory + "/ca.key", "-subj", "/CN=Fake Apple CA", "-days", "800",
            "-out", directory + "/ca.pem",
        ])
    }

    var created: [String] { state.withLock { $0.created } }
    var revoked: [String] { state.withLock { $0.revoked } }

    func refuseNext(_ status: Int) { state.withLock { $0.refusals.append(status) } }

    func createCertificate(type: ASCCertificateType, csrPEM: String) async throws -> ASCCertificate {
        #expect(type == .development)
        if let status = state.withLock({ $0.refusals.isEmpty ? nil : $0.refusals.removeFirst() }) {
            throw ASCError.http(status: status, body: #"{"errors":[{"detail":"You already have a current Development certificate or a pending certificate request."}]}"#)
        }
        let number = state.withLock { state in
            state.csrs.append(csrPEM)
            return state.csrs.count
        }
        let csr = directory + "/request-\(number).pem"
        try Data(csrPEM.utf8).write(to: URL(fileURLWithPath: csr))
        let der = directory + "/certificate-\(number).der"
        _ = try await openssl([
            "x509", "-req", "-in", csr, "-CA", directory + "/ca.pem", "-CAkey", directory + "/ca.key",
            "-set_serial", "0x5A1B\(number)", "-days", "365", "-outform", "DER", "-out", der,
        ])
        let id = "CERT\(number)"
        state.withLock { $0.created.append(id) }
        return ASCCertificate(
            id: id, serialNumber: "5A1B\(number)", name: "Apple Development: Created via API", expirationDate: nil,
            content: try Data(contentsOf: URL(fileURLWithPath: der)))
    }

    func revokeCertificate(id: String) async throws { state.withLock { $0.revoked.append(id) } }

    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { [] }
    func appIconURL(appID: String) async throws -> String? { nil }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "g", name: name, isInternal: isInternal)
    }
    func submitForBetaReview(buildID: String) async throws {}
}

/// A `.p12` of a self-signed certificate with an Apple-like subject, as Keychain Access would export one.
private func makeP12(commonName: String = "Apple Development: Jane Doe (ABCDE12345)", days: Int = 300, password: String)
    async throws -> Data
{
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    _ = try await openssl(["genrsa", "-out", directory + "/key.pem", "2048"])
    _ = try await openssl([
        "req", "-x509", "-new", "-key", directory + "/key.pem", "-days", "\(days)", "-out", directory + "/cert.pem",
        "-subj", "/UID=ABC/CN=\(commonName)/OU=TEAM123456/O=Acme Ltd/C=US",
    ])
    _ = try await openssl(
        ["pkcs12", "-export", "-inkey", directory + "/key.pem", "-in", directory + "/cert.pem", "-passout", "stdin",
         "-out", directory + "/id.p12"],
        input: password)
    return try Data(contentsOf: URL(fileURLWithPath: directory + "/id.p12"))
}

@Suite(.timeLimit(.minutes(2))) struct SigningTests {
    struct Setup {
        let fixture: APIFixture
        let asc: FakeCertificateASC
        let now: ManualNow

        init(teamKey: Bool = true) async throws {
            let asc = try await FakeCertificateASC()
            let now = ManualNow(Date())
            self.asc = asc
            self.now = now
            fixture = try APIFixture(appStoreConnectFactory: { _ in asc }, now: { now() })
            var keys = [("HANGAR_ASC_KEY_ID", "KEY123"), ("HANGAR_ASC_KEY_PATH", "-----BEGIN PRIVATE KEY-----\n")]
            if teamKey { keys.append(("HANGAR_ASC_ISSUER_ID", "issuer-uuid")) }
            for (name, value) in keys {
                try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
            }
        }

        func create(_ client: some TestClientProtocol) async throws -> (HTTPResponse.Status, Data) {
            try await client.execute(uri: "/api/v1/signing/certificate", method: .post) { response throws in
                (response.status, Data(response.body.readableBytesView))
            }
        }

        func status(_ client: some TestClientProtocol) async throws -> SigningStatus {
            try await client.execute(uri: "/api/v1/signing", method: .get) { try decode(SigningStatus.self, $0) }
        }

        func importP12(_ client: some TestClientProtocol, _ p12: Data, password: String) async throws -> (HTTPResponse.Status, Data) {
            try await client.execute(
                uri: "/api/v1/signing/import", method: .post, headers: jsonHeaders,
                body: try body(ImportSigningIdentityRequest(p12: p12, password: password))
            ) { response in (response.status, Data(response.body.readableBytesView)) }
        }
    }

    private static func code(_ data: Data) -> String? { try? JSONCoding.decoder.decode(APIError.self, from: data).code }

    @Test func nothingUntilTheOwnerAsks() async throws {
        let setup = try await Setup()
        try await setup.fixture.test { client throws in
            let status = try await setup.status(client)
            #expect(status == SigningStatus(state: .none, identity: nil, canCreate: true))
        }
        #expect(setup.asc.created.isEmpty)
        #expect(setup.fixture.server.signing.jobProblem()?.contains("Settings › Signing") == true)
    }

    @Test func createsOneCertificateAndRefusesASecond() async throws {
        let setup = try await Setup()
        try await setup.fixture.test { client throws in
            let (status, data) = try await setup.create(client)
            #expect(status == .created)
            let response = try JSONCoding.decoder.decode(SigningCreateResponse.self, from: data)
            #expect(response.status.state == .active)
            #expect(response.status.identity?.origin == .created)
            #expect(response.status.identity?.ascCertificateID == "CERT1")
            #expect(response.status.identity?.serialNumber == "5A1B1")
            #expect(response.status.identity?.name == "Hangar")
            #expect(response.revokedCertificateID == nil)
            #expect(!response.status.canCreate)

            let (again, body) = try await setup.create(client)
            #expect(again == .conflict)
            #expect(Self.code(body) == "signing_identity_exists")
        }
        #expect(setup.asc.created == ["CERT1"])
        #expect(setup.asc.revoked.isEmpty)
        // The CSR carries a public key only.
        let csr = try #require(setup.asc.state.withLock { $0.csrs.first })
        #expect(csr.contains("BEGIN CERTIFICATE REQUEST") && !csr.contains("PRIVATE KEY"))
        // A VM archive can now get it, and it opens with its password.
        let identity = try #require(try setup.fixture.server.signing.jobIdentity())
        let file = try scratch() + "/check.p12"
        try identity.p12.write(to: URL(fileURLWithPath: file))
        let certificate = try await openssl(["pkcs12", "-in", file, "-clcerts", "-nokeys", "-passin", "stdin"], input: identity.password)
        #expect(certificate.contains("BEGIN CERTIFICATE"))
        #expect(setup.fixture.server.signing.jobProblem() == nil)
        // No work directory is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: setup.fixture.directory.path).filter { $0.hasPrefix(".signing-") }
        #expect(leftovers.isEmpty)
    }

    @Test func atMostOneCertificateADayEvenAfterRemoving() async throws {
        let setup = try await Setup()
        try await setup.fixture.test { client throws in
            #expect(try await setup.create(client).0 == .created)
            // Remove deletes the stored copy only: nothing is revoked.
            try await client.execute(uri: "/api/v1/signing", method: .delete) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(SigningStatus.self, response).state == .none)
            }
            #expect(setup.asc.revoked.isEmpty)
            let status = try await setup.status(client)
            #expect(!status.canCreate && status.nextCreationAt != nil)

            let (refused, body) = try await setup.create(client)
            #expect(refused == .tooManyRequests)
            #expect(Self.code(body) == "signing_rate_limited")

            setup.now.advance(by: 25 * 3600)
            #expect(try await setup.create(client).0 == .created)
        }
        #expect(setup.asc.created == ["CERT1", "CERT2"])
        // The removed one was not Hangar's to revoke any more: it is no longer stored.
        #expect(setup.asc.revoked.isEmpty)
    }

    @Test func renewalOnlyInTheLastThirtyDaysAndRevokesOnlyTheOldHangarCertificate() async throws {
        let setup = try await Setup()
        try await setup.fixture.test { client throws in
            #expect(try await setup.create(client).0 == .created)
            let expiry = try #require(try await setup.status(client).identity?.expiresAt)

            setup.now.advance(by: expiry.timeIntervalSince(setup.now()) - 31 * 86_400)
            #expect(try await setup.status(client).state == .active)
            #expect(try await setup.create(client).0 == .conflict)

            setup.now.advance(by: 2 * 86_400)
            let window = try await setup.status(client)
            #expect(window.state == .expiring && window.canCreate)
            let (status, data) = try await setup.create(client)
            #expect(status == .created)
            let response = try JSONCoding.decoder.decode(SigningCreateResponse.self, from: data)
            #expect(response.revokedCertificateID == "CERT1")
            #expect(response.status.identity?.ascCertificateID == "CERT2")
            #expect(response.status.identity?.serialNumber == "5A1B2")
        }
        #expect(setup.asc.created == ["CERT1", "CERT2"])
        #expect(setup.asc.revoked == ["CERT1"])
    }

    @Test func renewingAnImportedIdentityRevokesNothing() async throws {
        let setup = try await Setup()
        let p12 = try await makeP12(days: 20, password: "secret")
        try await setup.fixture.test { client throws in
            #expect(try await setup.importP12(client, p12, password: "secret").0 == .created)
            #expect(try await setup.status(client).state == .expiring)
            #expect(try await setup.create(client).0 == .created)
        }
        #expect(setup.asc.created == ["CERT1"])
        #expect(setup.asc.revoked.isEmpty)
    }

    @Test func aRefusalDoesNotCountAgainstTheDailyGuard() async throws {
        let setup = try await Setup()
        setup.asc.refuseNext(409)
        try await setup.fixture.test { client throws in
            let (status, body) = try await setup.create(client)
            #expect(status == .badGateway)
            #expect(Self.code(body) == "asc_refused")
            #expect(String(decoding: body, as: UTF8.self).contains("current Development certificate"))
            #expect(try await setup.create(client).0 == .created)
        }
        #expect(setup.asc.created == ["CERT1"])
    }

    @Test func anIndividualKeyCannotCreate() async throws {
        let setup = try await Setup(teamKey: false)
        try await setup.fixture.test { client throws in
            let (status, body) = try await setup.create(client)
            #expect(status == .conflict)
            #expect(Self.code(body) == "team_key_required")
        }
        #expect(setup.asc.created.isEmpty)
    }

    @Test func importAdoptsAnExistingIdentityWithoutCreatingOne() async throws {
        let setup = try await Setup()
        let p12 = try await makeP12(password: "owner's password")
        try await setup.fixture.test { client throws in
            let (wrong, wrongBody) = try await setup.importP12(client, p12, password: "nope")
            #expect(wrong == .badRequest)
            #expect(Self.code(wrongBody) == "invalid_identity")

            let distribution = try await makeP12(commonName: "Apple Distribution: Acme Ltd (TEAM123456)", password: "x")
            let (refused, refusedBody) = try await setup.importP12(client, distribution, password: "x")
            #expect(refused == .badRequest)
            #expect(String(decoding: refusedBody, as: UTF8.self).contains("not an Apple Development certificate"))

            let (status, data) = try await setup.importP12(client, p12, password: "owner's password")
            #expect(status == .created)
            let imported = try JSONCoding.decoder.decode(SigningStatus.self, from: data)
            #expect(imported.state == .active)
            #expect(imported.identity?.origin == .imported)
            #expect(imported.identity?.name == "Apple Development: Jane Doe (ABCDE12345)")
            #expect(imported.identity?.teamID == "TEAM123456")
            #expect(imported.identity?.ascCertificateID == nil)

            #expect(try await setup.importP12(client, p12, password: "owner's password").0 == .conflict)
            #expect(try await setup.create(client).0 == .conflict)
        }
        #expect(setup.asc.created.isEmpty)
        // Packed again under a password of Hangar's: the owner's is not kept.
        let identity = try #require(try setup.fixture.server.signing.jobIdentity())
        #expect(identity.password != "owner's password")
        #expect(identity.p12 != p12)
    }

    @Test func theIdentityIsSealedAtRestAndNeverShown() async throws {
        let setup = try await Setup()
        let collected = Mutex<[String]>([])
        try await setup.fixture.test { client throws in
            let created = String(decoding: try await setup.create(client).1, as: UTF8.self)
            collected.withLock { $0.append(created) }
            for uri in ["/api/v1/signing", "/api/v1/settings"] {
                try await client.execute(uri: uri, method: .get) { response throws in
                    collected.withLock { $0.append(String(buffer: response.body)) }
                }
            }
        }
        let bodies = collected.withLock { $0 }
        let identity = try #require(try setup.fixture.server.signing.jobIdentity())
        let secrets = [identity.password, identity.p12.base64EncodedString()]
        for body in bodies {
            for secret in secrets { #expect(!body.contains(secret)) }
        }
        let rows = try setup.fixture.server.database.read { db in try Row.fetchAll(db, sql: "SELECT * FROM signing_identity") }
        #expect(rows.count == 1)
        for row in rows {
            for (_, value) in row {
                let bytes: Data
                switch value.storage {
                case .blob(let data): bytes = data
                case .string(let text): bytes = Data(text.utf8)
                default: continue
                }
                #expect(bytes.range(of: identity.p12) == nil)
                for secret in secrets { #expect(bytes.range(of: Data(secret.utf8)) == nil) }
            }
        }
    }

    @Test func noAPITokenMayCreateRenewImportOrRemoveButReadSeesTheStatus() async throws {
        let setup = try await Setup()
        let read = try setup.fixture.server.apiTokens.create(name: "r", scope: .read).secret
        let configure = try setup.fixture.server.apiTokens.create(name: "c", scope: .configure).secret
        let p12 = try await makeP12(password: "x")
        try await setup.fixture.test { client throws in
            for secret in [read, configure] {
                let auth: HTTPFields = [.authorization: "Bearer \(secret)", .contentType: "application/json"]
                try await client.execute(uri: "/api/v1/signing/certificate", method: .post, headers: auth) { response throws in
                    #expect(response.status == .forbidden)
                    #expect(try decode(APIError.self, response).code == "token_scope")
                }
                try await client.execute(
                    uri: "/api/v1/signing/import", method: .post, headers: auth,
                    body: try body(ImportSigningIdentityRequest(p12: p12, password: "x"))
                ) { response throws in #expect(response.status == .forbidden) }
                try await client.execute(uri: "/api/v1/signing", method: .delete, headers: auth) { response throws in
                    #expect(response.status == .forbidden)
                }
            }
            try await client.execute(uri: "/api/v1/signing", method: .get, headers: [.authorization: "Bearer \(read)"]) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(SigningStatus.self, response).state == .none)
            }
        }
        #expect(setup.asc.created.isEmpty)
        #expect(APITokenPolicy.required(method: .post, path: "signing/certificate") == nil)
        #expect(APITokenPolicy.required(method: .post, path: "signing/import") == nil)
        #expect(APITokenPolicy.required(method: .delete, path: "signing") == nil)
        #expect(APITokenPolicy.required(method: .get, path: "signing") == .read)
    }
}

/// The identity rides along only in a VM machine's archive assignment.
@Suite(.timeLimit(.minutes(1))) struct SigningAssignmentTests {
    static let identity = JobSigningIdentity(p12: Data("fake-p12".utf8), password: "p12-password")

    private func seed(_ server: HangarServerApp) throws {
        try server.signing.repository.save(
            Self.identity,
            info: SigningIdentityInfo(
                name: "Apple Development: Hangar", teamID: "TEAM123456", serialNumber: "01",
                expiresAt: WorkerAPITests.t0.addingTimeInterval(365 * 86_400), createdAt: WorkerAPITests.t0, origin: .imported))
    }

    private func vmReport() -> MachineReport {
        var report = WorkerAPITests.report()
        report.vm = VMReport(slots: 1, configuredSlots: 1, freeSlots: 1, storageFreeGB: 200, networkFilter: true)
        return report
    }

    private func assignments(_ setup: WorkerAPITests.Setup) async throws -> [ActionKind: JobAssignment] {
        let seen = Mutex<[ActionKind: JobAssignment]>([:])
        let server = setup.fixture.server
        try await setup.fixture.test { client throws in
            for _ in 0..<2 {
                let assignment = try await client.execute(uri: "/api/v1/worker/jobs/next?wait=0", method: .get, headers: setup.auth) {
                    try decode(JobAssignment.self, $0)
                }
                seen.withLock { $0[assignment.job.action.kind] = assignment }
                try server.builds.setJobStatus(id: assignment.job.id, status: .cancelled, at: WorkerAPITests.t0)
            }
        }
        return seen.withLock { $0 }
    }

    @Test func onlyAVMArchiveGetsTheIdentity() async throws {
        let setup = try await WorkerAPITests.Setup(workflow: "ci")
        try seed(setup.fixture.server)
        try setup.fixture.server.machines.updateReport(id: setup.machine.id, report: vmReport(), seenAt: WorkerAPITests.t0)
        let seen = try await assignments(setup)
        #expect(seen[.archive]?.signingIdentity == Self.identity)
        #expect(seen[.test]?.signingIdentity == nil)
    }

    @Test func aHostWorkerNeverGetsIt() async throws {
        let setup = try await WorkerAPITests.Setup(workflow: "ci")
        try seed(setup.fixture.server)
        try setup.fixture.server.machines.updateReport(
            id: setup.machine.id, report: WorkerAPITests.report(), seenAt: WorkerAPITests.t0)
        let seen = try await assignments(setup)
        #expect(seen[.archive]?.signingIdentity == nil)
        #expect(seen[.test]?.signingIdentity == nil)
    }

    @Test func aVMArchiveWithoutAServerIdentityGetsNone() async throws {
        let setup = try await WorkerAPITests.Setup(workflow: "ci")
        try setup.fixture.server.machines.updateReport(id: setup.machine.id, report: vmReport(), seenAt: WorkerAPITests.t0)
        #expect(try await assignments(setup)[.archive]?.signingIdentity == nil)
    }
}

/// A VM archive waits only when the server has no usable identity and the worker none of its own.
struct SigningEligibilityTests {
    private func job(_ kind: ActionKind, problem: String?) -> QueuedJob {
        let workflow = Workflow(xcode: "27.2", actions: [])
        let action = kind == .archive
            ? WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect) : .test(scheme: "Legilo", platform: .iOS)
        return SchedulerLoop.queuedJob(
            id: UUID(), buildID: UUID(), createdAt: Date(), action: action, workflow: workflow, pinned: nil, teamKey: true,
            signingProblem: problem)
    }

    private func machine(vm: Bool, ownIdentity: Bool = false) -> MachineSnapshot {
        MachineSnapshot(
            id: UUID(), name: "studio", isOnline: true, freeSlots: 1, runningJobs: 0, xcodeVersions: ["27.2"], tools: [],
            freeDiskGB: 200, performanceCores: 10, onACPower: true, canSign: true,
            simulatorRuntimes: ["iOS 27.2"], headless: vm, vm: vm, vmOwnIdentity: ownIdentity)
    }

    @Test func eligibility() {
        let problem = "Hangar has no signing certificate for VM archives: create or import one in Settings › Signing"
        let archive = job(.archive, problem: problem)
        #expect(Scheduler.ineligibility(of: archive, on: machine(vm: true), minFreeDiskGB: 20) == [.noSigningIdentity(problem)])
        #expect(Ineligibility.noSigningIdentity(problem).description == problem)
        // The worker's own identity overrides the server's.
        #expect(Scheduler.ineligibility(of: archive, on: machine(vm: true, ownIdentity: true), minFreeDiskGB: 20).isEmpty)
        // A host worker signs with its own keychain, as before.
        #expect(Scheduler.ineligibility(of: archive, on: machine(vm: false), minFreeDiskGB: 20).isEmpty)
        // Tests do not sign; with an identity, archives pass.
        #expect(!Scheduler.ineligibility(of: job(.test, problem: problem), on: machine(vm: true), minFreeDiskGB: 20)
            .contains(.noSigningIdentity(problem)))
        #expect(job(.test, problem: problem).signingProblem == nil)
        #expect(Scheduler.ineligibility(of: job(.archive, problem: nil), on: machine(vm: true), minFreeDiskGB: 20).isEmpty)
    }
}
