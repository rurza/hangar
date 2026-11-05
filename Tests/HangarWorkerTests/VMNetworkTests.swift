import Foundation
import HangarCore
import Network
import Synchronization
import Testing

@testable import HangarWorker

@Suite struct VMNetworkFilterTests {
    @Test func theRulesKeepGuestsOffThisMacTheLANAndTheTailnet() {
        let rules = VMNetworkFilter().rules
        #expect(rules.contains(#"guests = "192.168.64.0/24""#))
        #expect(rules.contains(#"gateway = "192.168.64.1""#))
        for range in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4", "127.0.0.0/8"] {
            #expect(rules.contains(range), "\(range)")
        }
        let lines = rules.split(separator: "\n").map(String.init)
        func index(_ prefix: String) -> Int? { lines.firstIndex { $0.hasPrefix(prefix) } }
        // Host-initiated connections (SSH, the relay's port forward) keep state, so their answers pass the blocks.
        let hostToGuest = try? #require(index("pass out quick inet from any to $guests keep state"))
        let dns = index("pass in quick inet proto { udp, tcp } from $guests to $gateway port 53")
        let blockGateway = index("block drop in quick inet from $guests to $gateway")
        let blockSelf = index("block drop in quick inet from $guests to self")
        let blockPrivate = index("block drop in quick inet from $guests to $blocked")
        #expect(hostToGuest != nil && dns != nil && blockGateway != nil && blockSelf != nil && blockPrivate != nil)
        #expect(dns! < blockGateway! && hostToGuest! < blockGateway!)
        #expect(rules.contains("block drop in quick on $bridges inet6 all"))
        // DHCP must pass: renewals go to the gateway.
        #expect(rules.contains("port 68 to any port 67"))
    }

    @Test func theSubnetFollowsVmnetsPreferences() throws {
        let path = NSTemporaryDirectory() + "vmnet-\(UUID().uuidString).plist"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plist: [String: Any] = ["Shared_Net_Address": "192.168.70.1", "Shared_Net_Mask": "255.255.254.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        let filter = VMNetworkFilter.current(preferences: path)
        #expect(filter.gateway == "192.168.70.1")
        #expect(filter.subnet == "192.168.70.0/23")
        #expect(VMNetworkFilter.current(preferences: "/nonexistent") == VMNetworkFilter())
        #expect(VMNetworkFilter().rulesSHA256 != filter.rulesSHA256)
    }

    @Test func theLoaderLoadsTheAnchorEnablesPfAndWritesTheMarker() {
        let script = VMNetworkFilter.loaderScript
        #expect(script.contains("/sbin/pfctl -q -a 'com.apple/250.HangarVM' -f '/etc/pf.anchors/app.hangar.vm'"))
        #expect(script.contains("/sbin/pfctl -q -E"))
        #expect(script.contains("kern.boottime"))
        #expect(script.contains(VMNetworkFilter.markerPath))
        #expect(VMNetworkFilter.daemonPlist.contains("<string>app.hangar.pf</string>"))
        #expect(VMNetworkFilter.daemonPlist.contains("<key>RunAtLoad</key>"))
    }

    @Test func installCommandsPutRootOwnedFilesInPlaceAndLoadTheDaemon() {
        let commands = VMNetworkFilter().installCommands(staging: "/tmp/s")
        #expect(commands.contains(["/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "0644", "/tmp/s/rules", "/etc/pf.anchors/app.hangar.vm"]))
        #expect(commands.last == ["/bin/launchctl", "bootstrap", "system", "/Library/LaunchDaemons/app.hangar.pf.plist"])
        #expect(!commands.contains { $0.contains("/etc/pf.conf") })
    }

    struct Marker {
        let path = NSTemporaryDirectory() + "hangar-pf-marker-" + UUID().uuidString

        func write(sha: String, boot: Int, anchor: String = VMNetworkFilter.anchor, mode: Int = 0o644) throws {
            try #"{"anchor":"\#(anchor)","rulesSHA256":"\#(sha)","bootTime":\#(boot)}"#
                .write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }

    @Test func theMarkerMustNameTheseRulesAndThisBoot() throws {
        let filter = VMNetworkFilter()
        let marker = Marker()
        defer { try? FileManager.default.removeItem(atPath: marker.path) }
        let me = Int(getuid())
        #expect(filter.problem(markerPath: marker.path, bootTime: 100, ownerID: me)?.contains("not installed") == true)
        try marker.write(sha: filter.rulesSHA256, boot: 100)
        #expect(filter.problem(markerPath: marker.path, bootTime: 100, ownerID: me) == nil)
        #expect(filter.problem(markerPath: marker.path, bootTime: 200, ownerID: me)?.contains("since this Mac started") == true)
        // Written by anyone but root: not evidence.
        #expect(filter.problem(markerPath: marker.path, bootTime: 100)?.contains("root") == true)
        try marker.write(sha: "old", boot: 100)
        #expect(filter.problem(markerPath: marker.path, bootTime: 100, ownerID: me)?.contains("out of date") == true)
        try marker.write(sha: filter.rulesSHA256, boot: 100, mode: 0o666)
        #expect(filter.problem(markerPath: marker.path, bootTime: 100, ownerID: me)?.contains("root") == true)
    }

    @Test func thisMacsBootTimeIsReadable() {
        #expect((VMNetworkFilter.bootTime() ?? 0) > 1_600_000_000)
    }
}

@Suite struct GuestSSHTests {
    static let ssh = GuestSSH(
        runner: RecordingProcessRunner(), privateKey: "/vm/keys/id_ed25519", hostKeys: .pinned(knownHosts: "/vm/images/x/known_hosts"))

    @Test func pinnedHostKeysAndOnlyTheHostsKey() {
        let options = Self.ssh.options()
        #expect(options.contains("StrictHostKeyChecking=yes"))
        #expect(options.contains("UserKnownHostsFile=/vm/images/x/known_hosts"))
        #expect(options.contains("HostKeyAlias=hangar-guest"))
        #expect(options.contains("BatchMode=yes"))
        #expect(options.contains("PasswordAuthentication=no"))
        #expect(options.contains("IdentitiesOnly=yes"))
        #expect(options.starts(with: ["-F", "/dev/null"]))
    }

    @Test func theFirstLoginIntoAVanillaImageUsesItsPublishedPassword() {
        let ssh = GuestSSH(
            runner: RecordingProcessRunner(), privateKey: "/k", hostKeys: .record(knownHosts: "/kh"), askpassScript: "/askpass.sh")
        #expect(ssh.options().contains("StrictHostKeyChecking=accept-new"))
        #expect(ssh.options().contains("PreferredAuthentications=password"))
        #expect(!ssh.options().contains("BatchMode=yes"))
        #expect(ssh.environment["SSH_ASKPASS"] == "/askpass.sh")
        #expect(ssh.environment["SSH_ASKPASS_REQUIRE"] == "force")
    }

    @Test func theRemoteCommandIsOneArgumentAfterTheDestination() {
        let command = Self.ssh.command(user: "builder", host: "192.168.64.2", "echo 'hi'", extraOptions: ["-R", "1:2:3"])
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.suffix(3) == ["builder@192.168.64.2", "--", "echo 'hi'"])
        #expect(command.arguments.contains("-R"))
    }

    @Test func secretsGoOnStandardInputNotTheCommandLine() async throws {
        let runner = RecordingProcessRunner()
        let ssh = GuestSSH(runner: runner, privateKey: "/k", hostKeys: .pinned(knownHosts: "/kh"))
        try await ssh.require("x", user: "admin", host: "h", "read -r p", input: SensitiveText("s3cret\n"))
        #expect(runner.commands.first?.standardInput?.value == "s3cret\n")
        #expect(!(runner.commands.first?.arguments.joined().contains("s3cret") ?? true))
    }

    @Test func aFailedCommandNamesItself() async {
        let runner = RecordingProcessRunner()
        runner.script({ _ in true }, lines: ["boom"], exitCode: 3)
        let ssh = GuestSSH(runner: runner, privateKey: "/k", hostKeys: .pinned(knownHosts: "/kh"))
        await #expect(throws: GuestCommandError(what: "make it", exitCode: 3, output: "boom")) {
            try await ssh.require("make it", user: "admin", host: "h", "false")
        }
        #expect(GuestCommandError(what: "w", exitCode: 255, output: "").description.contains("ssh could not reach"))
    }

    @Test func copyStreamsTheFileThroughTheShell() async throws {
        let runner = RecordingProcessRunner()
        let ssh = GuestSSH(runner: runner, privateKey: "/k", hostKeys: .pinned(knownHosts: "/kh"))
        try await ssh.copy(file: "/usr/local/bin/hangar worker", user: "builder", host: "h", to: ".hangar/bin/hangar-worker")
        let command = try #require(runner.commands.first)
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments[1].hasSuffix("< '/usr/local/bin/hangar worker'"))
        #expect(command.arguments[1].contains("cat > .hangar/bin/hangar-worker"))
    }

    @Test func quotingIsPOSIX() {
        #expect(GuestSSH.quote("plain/path-1.2") == "plain/path-1.2")
        #expect(GuestSSH.quote("it's") == #"'it'\''s'"#)
        #expect(GuestSSH.quote("a b") == "'a b'")
        #expect(GuestSSH.quote("") == "''")
        #expect(GuestSSH.quote("$(rm -rf /)") == "'$(rm -rf /)'")
    }
}

@Suite struct GuestRelayCheckTests {
    static let job = UUID(uuidString: "6F1C3E2A-0000-4000-8000-000000000001")!
    static let rule = GuestRelay.Rule(jobID: job, token: "hgj_secret")
    static let server = URL(string: "http://rurzomac-mini:8787")!

    static func head(_ method: String = "POST", _ path: String? = nil, headers: [String] = ["Authorization: Bearer hgj_secret", "Content-Length: 2"]) -> String {
        (["\(method) \(path ?? "/api/v1/worker/jobs/\(job.uuidString)/steps") HTTP/1.1", "Host: 127.0.0.1:8787"] + headers)
            .joined(separator: "\r\n")
    }

    @Test func theJobsOwnRoutesWithItsTokenGoThroughRewritten() throws {
        let decision = GuestRelay.check(head: Self.head(headers: [
            "Authorization: Bearer hgj_secret", "Content-Length: 2", "Content-Type: application/json", "Connection: keep-alive",
        ]), rule: Self.rule, server: Self.server)
        guard case .forward(let head, let length) = decision else { Issue.record("refused: \(decision)"); return }
        #expect(length == 2)
        let lines = head.components(separatedBy: "\r\n")
        #expect(lines[0] == "POST /api/v1/worker/jobs/\(Self.job.uuidString)/steps HTTP/1.1")
        #expect(lines.contains("Host: rurzomac-mini:8787"))
        #expect(lines.contains("Connection: close"))
        #expect(!lines.contains("Connection: keep-alive"))
        #expect(!lines.contains("Host: 127.0.0.1:8787"))
        #expect(head.hasSuffix("\r\n\r\n"))
    }

    @Test func aServerBehindAPathPrefixKeepsIt() {
        let decision = GuestRelay.check(head: Self.head(), rule: Self.rule, server: URL(string: "https://ci.example.com/hangar/")!)
        guard case .forward(let head, _) = decision else { Issue.record("refused"); return }
        #expect(head.hasPrefix("POST /hangar/api/v1/worker/jobs/"))
        #expect(head.contains("Host: ci.example.com\r\n"))
    }

    @Test(arguments: ["start", "info", "steps", "log", "finish", "artifacts/App.ipa"])
    func everyRouteTheGuestNeedsIsAllowed(_ route: String) {
        #expect(GuestRelay.isAllowed(path: "/api/v1/worker/jobs/\(Self.job.uuidString)/\(route)", jobID: Self.job))
        #expect(GuestRelay.isAllowed(path: "/api/v1/worker/jobs/\(Self.job.uuidString.lowercased())/\(route)", jobID: Self.job))
    }

    @Test(arguments: [
        "/api/v1/worker/heartbeat", "/api/v1/worker/jobs/next", "/api/v1/worker/me",
        "/api/v1/worker/jobs/6F1C3E2A-0000-4000-8000-000000000001/token",
        "/api/v1/worker/jobs/6F1C3E2A-0000-4000-8000-000000000002/finish",
        "/api/v1/worker/jobs/6F1C3E2A-0000-4000-8000-000000000001/finish?x=1",
        "/api/v1/worker/jobs/6F1C3E2A-0000-4000-8000-000000000001/artifacts/..",
        "/api/v1/worker/jobs/6F1C3E2A-0000-4000-8000-000000000001/artifacts/a/b",
        "/api/v1/apps", "http://elsewhere/api/v1/worker/jobs/6F1C3E2A-0000-4000-8000-000000000001/finish",
    ])
    func everythingElseIsRefused(_ path: String) {
        #expect(!GuestRelay.isAllowed(path: path, jobID: Self.job))
        #expect(GuestRelay.check(head: Self.head("POST", path), rule: Self.rule, server: Self.server)
            == .refuse(status: 403, message: "only this job's worker routes are reachable from its VM"))
    }

    @Test func anotherTokenNoTokenAndOtherMethodsAreRefused() {
        let refusedToken = GuestRelay.Decision.refuse(status: 403, message: "the request does not carry this job's token")
        #expect(GuestRelay.check(head: Self.head(headers: ["Authorization: Bearer machine-token"]), rule: Self.rule, server: Self.server) == refusedToken)
        #expect(GuestRelay.check(head: Self.head(headers: []), rule: Self.rule, server: Self.server) == refusedToken)
        #expect(GuestRelay.check(
            head: Self.head(headers: ["Authorization: Bearer hgj_secret", "Authorization: Bearer x"]), rule: Self.rule,
            server: Self.server) == refusedToken)
        guard case .refuse(403, _) = GuestRelay.check(head: Self.head("GET"), rule: Self.rule, server: Self.server) else {
            Issue.record("GET passed"); return
        }
    }

    @Test func chunkedOrAmbiguousBodiesAreRefused() {
        guard case .refuse(411, _) = GuestRelay.check(
            head: Self.head(headers: ["Authorization: Bearer hgj_secret", "Transfer-Encoding: chunked"]), rule: Self.rule,
            server: Self.server)
        else { Issue.record("chunked passed"); return }
        guard case .refuse(400, _) = GuestRelay.check(
            head: Self.head(headers: ["Authorization: Bearer hgj_secret", "Content-Length: 2", "Content-Length: 5"]),
            rule: Self.rule, server: Self.server)
        else { Issue.record("two lengths passed"); return }
        guard case .refuse(400, _) = GuestRelay.check(head: "GARBAGE", rule: Self.rule, server: Self.server) else {
            Issue.record("garbage passed"); return
        }
    }

    @Test func aRequestWithoutABodyHasLengthZero() {
        guard case .forward(_, 0) = GuestRelay.check(
            head: Self.head(headers: ["Authorization: Bearer hgj_secret"]), rule: Self.rule, server: Self.server)
        else { Issue.record("refused"); return }
    }
}

/// The relay end to end, against a loopback "server" that records what reached it.
@Suite(.timeLimit(.minutes(1))) struct GuestRelayTests {
    /// Answers every connection with 200 and `{"ok":true}` once it has read a head and `Content-Length` bytes.
    final class Upstream: Sendable {
        let listener: NWListener
        let received = Mutex<[String]>([])
        let queue = DispatchQueue(label: "upstream")

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                read(connection, Data())
            }
            let ready = AsyncStream<UInt16> { continuation in
                listener.stateUpdateHandler = { [listener] state in
                    if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() }
                }
            }
            listener.start(queue: queue)
            for await port in ready { return port }
            return 0
        }

        private func read(_ connection: NWConnection, _ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, _ in
                var buffer = buffer
                if let data { buffer.append(data) }
                let text = String(decoding: buffer, as: UTF8.self)
                if let end = text.range(of: "\r\n\r\n") {
                    let head = text[..<end.lowerBound]
                    let length = head.components(separatedBy: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    if text[end.upperBound...].utf8.count >= length {
                        received.withLock { $0.append(text) }
                        let body = #"{"ok":true}"#
                        let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                }
                if complete { connection.cancel() } else { read(connection, buffer) }
            }
        }
    }

    @Test func aJobRequestReachesTheServerAndItsAnswerComesBack() async throws {
        let upstream = try Upstream()
        let upstreamPort = try await upstream.start()
        defer { upstream.listener.cancel() }
        let job = UUID()
        let relay = try GuestRelay(
            rule: .init(jobID: job, token: "hgj_t"), server: URL(string: "http://127.0.0.1:\(upstreamPort)/root")!)
        let port = try await relay.start()
        defer { relay.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/worker/jobs/\(job.uuidString)/log")!)
        request.httpMethod = "POST"
        request.setValue("Bearer hgj_t", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"entries":[]}"#.utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        let seen = try #require(upstream.received.withLock { $0.first })
        #expect(seen.hasPrefix("POST /root/api/v1/worker/jobs/\(job.uuidString)/log HTTP/1.1\r\n"))
        #expect(seen.contains("Host: 127.0.0.1:\(upstreamPort)\r\n"))
        #expect(seen.hasSuffix(#"{"entries":[]}"#))
    }

    @Test func aRefusedRequestNeverReachesTheServer() async throws {
        let upstream = try Upstream()
        let upstreamPort = try await upstream.start()
        defer { upstream.listener.cancel() }
        let relay = try GuestRelay(rule: .init(jobID: UUID(), token: "hgj_t"), server: URL(string: "http://127.0.0.1:\(upstreamPort)")!)
        let port = try await relay.start()
        defer { relay.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/worker/heartbeat")!)
        request.httpMethod = "POST"
        request.setValue("Bearer hgj_t", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        #expect(String(decoding: data, as: UTF8.self).contains("relay_refused"))
        #expect(upstream.received.withLock { $0.isEmpty })
    }
}
