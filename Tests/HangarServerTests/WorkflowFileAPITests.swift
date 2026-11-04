import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

private let legiloYAML = """
    version: 1
    workflows:
      testflight:
        project: Legilo.xcodeproj
        xcode: "27.2"
        team: YL78V8PY6H
        tools: [brew]
        actions:
          - { scheme: Legilo, platform: macos, export: app-store-connect }
          - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
        post-actions:
          - testflight:
              groups: [Internal]
    """

private let uri = "/api/v1/apps/legilo/workflow-file"

@Suite(.timeLimit(.minutes(1))) struct WorkflowFileAPITests {
    @Test func putValidStoresAndReturnsParsed() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            try await client.execute(uri: uri, method: .put, headers: jsonHeaders, body: try body(PutWorkflowFileRequest(yaml: legiloYAML))) { response throws in
                #expect(response.status == .ok)
                let stored = try decode(StoredWorkflowFile.self, response)
                #expect(stored.yaml == legiloYAML)
                #expect(stored.workflows.workflows["testflight"]?.actions.count == 2)
            }
            try await client.execute(uri: uri, method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(StoredWorkflowFile.self, response).yaml == legiloYAML)
            }
        }
    }

    @Test func putInvalidIsRefusedAndStoresNothing() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            let yaml = legiloYAML.replacingOccurrences(of: "platform: macos", with: "platform: android")
            try await client.execute(uri: uri, method: .put, headers: jsonHeaders, body: try body(PutWorkflowFileRequest(yaml: yaml))) { response throws in
                #expect(response.status == .badRequest)
                let error = try decode(APIError.self, response)
                #expect(error.code == "invalid_workflow_file")
                #expect(error.message.contains("android"))
            }
            try await client.execute(uri: uri, method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "workflow_file_not_found")
            }
        }
    }

    @Test func putTooLargeIsRefused() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            let yaml = legiloYAML + "\n# " + String(repeating: "x", count: 70_000)
            try await client.execute(uri: uri, method: .put, headers: jsonHeaders, body: try body(PutWorkflowFileRequest(yaml: yaml))) { response throws in
                #expect(response.status == .badRequest)
                let error = try decode(APIError.self, response)
                #expect(error.code == "invalid_workflow_file")
                #expect(error.message.contains("too large"))
            }
        }
    }

    @Test func deleteRemoves() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        try await fixture.test { client in
            try await client.execute(uri: uri, method: .put, headers: jsonHeaders, body: try body(PutWorkflowFileRequest(yaml: legiloYAML))) { _ in }
            try await client.execute(uri: uri, method: .delete) { #expect($0.status == .noContent) }
            try await client.execute(uri: uri, method: .get) { #expect($0.status == .notFound) }
            try await client.execute(uri: uri, method: .delete) { #expect($0.status == .noContent) }
        }
    }

    @Test func deletingAppRemovesItsWorkflowFile() async throws {
        let fixture = try APIFixture()
        let app = try fixture.createApp()
        try fixture.server.workflowFiles.set(appID: app.id, yaml: legiloYAML)
        try fixture.server.apps.delete(id: app.id)
        #expect(try fixture.server.workflowFiles.get(appID: app.id) == nil)
    }
}
