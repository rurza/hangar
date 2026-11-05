import Clocks
import Foundation
import HangarAppStoreConnect
import HangarCore
import Synchronization
import Testing

@testable import HangarServer

/// Answers `appIconURL` with `icon` and counts the calls.
private final class IconASC: AppStoreConnectClient {
    let icon: String?
    private let calls = Mutex(0)
    init(icon: String?) { self.icon = icon }
    var callCount: Int { calls.withLock { $0 } }

    func appIconURL(appID: String) async throws -> String? {
        calls.withLock { $0 += 1 }
        return icon
    }
    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { [] }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "new", name: name, isInternal: isInternal)
    }
    func submitForBetaReview(buildID: String) async throws {}
}

/// Never answers until cancelled: a source slower than any timeout.
private final class Hang: Sendable {
    private let stream: AsyncStream<Never>
    private let continuation: AsyncStream<Never>.Continuation  // kept so the stream stays open
    private let calls = Mutex(0)
    init() { (stream, continuation) = AsyncStream.makeStream() }
    var callCount: Int { calls.withLock { $0 } }

    func wait() async throws -> Never {
        calls.withLock { $0 += 1 }
        for await _ in stream {}
        throw CancellationError()
    }
}

private struct HangingASC: AppStoreConnectClient {
    let hang: Hang
    func appIconURL(appID: String) async throws -> String? { try await hang.wait() }
    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] { [] }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup {
        ASCBetaGroup(id: "new", name: name, isInternal: isInternal)
    }
    func submitForBetaReview(buildID: String) async throws {}
}

private struct HangingTransport: HTTPTransport {
    let hang: Hang
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await hang.wait() }
}

/// A settable wall clock.
private final class Now: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func advance(minutes: Double) { value.withLock { $0.addTimeInterval(minutes * 60) } }
    var date: Date { value.withLock { $0 } }
}

private let ascIcon = "https://is1-ssl.mzstatic.com/image/thumb/Purple/AppIcon/512x512bb.png"
private let artwork = "https://is1-ssl.mzstatic.com/image/thumb/Purple/artwork/512x512bb.jpg"

private func lookup(_ artworkURL: String?) -> StubTransport.Response {
    guard let artworkURL else { return StubTransport.Response(body: #"{"resultCount":0,"results":[]}"#) }
    return StubTransport.Response(body: #"{"resultCount":1,"results":[{"artworkUrl512":"\#(artworkURL)"}]}"#)
}

@Suite(.timeLimit(.minutes(1))) struct AppIconResolverTests {
    private func resolver(
        _ client: (any AppStoreConnectClient)?, _ transport: StubTransport, now: Now = Now()
    ) -> AppIconResolver {
        AppIconResolver(client: { client }, transport: transport, now: { now.date })
    }

    @Test func appStoreConnectComesFirst() async throws {
        let transport = StubTransport()
        let url = await resolver(IconASC(icon: ascIcon), transport).iconURL(ascAppID: "42")
        #expect(url == ascIcon)
        #expect(transport.requests.isEmpty)
    }

    @Test func fallsBackToITunesLookupThenMacSoftware() async throws {
        let transport = StubTransport(responses: [lookup(nil), lookup(artwork)])
        let url = await resolver(IconASC(icon: nil), transport).iconURL(ascAppID: "42")
        #expect(url == artwork)
        let urls = transport.requests.compactMap(\.url?.absoluteString)
        #expect(urls == ["https://itunes.apple.com/lookup?id=42", "https://itunes.apple.com/lookup?id=42&entity=macSoftware"])
    }

    @Test func withoutAppStoreConnectKeyUsesITunes() async throws {
        let transport = StubTransport(responses: [lookup(artwork)])
        #expect(await resolver(nil, transport).iconURL(ascAppID: "42") == artwork)
    }

    @Test func nonHTTPSURLsAreRejected() async throws {
        let transport = StubTransport(responses: [lookup("http://example.com/icon.png"), lookup("javascript:alert(1)")])
        let url = await resolver(IconASC(icon: "http://is1.mzstatic.com/icon.png"), transport).iconURL(ascAppID: "42")
        #expect(url == nil)
        #expect(transport.requests.count == 2)
    }

    @Test func failuresReadAsNoIcon() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(status: 503, body: "down")])
        #expect(await resolver(nil, transport).iconURL(ascAppID: "42") == nil)  // second lookup: out of responses
    }

    @Test func iconsAreCachedForAnHour() async throws {
        let now = Now()
        let client = IconASC(icon: ascIcon)
        let resolver = resolver(client, StubTransport(), now: now)
        #expect(await resolver.iconURL(ascAppID: "42") == ascIcon)
        now.advance(minutes: 59)
        #expect(await resolver.iconURL(ascAppID: "42") == ascIcon)
        #expect(client.callCount == 1)
        now.advance(minutes: 2)
        #expect(await resolver.iconURL(ascAppID: "42") == ascIcon)
        #expect(client.callCount == 2)
    }

    @Test func missesAreCachedForTenMinutes() async throws {
        let now = Now()
        let transport = StubTransport(responses: [lookup(nil), lookup(nil)])
        let resolver = resolver(nil, transport, now: now)
        #expect(await resolver.iconURL(ascAppID: "42") == nil)
        now.advance(minutes: 9)
        #expect(await resolver.iconURL(ascAppID: "42") == nil)
        #expect(transport.requests.count == 2)
        now.advance(minutes: 2)
        transport.enqueue(lookup(artwork))
        #expect(await resolver.iconURL(ascAppID: "42") == artwork)
    }

    @Test func timedOutSourcesAreGivenUpAndTheMissCachedForAMinute() async throws {
        let now = Now()
        let hang = Hang()
        // The immediate clock times every source out at once; the hanging sources never answer first.
        let resolver = AppIconResolver(
            client: { HangingASC(hang: hang) }, transport: HangingTransport(hang: hang), clock: ImmediateClock(),
            now: { now.date })
        #expect(await resolver.iconURL(ascAppID: "42") == nil)
        #expect(hang.callCount == 3)  // App Store Connect and both lookups, each given up
        now.advance(minutes: 59.0 / 60)
        #expect(await resolver.iconURL(ascAppID: "42") == nil)
        #expect(hang.callCount == 3)
        now.advance(minutes: 2.0 / 60)
        #expect(await resolver.iconURL(ascAppID: "42") == nil)
        #expect(hang.callCount == 6)
    }

    @Test func iconURLsResolvesEveryApp() async throws {
        let client = IconASC(icon: ascIcon)
        let icons = await resolver(nil, StubTransport()).iconURLs(ascAppIDs: ["1", "2", "3"], client: client, maxConcurrent: 2)
        #expect(icons == ["1": ascIcon, "2": ascIcon, "3": ascIcon])
        #expect(client.callCount == 3)
    }

    @Test func backfillStoresIconsOncePerHour() async throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        let apps = AppRepository(database: database)
        let app = try apps.create(CreateAppRequest(name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42"))
        let now = Now()
        let transport = StubTransport(responses: [lookup(nil), lookup(nil)])
        let backfill = AppIconBackfill(resolver: resolver(nil, transport, now: now), apps: apps, now: { now.date })

        backfill.fill([app])
        await backfill.waitForIdle()
        #expect(try apps.find(slugOrID: "legilo")?.iconURL == nil)
        #expect(transport.requests.count == 2)

        now.advance(minutes: 30)  // the miss has expired, but the app was tried within the hour
        backfill.fill([app])
        await backfill.waitForIdle()
        #expect(transport.requests.count == 2)

        now.advance(minutes: 31)
        transport.enqueue(lookup(artwork))
        backfill.fill([app])
        await backfill.waitForIdle()
        #expect(try apps.find(slugOrID: "legilo")?.iconURL == artwork)
    }
}
