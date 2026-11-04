import Foundation
import HangarAppStoreConnect
import HangarCore

public enum BuildNumberError: Error, Equatable, Sendable {
    case appStoreConnectNotConfigured
    case sourceUnavailable(source: String, reason: String)
    /// A `CFBundleVersion` that is not a plain non-negative integer; never guessed at.
    case nonInteger(source: String, value: String)
    case bumpNotHigher(current: Int, requested: Int)
}

/// A place that may already hold build numbers for an app.
public protocol KnownNumberSource: Sendable {
    var name: String { get }
    /// The highest number the source knows, or nil when it knows none.
    func highestNumber(for app: App) async throws -> Int?
}

/// Every build of the app in App Store Connect, all platforms.
public struct AppStoreConnectBuildsSource: KnownNumberSource {
    public static let sourceName = "app-store-connect"
    public var name: String { Self.sourceName }
    let client: any AppStoreConnectClient

    public init(client: any AppStoreConnectClient) { self.client = client }

    public func highestNumber(for app: App) async throws -> Int? {
        var highest: Int?
        for build in try await client.builds(appID: app.appStoreConnectAppID, version: nil) {
            guard !build.version.isEmpty, build.version.utf8.allSatisfy({ (48...57).contains($0) }),
                let number = Int(build.version)
            else { throw BuildNumberError.nonInteger(source: name, value: build.version) }
            highest = max(highest ?? number, number)
        }
        return highest
    }
}

/// Xcode Cloud run numbers, read-only.
public struct XcodeCloudRunsSource: KnownNumberSource {
    public static let sourceName = "xcode-cloud"
    public var name: String { Self.sourceName }
    let client: any AppStoreConnectClient

    public init(client: any AppStoreConnectClient) { self.client = client }

    public func highestNumber(for app: App) async throws -> Int? {
        try await client.xcodeCloudRunNumbers(appID: app.appStoreConnectAppID).max()
    }
}

/// Phase 1 stub: Phase 2 (Sparkle appcasts) fills in the body.
public struct AppcastSource: KnownNumberSource {
    public static let sourceName = "appcast"
    public var name: String { Self.sourceName }

    public init() {}

    public func highestNumber(for app: App) async throws -> Int? { nil }
}
