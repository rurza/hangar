import Foundation
import Testing

/// The variables editors' pure rules (Web/assets/variable-model.js), run in JXA.
@Suite(.timeLimit(.minutes(1))) struct VariableModelTests {
    static func run(_ expression: String) throws -> String { try run("null", expression) }

    static func run(_ json: String, _ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: json, files: ["variable-model.js"], expression)
    }

    @Test func namesThatLookSecret() throws {
        let secret = ["SENTRY_AUTH_TOKEN", "API_KEY", "APIKEY", "DB_PASSWORD", "AWS_SECRET_ACCESS_KEY", "GH_PAT_TOKEN",
                      "MATCH_PASSWORD", "private_key", "SIGNING_CREDENTIALS", "ACCESSTOKEN", "NPM_PWD"]
        let plain = ["SENTRY_DSN", "SENTRY_ORG", "API_BASE_URL", "MONKEY", "KEYBOARD_LAYOUT", "TOKENIZER", "BUILD_FLAVOR", ""]
        let list = (secret + plain).map { "'\($0)'" }.joined(separator: ",")
        let output = try Self.run("[\(list)].map((n) => looksSecret(n) ? 1 : 0).join('')")
        #expect(output == String(repeating: "1", count: secret.count) + String(repeating: "0", count: plain.count))
    }

    @Test func restrictionsReadAsText() throws {
        #expect(try Self.run("[workflowsText([]), workflowsText(['Beta']), workflowsText(['Beta', 'Nightly', 'Release'])].join('|')")
            == "All workflows|Beta|Beta, Nightly and Release")
        #expect(try Self.run("normalizedWorkflows([' Release', 'Beta', 'Release', '']).join(',')") == "Beta,Release")
    }

    @Test func unknownWorkflowNamesAreFlaggedOnlyWhenTheNamesAreKnown() throws {
        #expect(try Self.run("unknownWorkflowsText(['Beta'], ['beta', 'Release'])")
            == "“Beta” is not a workflow of this app any more: no build gets this value.")
        #expect(try Self.run("unknownWorkflowsText(['Beta', 'Old', 'Gone'], ['Beta'], { group: true })")
            == "“Old” and “Gone” are not workflows of this app any more.")
        #expect(try Self.run("unknownWorkflowsText(['Old'], ['Beta'], { group: true })")
            == "“Old” is not a workflow of this app any more: no build gets these variables.")
        #expect(try Self.run("String(unknownWorkflowsText(['Beta'], null))") == "null")
        #expect(try Self.run("String(unknownWorkflowsText([], ['Beta']))") == "null")
    }

    @Test func overlapFollowsTheServersRule() throws {
        let variables = #"""
            [{"name": "DSN", "workflows": ["Beta"]}, {"name": "DSN", "workflows": []}, {"name": "OTHER", "workflows": ["Release"]}]
            """#
        // A restricted one overlapping another restricted one; one for all workflows twice; neither with the other.
        #expect(try Self.run(variables, "String(overlapping(input, 'DSN', ['Beta', 'Release'])?.workflows)") == "Beta")
        #expect(try Self.run(variables, "String(overlapping(input, 'DSN', [])?.workflows)") == "")
        #expect(try Self.run(variables, "String(overlapping(input, 'DSN', ['Release']))") == "null")
        // The one being edited never clashes with itself.
        #expect(try Self.run(variables, "String(overlapping(input, 'DSN', ['Beta'], input[0]))") == "null")
    }
}
