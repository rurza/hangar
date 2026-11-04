import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging
import Synchronization

/// Finds an app's icon: the newest App Store Connect build's icon, else the public iTunes lookup's artwork (released
/// apps only). Only https URLs are returned. Never throws: a failure is logged at debug and reads as no icon.
/// Each source (App Store Connect, each iTunes lookup) is given up after `sourceTimeout`. Results are cached in memory:
/// an icon for an hour, a miss for ten minutes, and a miss with a timed-out source for a minute.
public final class AppIconResolver: Sendable {
    public typealias ClientProvider = @Sendable () throws -> (any AppStoreConnectClient)?

    static let hitLifetime: TimeInterval = 3600
    static let missLifetime: TimeInterval = 600
    static let timeoutMissLifetime: TimeInterval = 60

    private struct Entry {
        var url: String?
        var expiresAt: Date
    }

    private let client: ClientProvider
    private let transport: any HTTPTransport
    private let clock: any Clock<Duration>
    private let sourceTimeout: Duration
    private let now: @Sendable () -> Date
    private let cache = Mutex<[String: Entry]>([:])
    private let logger = Logger(label: "app.hangar.server.icons")

    /// `client` is asked on every lookup, so a key configured later takes effect; nil skips App Store Connect.
    /// `transport` carries the iTunes lookup; `clock` times each source out after `sourceTimeout`.
    public init(
        client: @escaping ClientProvider, transport: any HTTPTransport, clock: any Clock<Duration> = ContinuousClock(),
        sourceTimeout: Duration = .seconds(5), now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.transport = transport
        self.clock = clock
        self.sourceTimeout = sourceTimeout
        self.now = now
    }

    public func iconURL(ascAppID: String) async -> String? {
        if let cached = cached(ascAppID) { return cached.url }
        let client: (any AppStoreConnectClient)?
        do {
            client = try self.client()
        } catch {
            logger.debug("App Store Connect client unavailable: \(error)")
            client = nil
        }
        return await iconURL(ascAppID: ascAppID, client: client)
    }

    private func cached(_ ascAppID: String) -> Entry? {
        cache.withLock { $0[ascAppID] }.flatMap { $0.expiresAt > now() ? $0 : nil }
    }

    private func iconURL(ascAppID: String, client: (any AppStoreConnectClient)?) async -> String? {
        if let cached = cached(ascAppID) { return cached.url }
        let (url, timedOut) = await resolve(ascAppID, client: client)
        // An attempt the caller cancelled says nothing about the app, so a miss from it is not remembered.
        if url == nil && Task.isCancelled { return nil }
        let lifetime = url != nil ? Self.hitLifetime : timedOut ? Self.timeoutMissLifetime : Self.missLifetime
        cache.withLock { $0[ascAppID] = Entry(url: url, expiresAt: now().addingTimeInterval(lifetime)) }
        return url
    }

    /// Icons of several apps by App Store Connect ID, asking `client` (nil: the iTunes lookup only), at most
    /// `maxConcurrent` lookups at a time. Apps without an icon are absent.
    public func iconURLs(
        ascAppIDs: [String], client: (any AppStoreConnectClient)?, maxConcurrent: Int = 6
    ) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            var pending = ascAppIDs[...]
            var result: [String: String] = [:]
            func startNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask { (id, await self.iconURL(ascAppID: id, client: client)) }
            }
            for _ in 0..<max(1, maxConcurrent) { startNext() }
            while let (id, url) = await group.next() {
                if let url { result[id] = url }
                startNext()
            }
            return result
        }
    }

    private enum Outcome: Sendable {
        case value(String?)
        case failed(any Error)
        case timedOut
    }

    /// Runs one source, given up after `sourceTimeout`.
    private func bounded(_ source: @escaping @Sendable () async throws -> String?) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .value(try await source()) } catch { return .failed(error) }
            }
            group.addTask { [clock, sourceTimeout] in
                try? await clock.sleep(for: sourceTimeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// The icon, and whether a source timed out on the way.
    private func resolve(_ ascAppID: String, client: (any AppStoreConnectClient)?) async -> (String?, timedOut: Bool) {
        var sources: [(String, @Sendable () async throws -> String?)] = []
        if let client {
            sources.append(("App Store Connect", { try await client.appIconURL(appID: ascAppID).flatMap(Self.https) }))
        }
        for entity in [nil, "macSoftware"] {
            sources.append(("iTunes lookup (\(entity ?? "default"))", { try await self.lookupArtwork(ascAppID, entity: entity) }))
        }
        var timedOut = false
        for (name, source) in sources {
            switch await bounded(source) {
            case .value(let url?): return (url, timedOut)
            case .value(nil): break
            case .failed(let error): logger.debug("\(name) icon of app \(ascAppID) failed: \(error)")
            case .timedOut:
                timedOut = true
                logger.debug("\(name) icon of app \(ascAppID) timed out")
            }
        }
        return (nil, timedOut)
    }

    private struct LookupFailed: Error, CustomStringConvertible {
        var status: Int
        var description: String { "HTTP \(status)" }
    }

    private struct LookupResponse: Decodable {
        struct Item: Decodable { var artworkUrl512: String? }
        var results: [Item]
    }

    private func lookupArtwork(_ ascAppID: String, entity: String?) async throws -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: ascAppID)]
            + (entity.map { [URLQueryItem(name: "entity", value: $0)] } ?? [])
        guard let url = components.url else { return nil }
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else { throw LookupFailed(status: response.statusCode) }
        return try JSONDecoder().decode(LookupResponse.self, from: data).results.first?.artworkUrl512.flatMap(Self.https)
    }

    /// The URL when it is an absolute https URL with a host, else nil.
    static func https(_ text: String) -> String? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return text
    }
}
