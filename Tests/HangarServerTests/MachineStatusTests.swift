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

    @Test func aVMMacThatIsNotReadyIsNotIdle() throws {
        func load(_ json: String) throws -> String {
            try Self.run(json, "(() => { const t = loadText(input); return `${t.headline} | ${t.detail}`; })()")
        }
        #expect(try load(#"{"running": 0, "max": 1, "paused": false, "vmNotReady": true}"#)
            == "Not Taking Builds | VM builds aren’t ready yet")
        #expect(try load(#"{"running": 0, "max": 1, "paused": true, "vmNotReady": true}"#)
            == "Builds Paused | VM builds aren’t ready yet")
    }

    @Test func theChecklistNamesTheCommandOnceAndKeepsEveryRow() throws {
        let json = #"""
            {"slots": 0, "checks": [
              {"id": "settings", "title": "VM settings", "ok": true, "required": true, "detail": "1 slot"},
              {"id": "networkFilter", "title": "Network filter", "ok": false, "required": true, "detail": "not installed: run `x`"},
              {"id": "image", "title": "Xcode image", "ok": false, "required": true, "detail": "none", "command": "sudo w vm setup"},
              {"id": "storage", "title": "Storage", "ok": false, "required": true, "detail": "ownership", "command": "sudo diskutil enableOwnership /Volumes/SSD"}
            ]}
            """#
        let result = try Self.run(json, """
            (() => { const c = vmChecklist(input);
              return [c.ready, c.command, c.rows.map((r) => `${r.id}:${r.ok}:${r.command}`).join(',')].join(' | '); })()
            """)
        #expect(result == "false | sudo w vm setup | settings:true:null,networkFilter:false:null,image:false:null,storage:false:sudo diskutil enableOwnership /Volumes/SSD")
    }

    @Test func anOlderWorkersProblemIsOneRow() throws {
        let result = try Self.run(#"{"slots": 0, "problem": "no image"}"#, """
            (() => { const c = vmChecklist(input); return `${c.rows.length} ${c.rows[0].detail} ${c.command}`; })()
            """)
        #expect(result == "1 no image null")
        #expect(try Self.run(#"{"slots": 1}"#, "String(vmChecklist(input).rows.length)") == "0")
    }

    @Test func anXcodeUpdateWithoutAnImageIsNoticed() throws {
        func drift(_ json: String) throws -> String {
            try Self.run(json, "(() => { const d = xcodeDrift(input); return d ? `${d.title} | ${d.command}` : 'none'; })()")
        }
        let image = #"{"name": "xcode-27.2", "xcode": "27.2", "xcodeBuild": "17C52"}"#
        let setup = #""setupCommand": "sudo /Users/adam/.local/bin/hangar-worker vm setup""#
        // The App Store replaced Xcode.app with 27.3.
        #expect(try drift(#"""
            {"xcodes": [{"version": "27.3", "build": "17D10", "path": "/Applications/Xcode.app"}],
             "vm": {"slots": 1, \#(setup), "images": [\#(image)]}}
            """#) == "Xcode 27.3 on this Mac has no VM image yet | sudo /Users/adam/.local/bin/hangar-worker vm setup")
        // Another Xcode is named.
        #expect(try drift(#"""
            {"xcodes": [{"version": "27.2", "build": "17C52", "path": "/Applications/Xcode.app"},
                        {"version": "27.4", "build": "17E1", "path": "/Applications/Xcode 27.4.app"}],
             "vm": {"slots": 1, \#(setup), "images": [\#(image)]}}
            """#) == "Xcode 27.4 on this Mac has no VM image yet | sudo /Users/adam/.local/bin/hangar-worker vm setup --xcode '/Applications/Xcode 27.4.app'")
        // In step: nothing. Without any image the checklist says it; on a host Mac it does not apply.
        #expect(try drift(#"""
            {"xcodes": [{"version": "27.2", "build": "17C52", "path": "/Applications/Xcode.app"}],
             "vm": {"slots": 1, "images": [\#(image)]}}
            """#) == "none")
        #expect(try drift(#"{"xcodes": [{"version": "27.2", "build": "17C52"}], "vm": {"slots": 0, "images": []}}"#) == "none")
        #expect(try drift(#"{"xcodes": [{"version": "27.2", "build": "17C52"}]}"#) == "none")
    }

    @Test func aVMMacSaysWhatItsArchivesSignWith() throws {
        func line(_ vm: String, _ signing: String) throws -> String {
            try Self.run(#"{"vm": \#(vm), "signing": \#(signing)}"#, """
                (() => { const l = vmSigningLine(input.vm, input.signing); return l ? `${l.ok} ${l.link} ${l.text}` : 'none'; })()
                """)
        }
        let identity = #"{"expiresAt": "2027-11-05T12:00:00Z"}"#
        #expect(try line(#"{"slots": 1}"#, #"{"state": "active", "identity": \#(identity)}"#)
            == "true false Signs with Hangar’s certificate (until Nov 5, 2027)")
        #expect(try line(#"{"slots": 1}"#, #"{"state": "none"}"#)
            == "false true Archives wait for a signing certificate. Create it once in")
        #expect(try line(#"{"slots": 1}"#, #"{"state": "expired", "identity": \#(identity)}"#)
            == "false true Hangar’s certificate expired on Nov 5, 2027, so archives wait. Renew it in")
        #expect(try line(#"{"slots": 1, "ownIdentity": true}"#, "null").hasPrefix("true false Signs with its own"))
        #expect(try line(#"{"slots": 1}"#, "null") == "none")
        #expect(try line("null", #"{"state": "none"}"#) == "none")
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

    @Test func onlyAMacThatBuildsAsItsOwnersUserWarnsAboutIt() throws {
        func warning(_ json: String) throws -> String {
            try Self.run(json, "(() => { const w = buildUserWarning(input); return w ? w.title : 'none'; })()")
        }
        #expect(try warning(#"{"runningUser": "adam"}"#) == "Builds run as adam")
        #expect(try warning(#"{"runningUser": "adam", "vm": {"slots": 1}}"#) == "none")
        #expect(try warning(#"{"runningUser": "hangar"}"#) == "none")
        #expect(try warning("{}") == "none")
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
