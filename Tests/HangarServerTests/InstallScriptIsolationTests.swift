import Foundation
import HangarCore
import Testing

@testable import HangarServer

/// Who the install script installs for. It runs for real against stubs of curl, sudo, launchctl and id (first on
/// PATH, so neither sudo nor launchctl ever runs), with HOME and TMPDIR in a temporary directory, under `script` so
/// it has a terminal. The downloaded "hangar-worker" is a stub that logs its arguments.
@Suite(.timeLimit(.minutes(1))) struct InstallScriptIsolationTests {
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
                    case $1 in
                        /bin/test) exit "${STUB_HANGAR_CONFIG:-1}" ;;
                        /usr/bin/plutil) echo "${STUB_HANGAR_SERVER:-}" ;;
                    esac
                    exit 0
                    """#,
                // `print` fails (nothing loaded) unless STUB_DAEMON=1 loads the hangar user's LaunchDaemon.
                "launchctl": #"""
                    #!/bin/sh
                    echo "launchctl $*" >>"$STUB_LOG"
                    [ "$1" != print ] || { [ "${STUB_DAEMON:-}" = 1 ] && [ "$2" = system/app.hangar.worker ]; }
                    """#,
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

        /// Runs the script; returns its exit status and the stub log's lines.
        func run(_ environment: [String: String], workerSHA256: String? = nil) throws -> (status: Int32, log: [String], output: String) {
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
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            return (process.terminationStatus, lines, text)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static let admin = ["STUB_USER": "adam", "STUB_GROUPS": "staff everyone admin"]

    @Test func anAdministratorEnrollsIntoATemporaryConfigurationAndIsolates() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin)
        #expect(result.status == 0, "\(result.output)")
        let isolate = try #require(result.log.first { $0.hasPrefix("worker isolate") })
        #expect(isolate.wholeMatch(of: /worker isolate --binary (.+)\/hangar-worker --config \1\/config\.json/) != nil, "\(isolate)")
        let setup = try #require(result.log.first { $0.hasPrefix("worker setup") })
        #expect(setup.contains("--config ") && setup.hasSuffix("token=set"))
        #expect(!setup.contains("tok "), "the token stays out of the arguments")
        #expect(result.log.contains { $0.hasPrefix("sudo /bin/test -f /Users/hangar/") })
        #expect(result.log.contains { $0.contains("/api/v1/enroll") })
        #expect(!result.log.contains { $0.hasPrefix("launchctl") }, "isolate, not the script, installs the agent")
        #expect(!FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(".local/bin/hangar-worker").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.appendingPathComponent("tmp").path)
        #expect(leftovers.isEmpty, "the temporary directory with the token is removed: \(leftovers)")
        #expect(result.output.contains("HANGAR_AS_CURRENT_USER=1"))
    }

    @Test func anEnrolledWorkerMovesWithoutANewPairing() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.writeConfig(server: "http://studio:8787")
        let result = try sandbox.run(Self.admin.merging(["STUB_CHECK": "0"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        let isolate = try #require(result.log.first { $0.hasPrefix("worker isolate") })
        #expect(isolate.wholeMatch(of: /worker isolate --binary \S+\/hangar-worker/) != nil, "\(isolate)")
        #expect(!result.log.contains { $0.contains("/api/v1/enroll") })
        #expect(!result.log.contains { $0.hasPrefix("sudo") })
    }

    @Test func aHangarUserAlreadyEnrolledIsUpdated() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(
            Self.admin.merging(["STUB_HANGAR_CONFIG": "0", "STUB_HANGAR_SERVER": "http://studio:8787"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        let isolate = try #require(result.log.first { $0.hasPrefix("worker isolate") })
        #expect(!isolate.contains("--config"))
        #expect(!result.log.contains { $0.contains("/api/v1/enroll") })
    }

    @Test func optingOutInstallsForTheCurrentUser() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_AS_CURRENT_USER": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("worker isolate") || $0.hasPrefix("sudo") })
        #expect(result.log.contains { $0.hasPrefix("worker setup --server http://studio:8787 --max-jobs 1") })
        #expect(result.log.contains { $0.hasPrefix("launchctl bootstrap gui/501 ") })
        #expect(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(".local/bin/hangar-worker").path))
    }

    @Test(arguments: [
        ["STUB_USER": "hangar", "STUB_GROUPS": "staff everyone"],
        ["STUB_USER": "ci", "STUB_GROUPS": "staff everyone"],
    ])
    func theHangarUserOrAStandardAccountInstallsForItself(environment: [String: String]) throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(environment)
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("worker isolate") || $0.hasPrefix("sudo") })
        #expect(result.log.contains { $0.hasPrefix("launchctl bootstrap gui/501 ") })
    }

    /// isolate made hangar's worker a LaunchDaemon; an agent beside it would be a second worker with the same token.
    @Test func theHangarUserDoesNotGetAnAgentBesideItsDaemon() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(["STUB_USER": "hangar", "STUB_GROUPS": "staff everyone", "STUB_DAEMON": "1"])
        #expect(result.status != 0)
        #expect(result.output.contains("runs as a LaunchDaemon"), "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("launchctl bootstrap") || $0.hasPrefix("worker setup") })
    }

    /// The SHA-256 check guards every install: a binary that is not the announced one never reaches isolate (and so
    /// never the hangar user) or setup.
    @Test(arguments: [admin, admin.merging(["HANGAR_AS_CURRENT_USER": "1"]) { $1 }])
    func aBinaryThatIsNotTheAnnouncedOneIsNeverRun(environment: [String: String]) throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(environment, workerSHA256: String(repeating: "0", count: 64))
        #expect(result.status != 0)
        #expect(result.output.contains("SHA-256 mismatch"), "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("worker ") }, "the stub was never run: \(result.log)")
        #expect(!FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(".local/bin/hangar-worker").path))
    }

    @Test func theAnnouncedBinaryIsHandedToIsolate() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let worker = try Data(contentsOf: sandbox.root.appendingPathComponent("fake-worker"))
        let result = try sandbox.run(Self.admin, workerSHA256: SHA256File.hex(of: worker))
        #expect(result.status == 0, "\(result.output)")
        #expect(result.log.contains { $0.hasPrefix("worker isolate --binary ") })
    }

    // MARK: VM builds

    var appleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    @Test func aNewMacIsCheckedFirstThenEnrolledPausedAndOfferedVMSetup() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_VM_SETUP": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("Checking this Mac:"))
        #expect(result.output.contains("Free space:"))
        #expect(result.output.contains("Tailscale:"))
        let body = try String(contentsOf: sandbox.log.appendingPathExtension("body"), encoding: .utf8)
        #expect(body.contains(#""paused":\#(appleSilicon)"#), "\(body)")
        // VM setup runs after isolate, with the hangar user's binary, in the same sudo session.
        let isolate = try #require(result.log.firstIndex { $0.hasPrefix("worker isolate") })
        let setup = result.log.firstIndex { $0 == "sudo /Users/hangar/.local/bin/hangar-worker vm setup" }
        if appleSilicon {
            #expect(setup.map { $0 > isolate } == true, "\(result.log)")
        } else {
            #expect(setup == nil)
        }
    }

    @Test func declinedVMSetupLeavesTheCommandToRunLater() throws {
        guard appleSilicon else { return }
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_AS_CURRENT_USER": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.log.contains { $0.hasPrefix("sudo") })
        #expect(!result.output.contains("Keychain Access"), "host signing advice is for host builds")
        let worker = sandbox.home.appendingPathComponent(".local/bin/hangar-worker").path
        #expect(result.output.contains("Builds stay paused on mini-2 until VM builds are set up. When you are ready, run: sudo \(worker) vm setup"), "\(result.output)")
    }

    @Test func hostBuildsEnrollUnpausedAndSkipVMSetup() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let result = try sandbox.run(Self.admin.merging(["HANGAR_VM": "0", "HANGAR_VM_SETUP": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        let body = try String(contentsOf: sandbox.log.appendingPathExtension("body"), encoding: .utf8)
        #expect(body.contains(#""paused":false"#))
        #expect(!result.log.contains { $0.hasSuffix("vm setup") })
    }

    @Test func anUpdateIsNotOfferedVMSetup() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.writeConfig(server: "http://studio:8787")
        let result = try sandbox.run(Self.admin.merging(["STUB_CHECK": "0", "HANGAR_VM_SETUP": "1"]) { $1 })
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.log.contains { $0.hasSuffix("vm setup") })
    }
}
