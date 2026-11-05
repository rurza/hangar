import Foundation
import Testing

/// What the Machines page and the Deploy sheet say about a paused or VM Mac (Web/assets/machine-status.js), run in
/// JXA.
@Suite(.timeLimit(.minutes(1))) struct MachineStatusTests {
    static func run(_ json: String, _ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: json, files: ["machine-status.js"], expression)
    }

    @Test func theServersMacIsNamedLikeItsLocalHostNameIgnoringCase() throws {
        #expect(try Self.run(#"{"name": "Adams-Mac-mini"}"#, "String(isServerMac(input, 'adams-mac-mini'))") == "true")
        #expect(try Self.run(#"{"name": "MacBook"}"#, "String(isServerMac(input, 'adams-mac-mini'))") == "false")
        #expect(try Self.run(#"{"name": "MacBook"}"#, "String(isServerMac(input, null))") == "false")
    }

    @Test func aPausedMacSaysSoWhereItWouldSayIdle() throws {
        func load(_ json: String) throws -> String {
            try Self.run(json, "(() => { const t = loadText(input); return `${t.headline} | ${t.detail}`; })()")
        }
        #expect(try load(#"{"running": 0, "max": 1, "paused": false}"#) == "Idle | 0 of 1 job running")
        #expect(try load(#"{"running": 0, "max": 1, "paused": true}"#)
            == "Builds Paused | No new builds until resumed")
        #expect(try load(#"{"running": 1, "max": 2, "paused": true}"#)
            == "null | 1 of 2 jobs running · no new builds after this")
        #expect(try load(#"{"running": 1, "max": 1, "paused": false}"#) == "null | 1 of 1 job running")
    }

    @Test func theButtonAndToastFollowTheState() throws {
        #expect(try Self.run("{}", "pauseButtonLabel(false)") == "Pause Builds")
        #expect(try Self.run("{}", "pauseButtonLabel(true)") == "Resume Builds")
        #expect(try Self.run(#"{"name": "mini", "paused": true, "report": {"runningJobIDs": []}}"#, "pauseToast(input)")
            == "Builds paused on mini")
        #expect(try Self.run(#"{"name": "mini", "paused": true, "report": {"runningJobIDs": ["a"]}}"#, "pauseToast(input)")
            == "Builds paused on mini. The build it is running finishes first.")
        #expect(try Self.run(#"{"name": "mini", "paused": false}"#, "pauseToast(input)") == "mini takes builds again")
    }

    @Test func theDeploySheetSaysPausedOnce() throws {
        func line(_ json: String) throws -> String {
            try Self.run(json, "(() => { const l = deployMachineLine(input); return `${l.dot} | ${l.detail}`; })()")
        }
        #expect(try line(#"{"online": true, "paused": true, "problems": [], "waits": ["builds paused"]}"#)
            == "paused | Builds paused · waits until you resume it")
        #expect(try line(#"{"online": true, "paused": true, "problems": [], "waits": ["builds paused", "busy"]}"#)
            == "paused | Builds paused · waits until you resume it; busy")
        #expect(try line(#"{"online": true, "paused": true, "problems": ["Xcode 27.2 not installed"], "waits": ["builds paused"]}"#)
            == "warning | Builds paused · Xcode 27.2 not installed")
        #expect(try line(#"{"online": false, "paused": true, "problems": ["offline"], "waits": []}"#)
            == "offline | Offline · builds paused")
        #expect(try line(#"{"online": true, "paused": false, "problems": [], "waits": ["busy"]}"#) == "online | Online · busy")
        #expect(try line(#"{"online": true, "problems": [], "waits": []}"#) == "online | Online · can build it")
    }

    @Test func aVMMacSaysItsSlotsImagesAndFilterOnOneShortLine() throws {
        func line(_ json: String) throws -> String {
            try Self.run(json, "(() => { const l = vmLine(input); return `${l.text} | ${l.problem}`; })()")
        }
        #expect(try line(#"""
            {"slots": 1, "configuredSlots": 1, "freeSlots": 1, "networkFilter": true,
             "images": [{"name": "xcode-27.2", "xcode": "27.2"}]}
            """#) == "VM builds · 1 slot (1 free) · Xcode 27.2 · network filter on | null")
        #expect(try line(#"""
            {"slots": 1, "configuredSlots": 2, "freeSlots": 0, "networkFilter": true,
             "images": [{"name": "a", "xcode": "26.4"}, {"name": "b", "xcode": "27.2"}, {"name": "c", "xcode": "27.2"},
                        {"name": "vanilla"}]}
            """#) == "VM builds · 1 of 2 slots (0 free) · Xcode 27.2, 26.4 · network filter on | null")
        // No slot ready: the worker's reason, or a fallback.
        #expect(try line(#"""
            {"slots": 0, "configuredSlots": 1, "freeSlots": 0, "networkFilter": false, "images": [],
             "problem": "the network filter is not installed: run hangar-worker isolate"}
            """#) == "VM builds · not ready · no Xcode image · network filter off | the network filter is not installed: run hangar-worker isolate")
        #expect(try line(#"{"slots": 0, "networkFilter": true, "images": []}"#)
            == "VM builds · not ready · no Xcode image · network filter on | No VM slot is ready.")
    }
}
