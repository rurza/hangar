import Foundation
import HangarCore
import Testing

/// The web editor's `workflowToYAML` (Web/assets/yaml.js) and form model (Web/assets/workflow-model.js), run in
/// JXA: a `WorkflowFile` in its API JSON shape goes in, and the YAML that comes out must parse back to the same file.
@Suite(.timeLimit(.minutes(1))) struct WorkflowYAMLRoundTripTests {
    static let assets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/HangarServer/Web/assets")

    static let legilo = WorkflowFile(version: 1, workflows: [
        "testflight": Workflow(
            project: "Legilo.xcodeproj", xcode: "27.2", teamID: "YL78V8PY6H", tools: ["brew"],
            actions: [
                ArchiveAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect),
                ArchiveAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect),
            ],
            postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("Internal")])])]),
    ])

    static let workspaceInSubdirectory = WorkflowFile(version: 1, workflows: [
        "release": Workflow(
            workspace: "apps/Mac/Hangar.xcworkspace", xcode: "27",
            actions: [ArchiveAction(scheme: "Hangar", platform: .macOS, export: .developerID)]),
        "beta": Workflow(
            project: "Beta.xcodeproj", xcode: "26.4.1",
            actions: [ArchiveAction(scheme: "Beta", platform: .visionOS, export: .appStoreConnect)],
            postActions: [PostActionSpec(name: "testflight")]),
    ])

    static let testFlightSettings = WorkflowFile(version: 1, workflows: [
        "testflight": Workflow(
            project: "App.xcodeproj", xcode: "27.2",
            actions: [ArchiveAction(scheme: "App", platform: .iOS, export: .appStoreConnect)],
            postActions: [PostActionSpec(name: "testflight", settings: [
                "processing-timeout-minutes": .int(30),
                "wait-for-processing": .bool(false),
                "submit-for-external-review": .bool(true),
                "what-to-test": .bool(false),
                "groups": .array([.string("Internal"), .string("External Testers")]),
            ], requiresApproval: true)]),
    ])

    static let needsQuotes = WorkflowFile(version: 1, workflows: [
        "ci: nightly": Workflow(
            project: "My App/My App.xcodeproj", xcode: "27.10", teamID: "1ABCDE2345",
            tools: ["yes", "-x", "brew#2"],
            actions: [
                ArchiveAction(scheme: "App: Release", platform: .tvOS, export: .appStoreConnect),
                ArchiveAction(scheme: "2024 \"Edition\" \\ beta", platform: .watchOS, export: .appStoreConnect),
                ArchiveAction(scheme: "true", platform: .iOS, export: .appStoreConnect),
                ArchiveAction(scheme: "Line\u{85}Next\u{2028}Sep\u{2029}End", platform: .iOS, export: .appStoreConnect),
            ],
            postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("A, B"), .string("[x]")])])]),
    ])

    @Test(arguments: [
        ("legilo", legilo),
        ("workspace in a subdirectory", workspaceInSubdirectory),
        ("testflight settings", testFlightSettings),
        ("strings needing quotes", needsQuotes),
    ])
    func roundTrip(name: String, file: WorkflowFile) throws {
        let yaml = try Self.workflowToYAML(file)
        let parsed: WorkflowFile
        do {
            parsed = try WorkflowFileParser.parse(yaml)
        } catch {
            Issue.record("\(name): \(error)\n\(yaml)")
            return
        }
        #expect(parsed == file, "\(name):\n\(yaml)")
    }

    /// The same, but through the editor's form model first (load into the form, write back out), as a save does.
    @Test(arguments: [
        ("legilo", legilo),
        ("workspace in a subdirectory", workspaceInSubdirectory),
        ("testflight settings", testFlightSettings),
        ("strings needing quotes", needsQuotes),
    ])
    func roundTripThroughTheForm(name: String, file: WorkflowFile) throws {
        let yaml = try Self.runJXA(file, "workflowToYAML(fileFromModels(modelsFromFile(input)))")
        #expect(try WorkflowFileParser.parse(yaml) == file, "\(name):\n\(yaml)")
    }

    /// Post-actions run in order, so the form puts the TestFlight step back where it was. Only `testflight` is a
    /// known post-action yet, so the order is checked on the model's JSON rather than through the parser.
    @Test(arguments: [["slack", "testflight", "notify"], ["testflight", "slack"], ["slack", "notify"]])
    func formKeepsPostActionOrder(names: [String]) throws {
        let specs = names.map { name in
            let settings = name == "testflight" ? #"{"groups": ["Internal"]}"# : "{}"
            return #"{"name": "\#(name)", "settings": \#(settings), "requiresApproval": false}"#
        }
        let input = """
            {"version": 1, "workflows": {"w": {"project": "App.xcodeproj", "xcode": "27.2", "tools": [],
            "actions": [{"scheme": "App", "platform": "ios", "export": "app-store-connect"}],
            "postActions": [\(specs.joined(separator: ", "))]}}}
            """
        let output = try Self.runJXA(
            json: input,
            """
            (() => {
              const models = modelsFromFile(input);
              const order = (m) => fileFromModels(m).workflows.w.postActions.map((spec) => spec.name).join(',');
              const kept = order(models);
              models[0].testflightOn = !models[0].testflightOn;
              const toggled = order(models);
              models[0].testflightOn = !models[0].testflightOn;
              return [kept, toggled, order(models)].join('|');
            })()
            """)
        let withoutTestFlight = names.filter { $0 != "testflight" }
        let toggled = names.contains("testflight") ? withoutTestFlight : withoutTestFlight + ["testflight"]
        let expected = [names, toggled, names].map { $0.joined(separator: ",") }.joined(separator: "|")
        #expect(output == expected)
    }

    @Test func legiloMatchesTheDocumentedShape() throws {
        let yaml = try Self.workflowToYAML(Self.legilo)
        #expect(yaml == """
            version: 1
            workflows:
              testflight:
                project: Legilo.xcodeproj
                xcode: "27.2"
                team: "YL78V8PY6H"
                tools: [brew]
                actions:
                  - { scheme: Legilo, platform: macos, export: app-store-connect }
                  - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
                post-actions:
                  - testflight:
                      groups: [Internal]

            """)
    }

    @Test func defaultTestFlightSettingsAreLeftOut() throws {
        var file = Self.legilo
        file.workflows["testflight"]?.postActions = [PostActionSpec(name: "testflight", settings: [
            "wait-for-processing": .bool(true), "processing-timeout-minutes": .int(60), "groups": .array([]),
            "what-to-test": .bool(true), "submit-for-external-review": .bool(false),
        ])]
        let yaml = try Self.workflowToYAML(file)
        #expect(yaml.hasSuffix("    post-actions:\n      - testflight\n"), "\(yaml)")
    }

    /// Runs `workflowToYAML` from yaml.js in JXA with `file` encoded as the API encodes it.
    static func workflowToYAML(_ file: WorkflowFile) throws -> String {
        try runJXA(file, "workflowToYAML(input)")
    }

    static func runJXA(_ file: WorkflowFile, _ expression: String) throws -> String {
        try runJXA(json: String(decoding: try JSONEncoder().encode(file), as: UTF8.self), expression)
    }

    /// Loads `files` (yaml.js and workflow-model.js by default), each without its final `export { ... };` line, and returns the string
    /// `expression` evaluates to, with `input` bound to the parsed `json`.
    static func runJXA(json: String, files: [String] = ["yaml.js", "workflow-model.js"], _ expression: String) throws -> String {
        var source = ""
        for name in files {
            let text = try String(contentsOf: assets.appendingPathComponent(name), encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let exports = lines.filter { $0.hasPrefix("export ") }
            #expect(exports.count == 1 && exports[0].hasPrefix("export {"), "\(name) must have one final export { ... } line")
            source += lines.filter { !$0.hasPrefix("export ") }.joined(separator: "\n") + "\n"
        }
        source += "function run(argv) { const input = JSON.parse(argv[0]); return \(expression); }\n"

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("yaml-\(UUID().uuidString).js")
        try source.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path, json]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw JXAError(message: "osascript exited with \(process.terminationStatus): \(errorText)")
        }
        // osascript ends what it prints with a newline of its own.
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    struct JXAError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }
}
