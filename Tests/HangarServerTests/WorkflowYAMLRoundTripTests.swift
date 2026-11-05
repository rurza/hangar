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
                WorkflowAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect),
                WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect),
            ],
            postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("Internal")])])]),
    ])

    static let workspaceInSubdirectory = WorkflowFile(version: 1, workflows: [
        "release": Workflow(
            workspace: "apps/Mac/Hangar.xcworkspace", xcode: "27",
            actions: [WorkflowAction(scheme: "Hangar", platform: .macOS, export: .developerID)]),
        "beta": Workflow(
            project: "Beta.xcodeproj", xcode: "26.4.1",
            actions: [WorkflowAction(scheme: "Beta", platform: .visionOS, export: .appStoreConnect)],
            postActions: [PostActionSpec(name: "testflight")]),
    ])

    static let testFlightSettings = WorkflowFile(version: 1, workflows: [
        "testflight": Workflow(
            project: "App.xcodeproj", xcode: "27.2",
            actions: [WorkflowAction(scheme: "App", platform: .iOS, export: .appStoreConnect)],
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
                WorkflowAction(scheme: "App: Release", platform: .tvOS, export: .appStoreConnect),
                WorkflowAction(scheme: "2024 \"Edition\" \\ beta", platform: .watchOS, export: .appStoreConnect),
                WorkflowAction(scheme: "true", platform: .iOS, export: .appStoreConnect),
                WorkflowAction(scheme: "Line\u{85}Next\u{2028}Sep\u{2029}End", platform: .iOS, export: .appStoreConnect),
            ],
            postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("A, B"), .string("[x]")])])]),
    ])

    static let withTests = WorkflowFile(version: 1, workflows: [
        "ci": Workflow(
            project: "Legilo.xcodeproj", xcode: "27.2",
            actions: [
                .test(scheme: "LegiloTests", platform: .iOS, destination: "iPhone 17 Pro", testPlan: "Smoke"),
                .test(scheme: "Legilo", platform: .macOS),
                .test(scheme: "Vision: Tests", platform: .visionOS, testPlan: "true"),
                .test(scheme: "Pad", platform: .iOS, destination: "iPad Pro 11-inch (M4)"),
                .test(scheme: "Odd", platform: .iOS, destination: "Phone: #2, [beta]", testPlan: "Plan B"),
                WorkflowAction(scheme: "Legilo", platform: .macOS, export: .developerID),
            ],
            postActions: [PostActionSpec(name: "testflight")]),
    ])

    @Test(arguments: [
        ("legilo", legilo),
        ("workspace in a subdirectory", workspaceInSubdirectory),
        ("testflight settings", testFlightSettings),
        ("strings needing quotes", needsQuotes),
        ("test actions", withTests),
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
        ("test actions", withTests),
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

    @Test func testActionsMatchTheDocumentedShape() throws {
        let yaml = try Self.workflowToYAML(Self.withTests)
        #expect(yaml.contains("""
                actions:
                  - test: { scheme: LegiloTests, platform: ios, destination: "iPhone 17 Pro", test-plan: Smoke }
                  - test: { scheme: Legilo, platform: macos }
                  - test: { scheme: "Vision: Tests", platform: visionos, test-plan: "true" }
                  - test: { scheme: Pad, platform: ios, destination: "iPad Pro 11-inch (M4)" }
                  - test: { scheme: Odd, platform: ios, destination: "Phone: #2, [beta]", test-plan: "Plan B" }
                  - { scheme: Legilo, platform: macos, export: developer-id }

            """), "\(yaml)")
        // Destinations and plans are quoted as the Swift writer quotes them, so both write the same file.
        #expect(yaml == WorkflowYAMLWriter.yaml(Self.withTests))
    }

    /// Switching an action's kind in the form keeps only the fields of the new kind.
    @Test func formSwitchesKinds() throws {
        let output = try Self.runJXA(
            Self.withTests,
            """
            (() => {
              const models = modelsFromFile(input);
              const actions = models[0].actions;
              setActionKind(actions[0], 'archive');
              setActionKind(actions[5], 'test');
              actions[5].destination = '  ';
              const blank = blankAction('test');
              return JSON.stringify([fileFromModels(models).workflows.ci.actions[0], fileFromModels(models).workflows.ci.actions[5],
                blank, problems(models)]);
            })()
            """)
        #expect(output == #"[{"kind":"archive","scheme":"LegiloTests","platform":"ios","export":"app-store-connect"},"#
            + #"{"kind":"test","scheme":"Legilo","platform":"macos"},"#
            + #"{"kind":"test","scheme":"","platform":"ios","export":"app-store-connect","destination":"","testPlan":""},[]]"#)
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

    /// The wizard's answers become a workflow the server parses: tests first, then archives, TestFlight with the
    /// chosen groups. The summary line and the review sentence say the same.
    @Test func wizardBuildsTheWorkflowItDescribes() throws {
        let base = WorkflowFile(version: 1, workflows: [
            "release": Workflow(
                project: "Legilo.xcodeproj", xcode: "27.2", teamID: "YL78V8PY6H", tools: ["xcodegen"],
                actions: [WorkflowAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect)]),
        ])
        let output = try Self.runJXA(
            base,
            """
            (() => {
              const choices = [
                { scheme: 'Legilo', platform: 'macos', archive: true, test: false },
                { scheme: 'LegiloMobile', platform: 'ios', archive: true, test: true },
                { scheme: 'Helper', platform: 'macos', archive: false, test: false },
              ];
              const model = wizardModel({ name: 'Default', base: input.workflows.release, choices, distribution: 'testflight', groups: ['Internal'] });
              const file = fileFromModels([model]);
              return [workflowToYAML(file), workflowSummary(model), plainText(describeWorkflow(model)),
                JSON.stringify(allProblems(itemProblems(model, { betaGroups: ['Internal'] })))].join('\\n---\\n');
            })()
            """)
        let parts = output.components(separatedBy: "\n---\n")
        #expect(parts.count == 4)
        let parsed = try WorkflowFileParser.parse(parts[0])
        #expect(parsed == WorkflowFile(version: 1, workflows: [
            "Default": Workflow(
                project: "Legilo.xcodeproj", xcode: "27.2", teamID: "YL78V8PY6H", tools: ["xcodegen"],
                actions: [
                    .test(scheme: "LegiloMobile", platform: .iOS),
                    WorkflowAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect),
                    WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect),
                ],
                // Default settings are left out of the YAML.
                postActions: [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("Internal")])])]),
        ]))
        #expect(parts[1] == "Manual start · Archive macOS, iOS · Test iOS · TestFlight Internal")
        #expect(parts[2] == "Runs tests for LegiloMobile on the newest iPhone simulator, archives Legilo (macOS) and LegiloMobile (iOS), uploads both to TestFlight for Internal.")
        #expect(parts[3] == "[]")
    }

    /// Developer ID goes to Mac archives only and turns TestFlight off; tests alone need no distribution.
    @Test func wizardDistributionChoices() throws {
        let output = try Self.runJXA(
            Self.legilo,
            """
            (() => {
              const base = input.workflows.testflight;
              const mac = wizardModel({ name: 'Mac', base, distribution: 'developer-id',
                choices: [{ scheme: 'Legilo', platform: 'macos', archive: true, test: true }] });
              const keep = wizardModel({ name: 'Keep', base, distribution: 'keep',
                choices: [{ scheme: 'LegiloMobile', platform: 'ios', archive: true, test: false }] });
              const testsOnly = wizardModel({ name: 'CI', base, distribution: 'testflight',
                choices: [{ scheme: 'LegiloMobile', platform: 'ios', archive: false, test: true }] });
              return [mac, keep, testsOnly].map((model) => [JSON.stringify(toWorkflow(model).actions), String(model.testflightOn),
                plainText(describeWorkflow(model))].join(' | ')).join('\\n');
            })()
            """)
        #expect(output == """
            [{"kind":"test","scheme":"Legilo","platform":"macos"},{"kind":"archive","scheme":"Legilo","platform":"macos","export":"developer-id"}] | false | Runs tests for Legilo on this Mac, archives Legilo (macOS), signs it with Developer ID.
            [{"kind":"archive","scheme":"LegiloMobile","platform":"ios","export":"app-store-connect"}] | false | Archives LegiloMobile (iOS), keeps the builds on the build page.
            [{"kind":"test","scheme":"LegiloMobile","platform":"ios"}] | false | Runs tests for LegiloMobile on the newest iPhone simulator.
            """)
    }

    /// Each sidebar item gets its own problems, so the editor can badge the item that blocks a save.
    @Test func problemsAreFiledUnderTheirItem() throws {
        let output = try Self.runJXA(
            Self.withTests,
            """
            (() => {
              const model = modelsFromFile(input)[0];
              model.actions[1].scheme = ' ';
              model.testflight.groups = ['Internal', 'Typo'];
              model.testflight.timeout = 'soon';
              model.xcode = '';
              const found = itemProblems(model, { workflowNames: ['ci'], betaGroups: ['Internal'] });
              return JSON.stringify(found);
            })()
            """)
        #expect(output == #"{"general":["Another workflow is named “ci”."],"environment":["Choose an Xcode version."],"#
            + #""actions":[[],["Choose a scheme."],[],[],[],["TestFlight uploads every archive, and a Developer ID archive can’t go to TestFlight."]],"#
            + #""testflight":["The timeout is a whole number of minutes.","App Store Connect has no group named “Typo”."],"workflow":[]}"#)
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
