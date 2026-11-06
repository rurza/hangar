import Foundation
import HangarCore
import Testing

@testable import HangarServer

/// How the install script sets up a Mac: for the user running it, building in VMs or locally. It runs for real
/// against stubs of curl, sudo, launchctl, id and uname (first on PATH, so neither sudo nor launchctl ever runs), with
/// HOME and TMPDIR in a temporary directory, under `script` so it has a terminal; what the test types goes to that
/// terminal. The downloaded "hangar-worker" is a stub that logs its arguments.
@Suite(.timeLimit(.minutes(1))) struct InstallScriptModesTests {
    struct Sandbox {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var log: URL { root.appendingPathComponent("log") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("install-sandbox-\(UUID().uuidString)")
            let stubs = root.appendingPathComponent("stubs")
            try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root.appendingPathComponent("log").path, contents: nil)
            let worker = #"""
                #!/bin/sh
                echo "worker $*${HANGAR_WORKER_TOKEN:+ token=set}" >>"$STUB_LOG"
                case $1 in
                    --help) exit 0 ;;
                    check) [ "${STUB_CHECK:-3}" = 0 ] && echo mini-2; exit "${STUB_CHECK:-3}" ;;
                    doctor) echo '{"xcodes":[],"canSignWithoutPrompt":false}' ;;
                esac
                exit 0
                """#
            try Data(worker.utf8).write(to: root.appendingPathComponent("fake-worker"))
            let stubsText: [String: String] = [
                "curl": #"""
                    #!/bin/sh
                    echo "curl $*" >>"$STUB_LOG"
                    out=''
                    while [ $# -gt 0 ]; do
                        case $1 in -o) out=$2; shift ;; esac
                        case $1 in
                            */install/hangar-worker) cp "$STUB_WORKER" "$out"; printf 200; exit 0 ;;
                            */api/v1/enroll) cat >"$STUB_LOG.body"; printf '{"token":"tok"}\n201'; exit 0 ;;
                        esac
                        shift
                    done
                    exit 1
                    """#,
                "sudo": #"""
                    #!/bin/sh
                    echo "sudo $*" >>"$STUB_LOG"
                    exit 0
                    """#,
                // `print` fails: nothing is loaded.
                "launchctl": #"""
                    #!/bin/sh
                    echo "launchctl $*" >>"$STUB_LOG"
                    [ "$1" != print ]
                    """#,
                // Apple silicon unless STUB_ARCH says otherwise.
                "uname": #"""
                    #!/bin/sh
                    case $1 in
                        -m) echo "${STUB_ARCH:-arm64}" ;;
                        *) echo Darwin ;;
                    esac
                    """#,
                // The preflight's license check; the real one is slow.
                "xcodebuild": "#!/bin/sh\nexit 0\n",
                "id": #"""
                    #!/bin/sh
                    case $1 in
                        -un) echo "$STUB_USER" ;;
                        -Gn) echo "$STUB_GROUPS" ;;
                        -u) echo 501 ;;
                    esac
                    """#,
            ]
            for (name, text) in stubsText {
                try Data(text.utf8).write(to: stubs.appendingPathComponent(name))
            }
            for path in try FileManager.default.contentsOfDirectory(atPath: stubs.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubs.appendingPathComponent(path).path)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("fake-worker").path)
        }

        func writeConfig(server: String) throws {
            let directory = home.appendingPathComponent("Library/Application Support/Hangar/worker")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"serverURL":"\#(server)","token":"t","maxConcurrentJobs":1,"dataDirectory":"/x"}"#.utf8)
                .write(to: directory.appendingPathComponent("config.json"))
        }

        /// Runs the script, typing `typed` on its terminal; returns its exit status and the stub log's lines.
        func run(
            _ environment: [String: String], workerSHA256: String? = nil, typed: String? = nil
        ) throws -> (status: Int32, log: [String], output: String) {
            let script = root.appendingPathComponent("install.sh")
            try Data(InstallScript.render(origin: "http://studio:8787", workerSHA256: workerSHA256).utf8).write(to: script)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", script.path]
            process.environment = [
                "PATH": root.appendingPathComponent("stubs").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": home.path, "TMPDIR": root.appendingPathComponent("tmp").path,
                "STUB_LOG": log.path, "STUB_WORKER": root.appendingPathComponent("fake-worker").path,
                "HANGAR_MACHINE_NAME": "mini-2", "HANGAR_PAIRING_CODE": "ABCD-EFGH", "TERM": "dumb",
                // Never asked here; the tests that run VM setup say so.
                "HANGAR_VM_SETUP": "0",
            ].merging(environment) { $1 }
            // `script` turns the end of its input into an EOF on the terminal, which can arrive before what was typed:
            // the input stays open until the script is done.
            let input = typed.map { _ in Pipe() }
            if let input {
                process.standardInput = input
                input.fileHandleForWriting.write(Data(typed!.utf8))
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            try input?.fileHandleForWriting.close()
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            return (process.terminationStatus, lines, text)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static let admin = ["STUB_USER": "adam", "STUB_GROUPS": "staff everyone admin"]
    static let standard = ["STUB_USER": "ci", "STUB_GROUPS": "staff everyone"]

    var workerPath: (Sandbox) -> String { { $0.home.appendingPathComponent(".local/bin/hangar-worker").path } }

    func body(_ sandbox: Sandbox) throws -> String {
        try String(contentsOf: sandbox.log.appendingPathExtension("body"), encoding: .utf8)
    }

    /// Anyone, administrator or not, gets the worker for themselves: the binary in ~/.local/bin, the configuration
    /// and a launch agent in their own login session. No other user, no sudo.
    @Test(arguments: [admin, standard])
    func theWorkerIsInstalledForWhoeverRunsTheScript(environment: [String: String]) throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(environment)
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("sudo") || $0.hasPrefix("worker isolate") })
        let setup = try #require(result.log.first { $0.hasPrefix("worker setup") })
        #expect(setup.hasPrefix("worker setup --server http://studio:8787 --max-jobs 1") && setup.hasSuffix("token=set"))
        #expect(!setup.contains("tok "), "the token stays out of the arguments")
        #expect(result.log.contains { $0.hasPrefix("launchctl bootstrap gui/501 ") })
        #expect(FileManager.default.fileExists(atPath: workerPath(sandbox)))
        #expect(!result.output.contains("hangar user"))
    }

    /// The SHA-256 check guards every install: a binary that is not the announced one is never run.
    @Test func aBinaryThatIsNotTheAnnouncedOneIsNeverRun() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin, workerSHA256: String(repeating: "0", count: 64))
        #expect(result.status != 0)
        #expect(result.output.contains("SHA-256 mismatch"), "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("worker ") }, "the stub was never run: \(result.log)")
        #expect(!FileManager.default.fileExists(atPath: workerPath(sandbox)))
    }

    @Test func theAnnouncedBinaryIsInstalled() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let worker = try Data(contentsOf: sandbox.root.appendingPathComponent("fake-worker"))
        let result = try sandbox.run(Self.admin, workerSHA256: SHA256File.hex(of: worker))
        #expect(result.status == 0, "\(result.output)")
        #expect(result.log.contains { $0.hasPrefix("worker setup ") })
    }

    // MARK: VM or local

    @Test func aNewMacIsCheckedFirstThenEnrolledPausedAndSetUpForVMBuilds() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_VM_SETUP": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("Checking this Mac:"))
        #expect(result.output.contains("Free space:"))
        #expect(result.output.contains("Tailscale:"))
        #expect(try body(sandbox).contains(#""paused":true"#))
        // After the agent, with the installed binary, in the same sudo session.
        let agent = try #require(result.log.firstIndex { $0.hasPrefix("launchctl bootstrap") })
        let setup = try #require(result.log.firstIndex { $0 == "sudo \(workerPath(sandbox)) vm setup" })
        #expect(agent < setup, "\(result.log)")
    }

    /// Picking VM builds at the question is the go-ahead for VM setup too: it is not asked again.
    @Test func choosingVMsAtThePromptRunsVMSetup() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_VM_SETUP": ""]) { $1 }, typed: "1\n")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("How should mini-2 build?"), "\(result.output)")
        #expect(result.output.contains("2) Directly on this Mac, as adam"))
        #expect(try body(sandbox).contains(#""paused":true"#))
        #expect(result.log.contains("sudo \(workerPath(sandbox)) vm setup"), "\(result.log)")
        #expect(!result.output.contains("Set up VM builds now?"))
    }

    @Test func choosingLocalAtThePromptEnrollsWithBuildsOnAndNoVMSetup() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_VM_SETUP": ""]) { $1 }, typed: "2\n")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("mini-2 builds on this Mac, as adam."), "\(result.output)")
        #expect(try body(sandbox).contains(#""paused":false"#))
        #expect(!result.log.contains { $0.hasPrefix("sudo") })
        #expect(result.output.contains("Can sign without a prompt"), "local builds sign with the login keychain")
    }

    @Test func declinedVMSetupLeavesTheCommandToRunLater() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin)
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("sudo") })
        #expect(!result.output.contains("Keychain Access"), "host signing advice is for local builds")
        #expect(result.output.contains("Builds stay paused on mini-2 until VM builds are set up. When you are ready, run: sudo \(workerPath(sandbox)) vm setup"), "\(result.output)")
        #expect(result.output.contains("resume builds on its card"))
    }

    /// Setting up VM builds needs sudo: a standard account is told what an administrator runs.
    @Test func aStandardAccountIsToldWhoSetsUpVMBuilds() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.standard.merging(["HANGAR_VM_SETUP": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("sudo") })
        #expect(result.output.contains("Next, an administrator sets up VM builds on this Mac"), "\(result.output)")
    }

    @Test func hangarVM0BuildsLocallyWithoutAsking() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_VM": "0", "HANGAR_VM_SETUP": "1"]) { $1 }, typed: "1\n")
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.output.contains("How should"))
        #expect(try body(sandbox).contains(#""paused":false"#))
        #expect(!result.log.contains { $0.hasSuffix("vm setup") })
    }

    @Test func anIntelMacBuildsLocallyWithoutAsking() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["STUB_ARCH": "x86_64", "HANGAR_VM_SETUP": "1"]) { $1 }, typed: "1\n")
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.output.contains("How should"))
        #expect(result.output.contains("this Mac builds on the host"))
        #expect(try body(sandbox).contains(#""paused":false"#))
        #expect(!result.log.contains { $0.hasSuffix("vm setup") })
    }

    @Test func anUpdateIsNotAskedAndNotOfferedVMSetup() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.writeConfig(server: "http://studio:8787")
        let result = try sandbox.run(Self.admin.merging(["STUB_CHECK": "0", "HANGAR_VM_SETUP": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.output.contains("How should"))
        #expect(!result.log.contains { $0.contains("/api/v1/enroll") })
        #expect(!result.log.contains { $0.hasSuffix("vm setup") })
    }
}
