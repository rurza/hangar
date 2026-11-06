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
    /// One app by its App Store Connect ID; nil when the team has no such app.
    func app(id: String) async throws -> ASCApp?
    /// The app's icon (512 × 512 PNG) from the newest of its last five builds that carries one; nil when none does.
    func appIconURL(appID: String) async throws -> String?
    func betaGroups(appID: String) async throws -> [ASCBetaGroup]
    /// Creates a TestFlight group of the app (`POST /v1/betaGroups`); `internal` makes it an internal group, whose
    /// testers are App Store Connect users of the team.
    func createBetaGroup(appID: String, name: String, internal isInternal: Bool) async throws -> ASCBetaGroup
    /// Grants the group access to the build: `POST /v1/builds/{id}/relationships/betaGroups` ("Add access for beta
    /// groups to a build"). Not for a group that `receivesEveryBuild`: App Store Connect refuses any manual assignment
    /// to one with 422 "Builds cannot be assigned to this internal group", in this direction and the other
    /// (`POST /v1/betaGroups/{id}/relationships/builds`).
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws
    /// Creates the localization, or updates the existing one for `locale`.
    func setWhatToTest(buildID: String, locale: String, text: String) async throws
    func submitForBetaReview(buildID: String) async throws
    /// The app's TestFlight test information per locale (`GET /v1/apps/{id}/betaAppLocalizations`, read-only).
    func betaAppLocalizations(appID: String) async throws -> [ASCBetaAppLocalization]
    /// Creates a signing certificate from a PEM certificate signing request (`POST /v1/certificates`). Only the
    /// server's explicit "Create Hangar's signing certificate" action calls it. Needs a team key: individual keys
    /// cannot use the provisioning endpoints.
    func createCertificate(type: ASCCertificateType, csrPEM: String) async throws -> ASCCertificate
    /// Revokes one certificate by its App Store Connect ID (`DELETE /v1/certificates/{id}`).
    func revokeCertificate(id: String) async throws

    // Development provisioning for VM archives (VM builds design, *Signing*). Team keys only.

    /// The team's registered bundle IDs (`GET /v1/bundleIds`, read-only).
    func bundleIdentifiers() async throws -> [ASCBundleIdentifier]
    /// The team's active development profiles of `type`, with their bundle ID and certificates (read-only).
    func developmentProfiles(type: ASCDevelopmentProfileType) async throws -> [ASCProfile]
    /// The IDs of the team's enabled devices of a `/v1/devices` platform (`IOS`, `MAC_OS`; read-only).
    func enabledDeviceIDs(platform: String) async throws -> [String]
    /// The App Store Connect ID of the certificate with this serial number; nil when there is none.
    func certificateID(serialNumber: String) async throws -> String?
    /// Whether the key may list the team's users (`GET /v1/users`), which only an Admin key may: the development key
    /// must not be one.
    func canListUsers() async throws -> Bool
    /// Creates a development profile (`POST /v1/profiles`). Only the server's development-profile service calls it,
    /// for a bundle ID of the app being archived that has none with Hangar's certificate.
    func createDevelopmentProfile(
        name: String, type: ASCDevelopmentProfileType, bundleIDResourceID: String, certificateIDs: [String],
        deviceIDs: [String]
    ) async throws -> ASCProfile
}

extension AppStoreConnectClient {
    /// Clients that cannot create certificates say so.
    public func createCertificate(type: ASCCertificateType, csrPEM: String) async throws -> ASCCertificate {
        throw ASCError.decoding("creating certificates is not available from this client")
    }

    public func revokeCertificate(id: String) async throws {
        throw ASCError.decoding("revoking certificates is not available from this client")
    }

    public func bundleIdentifiers() async throws -> [ASCBundleIdentifier] {
        throw ASCError.decoding("bundle IDs are not available from this client")
    }

    public func developmentProfiles(type: ASCDevelopmentProfileType) async throws -> [ASCProfile] {
        throw ASCError.decoding("profiles are not available from this client")
    }

    public func enabledDeviceIDs(platform: String) async throws -> [String] {
        throw ASCError.decoding("devices are not available from this client")
    }

    public func certificateID(serialNumber: String) async throws -> String? {
        throw ASCError.decoding("certificates are not available from this client")
    }

    public func canListUsers() async throws -> Bool { false }

    public func createDevelopmentProfile(
        name: String, type: ASCDevelopmentProfileType, bundleIDResourceID: String, certificateIDs: [String],
        deviceIDs: [String]
    ) async throws -> ASCProfile {
        throw ASCError.decoding("creating profiles is not available from this client")
    }

    /// Clients that cannot read it say so; the deploy check then says nothing about it.
    public func betaAppLocalizations(appID: String) async throws -> [ASCBetaAppLocalization] {
        throw ASCError.decoding("beta app localizations are not available from this client")
    }

    /// Filters `apps()`; the live client asks App Store Connect for just these.
    public func apps(bundleIDs: [String]) async throws -> [ASCApp] {
        guard !bundleIDs.isEmpty else { return [] }
        let wanted = Set(bundleIDs)
        return try await apps().filter { wanted.contains($0.bundleID) }
    }

    /// Searches `apps()`; the live client asks App Store Connect for just this one.
    public func app(id: String) async throws -> ASCApp? {
        try await apps().first { $0.id == id }
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
