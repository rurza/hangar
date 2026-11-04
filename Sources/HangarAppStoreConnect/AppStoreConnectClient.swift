import Dependencies

public protocol AppStoreConnectClient: Sendable {
    /// Builds of an app, optionally of one version string; pages through `links.next`.
    func builds(appID: String, version: String?) async throws -> [ASCBuild]
    /// Build run numbers of every Xcode Cloud product of the app (read-only).
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int]
    /// Every app of the team (read-only); pages through `links.next`.
    func apps() async throws -> [ASCApp]
    /// The team's apps with one of these bundle IDs (read-only); none asked for, none returned.
    func apps(bundleIDs: [String]) async throws -> [ASCApp]
    /// The app's icon (512 × 512 PNG) from the newest of its last five builds that carries one; nil when none does.
    func appIconURL(appID: String) async throws -> String?
    func betaGroups(appID: String) async throws -> [ASCBetaGroup]
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws
    /// Creates the localization, or updates the existing one for `locale`.
    func setWhatToTest(buildID: String, locale: String, text: String) async throws
    func submitForBetaReview(buildID: String) async throws
}

extension AppStoreConnectClient {
    /// Filters `apps()`; the live client asks App Store Connect for just these.
    public func apps(bundleIDs: [String]) async throws -> [ASCApp] {
        guard !bundleIDs.isEmpty else { return [] }
        let wanted = Set(bundleIDs)
        return try await apps().filter { wanted.contains($0.bundleID) }
    }
}

private enum AppStoreConnectKey: DependencyKey {
    static let liveValue: (any AppStoreConnectClient)? = nil
    static let testValue: (any AppStoreConnectClient)? = nil
    static let previewValue: (any AppStoreConnectClient)? = nil
}

extension DependencyValues {
    /// `nil` until credentials are configured.
    public var appStoreConnect: (any AppStoreConnectClient)? {
        get { self[AppStoreConnectKey.self] }
        set { self[AppStoreConnectKey.self] = newValue }
    }
}
