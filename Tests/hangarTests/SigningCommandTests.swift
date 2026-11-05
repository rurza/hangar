import Foundation
import HangarClient
import HangarCore
import Testing

@testable import hangar

private typealias H = CLIHarness

@Suite struct SigningCommandTests {
    static let status = SigningStatus(
        state: .active,
        identity: SigningIdentityInfo(
            name: "Apple Development: Created via API (TEAM123456)", teamID: "TEAM123456", serialNumber: "5A1B",
            expiresAt: H.t0.addingTimeInterval(365 * 86_400), createdAt: H.t0, origin: .created, ascCertificateID: "CERT1"),
        canCreate: false, createBlockedReason: "valid")

    @Test func statusShowsTheCertificate() async throws {
        let result = await H(responses: [try H.json(Self.status)]).run(["signing", "status"])
        #expect(result.exitCode == 0)
        #expect(result.out.contains("Apple Development: Created via API (TEAM123456)"))
        #expect(result.out.contains("created by Hangar") && result.out.contains("CERT1"))
        #expect(result.requests.first?.url?.path == "/api/v1/signing")
    }

    @Test func createNeedsYesAndThenPostsOnce() async throws {
        let refused = await H().run(["signing", "create"])
        #expect(refused.exitCode == 1)
        #expect(refused.requests.isEmpty)
        #expect(refused.err.contains("one Apple Development certificate"))

        let harness = H(responses: [try H.json(SigningCreateResponse(status: Self.status), status: 201)])
        let result = await harness.run(["signing", "create", "--yes"])
        #expect(result.exitCode == 0)
        #expect(result.requests.map(\.httpMethod) == ["POST"])
        #expect(result.requests.first?.url?.path == "/api/v1/signing/certificate")
    }

    @Test func importSendsTheP12AndThePasswordFromTheEnvironment() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID().uuidString).p12")
        try Data("p12-bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = H(responses: [try H.json(Self.status, status: 201)], environment: ["HANGAR_P12_PASSWORD": "pw"])
        let result = await harness.run(["signing", "import", file.path])
        #expect(result.exitCode == 0)
        #expect(try result.bodies(ImportSigningIdentityRequest.self) == [ImportSigningIdentityRequest(p12: Data("p12-bytes".utf8), password: "pw")])
        #expect(!result.out.contains("pw\n"))
    }

    @Test func removeNeedsYesAndSaysNothingIsRevoked() async throws {
        #expect(await H().run(["signing", "remove"]).requests.isEmpty)
        let none = SigningStatus(state: .none, identity: nil, canCreate: true)
        let result = await H(responses: [try H.json(none)]).run(["signing", "remove", "--yes"])
        #expect(result.exitCode == 0)
        #expect(result.requests.first?.httpMethod == "DELETE")
        #expect(result.out.contains("not revoked"))
    }
}
