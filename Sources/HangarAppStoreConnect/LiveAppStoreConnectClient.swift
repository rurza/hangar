import Foundation
import HangarCore
import Synchronization

public final class LiveAppStoreConnectClient: AppStoreConnectClient {
    private static let host = "api.appstoreconnect.apple.com"
    private static let base = "https://\(host)"
    private static let maxPages = 1000
    private static let lifetime: TimeInterval = 1200
    private static let refreshMargin: TimeInterval = 60

    private struct CachedToken {
        var token: String
        var expiresAt: Date
    }

    private let credentials: ASCCredentials
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let cache = Mutex<CachedToken?>(nil)

    public init(credentials: ASCCredentials, transport: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    // MARK: - API

    public func builds(appID: String, version: String?) async throws -> [ASCBuild] {
        var query = [URLQueryItem(name: "filter[app]", value: appID)]
        if let version { query.append(URLQueryItem(name: "filter[version]", value: version)) }
        query += [URLQueryItem(name: "include", value: "preReleaseVersion"), URLQueryItem(name: "limit", value: "200")]
        var result: [ASCBuild] = []
        for page in try await pages(Wire.Builds.self, path: "/v1/builds", query: query) {
            let platforms = Dictionary(
                (page.included ?? []).filter { $0.type == "preReleaseVersions" }.compactMap { item in
                    item.attributes?.platform.map { (item.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            for item in page.data {
                let preRelease = item.relationships?.preReleaseVersion?.data?.id
                result.append(ASCBuild(
                    id: item.id,
                    version: item.attributes.version,
                    processingState: item.attributes.processingState ?? "",
                    platform: preRelease.flatMap { platforms[$0] },
                    uploadedDate: item.attributes.uploadedDate.flatMap(Self.parseDate)))
            }
        }
        return result
    }

    public func xcodeCloudRunNumbers(appID: String) async throws -> [Int] {
        let products = try await pages(Wire.Resources.self, path: "/v1/ciProducts", query: [URLQueryItem(name: "filter[app]", value: appID)])
        var numbers: [Int] = []
        for productID in products.flatMap({ $0.data.map(\.id) }) {
            let path = "/v1/ciProducts/\(productID)/buildRuns"
            for page in try await pages(Wire.BuildRuns.self, path: path, query: [URLQueryItem(name: "limit", value: "200")]) {
                numbers += page.data.map(\.attributes.number)
            }
        }
        return numbers
    }

    public func betaGroups(appID: String) async throws -> [ASCBetaGroup] {
        let query = [URLQueryItem(name: "filter[app]", value: appID), URLQueryItem(name: "limit", value: "200")]
        return try await pages(Wire.BetaGroups.self, path: "/v1/betaGroups", query: query).flatMap { page in
            page.data.map { ASCBetaGroup(id: $0.id, name: $0.attributes.name, isInternal: $0.attributes.isInternalGroup ?? false) }
        }
    }

    public func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {
        let body = JSONNode.object(["data": .array([.object(["type": .string("builds"), "id": .string(buildID)])])])
        _ = try await request("POST", url: try url(path: "/v1/betaGroups/\(groupID)/relationships/builds"), body: body)
    }

    public func setWhatToTest(buildID: String, locale: String, text: String) async throws {
        let listURL = try url(path: "/v1/builds/\(buildID)/betaBuildLocalizations")
        let existing = try decode(Wire.Localizations.self, from: try await request("GET", url: listURL, body: nil))
        if let match = existing.data.first(where: { $0.attributes.locale == locale }) {
            let body = JSONNode.object(["data": .object([
                "type": .string("betaBuildLocalizations"), "id": .string(match.id),
                "attributes": .object(["whatsNew": .string(text)]),
            ])])
            _ = try await request("PATCH", url: try url(path: "/v1/betaBuildLocalizations/\(match.id)"), body: body)
        } else {
            let body = JSONNode.object(["data": .object([
                "type": .string("betaBuildLocalizations"),
                "attributes": .object(["locale": .string(locale), "whatsNew": .string(text)]),
                "relationships": .object(["build": Self.buildReference(buildID)]),
            ])])
            _ = try await request("POST", url: try url(path: "/v1/betaBuildLocalizations"), body: body)
        }
    }

    public func submitForBetaReview(buildID: String) async throws {
        let body = JSONNode.object(["data": .object([
            "type": .string("betaAppReviewSubmissions"),
            "relationships": .object(["build": Self.buildReference(buildID)]),
        ])])
        _ = try await request("POST", url: try url(path: "/v1/betaAppReviewSubmissions"), body: body)
    }

    // MARK: - Plumbing

    /// Minimal JSON tree for request bodies.
    private enum JSONNode: Encodable {
        case string(String)
        case object([String: JSONNode])
        case array([JSONNode])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            }
        }
    }

    private static func buildReference(_ buildID: String) -> JSONNode {
        .object(["data": .object(["type": .string("builds"), "id": .string(buildID)])])
    }

    private func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(string: Self.base)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ASCError.decoding("invalid URL for \(path)") }
        return url
    }

    /// Fetches every page, following the absolute `links.next` URL until it is absent.
    /// `next` must stay on the API host over https (the JWT is sent with it), must not repeat, and is capped.
    private func pages<Page: Decodable & Paged>(_ type: Page.Type, path: String, query: [URLQueryItem]) async throws -> [Page] {
        var result: [Page] = []
        var visited: Set<URL> = []
        var next: URL? = try url(path: path, query: query)
        while let current = next {
            guard visited.insert(current).inserted else { throw ASCError.decoding("pagination cycle") }
            guard visited.count <= Self.maxPages else { throw ASCError.decoding("too many pages") }
            let page = try decode(Page.self, from: try await request("GET", url: current, body: nil))
            result.append(page)
            next = try page.nextURL.map { link in
                guard let url = URL(string: link), url.scheme == "https", url.host == Self.host else {
                    throw ASCError.decoding("unexpected pagination link")
                }
                return url
            }
        }
        return result
    }

    private func request(_ method: String, url: URL, body: JSONNode?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try bearerToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ASCError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ASCError.decoding(String(describing: error))
        }
    }

    private func bearerToken() throws -> String {
        let current = now()
        return try cache.withLock { cached in
            if let cached, cached.expiresAt.timeIntervalSince(current) > Self.refreshMargin { return cached.token }
            let token = try ASCJWT.token(credentials, now: current, lifetime: Self.lifetime)
            cached = CachedToken(token: token, expiresAt: ASCJWT.expiry(now: current, lifetime: Self.lifetime))
            return token
        }
    }

    /// App Store Connect dates carry an offset and sometimes fractional seconds.
    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

private protocol Paged {
    var nextURL: String? { get }
}

/// JSON:API response shapes, only the fields we read.
private enum Wire {
    struct Links: Decodable { var next: String? }

    struct Resources: Decodable, Paged {
        struct Item: Decodable { var id: String }
        var data: [Item]
        var links: Links?
        var nextURL: String? { links?.next }
    }

    struct Builds: Decodable, Paged {
        struct Item: Decodable {
            struct Attributes: Decodable {
                var version: String
                var processingState: String?
                var uploadedDate: String?
            }
            struct Relationships: Decodable {
                struct Ref: Decodable {
                    struct Data: Decodable { var id: String }
                    var data: Data?
                }
                var preReleaseVersion: Ref?
            }
            var id: String
            var attributes: Attributes
            var relationships: Relationships?
        }
        struct Included: Decodable {
            struct Attributes: Decodable { var platform: String? }
            var type: String
            var id: String
            var attributes: Attributes?
        }
        var data: [Item]
        var included: [Included]?
        var links: Links?
        var nextURL: String? { links?.next }
    }

    struct BuildRuns: Decodable, Paged {
        struct Item: Decodable {
            struct Attributes: Decodable { var number: Int }
            var attributes: Attributes
        }
        var data: [Item]
        var links: Links?
        var nextURL: String? { links?.next }
    }

    struct BetaGroups: Decodable, Paged {
        struct Item: Decodable {
            struct Attributes: Decodable {
                var name: String
                var isInternalGroup: Bool?
            }
            var id: String
            var attributes: Attributes
        }
        var data: [Item]
        var links: Links?
        var nextURL: String? { links?.next }
    }

    struct Localizations: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable { var locale: String? }
            var id: String
            var attributes: Attributes
        }
        var data: [Item]
    }
}
