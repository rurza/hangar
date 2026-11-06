import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// Making a secret plain takes its value typed again (security review L4).
@Suite(.timeLimit(.minutes(1))) struct SecretToPlainTests {
    @Test func aSecretBecomesPlainOnlyWithItsValue() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        let uri = "/api/v1/apps/legilo/variables/SENTRY_AUTH_TOKEN"
        try await fixture.test { client in
            try await client.execute(
                uri: uri + "?workflow=Beta", method: .put, headers: jsonHeaders,
                body: try body(VariableInput(value: "s3cret", isSecret: true, workflows: ["Beta"]))
            ) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: uri + "?workflow=Beta", method: .patch, headers: jsonHeaders, body: try body(VariableUpdate(isSecret: false))
            ) { response in
                #expect(response.status == .badRequest)
                let error = try decode(APIError.self, response)
                #expect(error.code == "value_required")
            }
            // Other changes to a secret need no value; with the value, it may become plain.
            try await client.execute(
                uri: uri + "?workflow=Beta", method: .patch, headers: jsonHeaders, body: try body(VariableUpdate(asFile: true))
            ) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: uri + "?workflow=Beta", method: .patch, headers: jsonHeaders,
                body: try body(VariableUpdate(value: "s3cret", isSecret: false))
            ) { #expect($0.status == .noContent) }
        }
        let summary = try fixture.server.variables.summaries(scope: .app(try #require(try fixture.server.apps.find(slugOrID: "legilo")).id))
        #expect(summary.map(\.isSecret) == [false])
    }
}
