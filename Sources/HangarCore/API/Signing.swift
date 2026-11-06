import Foundation

/// Where the server's Apple Development identity came from.
public enum SigningIdentityOrigin: String, Codable, Sendable {
    /// Hangar created the certificate through the App Store Connect API; it may revoke it on renewal.
    case created
    /// The owner uploaded a `.p12` of a certificate they already had; Hangar never revokes it.
    case imported
}

/// The server's identity as the API shows it: never the `.p12` or its password.
public struct SigningIdentityInfo: Codable, Equatable, Sendable {
    /// The certificate's common name, e.g. "Apple Development: Created via API (A1B2C3D4E5)".
    public var name: String
    public var teamID: String?
    public var serialNumber: String
    public var expiresAt: Date
    public var createdAt: Date
    public var origin: SigningIdentityOrigin
    /// The certificate's App Store Connect ID; only for one Hangar created.
    public var ascCertificateID: String?

    public init(
        name: String, teamID: String?, serialNumber: String, expiresAt: Date, createdAt: Date,
        origin: SigningIdentityOrigin, ascCertificateID: String? = nil
    ) {
        self.name = name
        self.teamID = teamID
        self.serialNumber = serialNumber
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.origin = origin
        self.ascCertificateID = ascCertificateID
    }
}

/// `GET /api/v1/signing`: the one Apple Development identity VM archives sign with.
public struct SigningStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case none
        case active
        /// Expires within `SigningStatus.renewalWindowDays`: it can be renewed.
        case expiring
        case expired
    }

    public static let renewalWindowDays = 30

    public var state: State
    public var identity: SigningIdentityInfo?
    /// Create (no identity) or Renew (one in the renewal window, or expired) is allowed right now.
    public var canCreate: Bool
    /// Why Create or Renew is not allowed, in plain English; nil when it is.
    public var createBlockedReason: String?
    /// When the 24-hour guard allows the next certificate; nil when it does not hold one back.
    public var nextCreationAt: Date?

    public init(
        state: State, identity: SigningIdentityInfo?, canCreate: Bool, createBlockedReason: String? = nil,
        nextCreationAt: Date? = nil
    ) {
        self.state = state
        self.identity = identity
        self.canCreate = canCreate
        self.createBlockedReason = createBlockedReason
        self.nextCreationAt = nextCreationAt
    }
}

/// `POST /api/v1/signing/certificate`: what Create or Renew did.
public struct SigningCreateResponse: Codable, Equatable, Sendable {
    public var status: SigningStatus
    /// The App Store Connect ID of the old Hangar-created certificate revoked after a renewal.
    public var revokedCertificateID: String?
    /// Set when revoking the old certificate failed: the new one is in use, the old one is still valid at Apple.
    public var revokeProblem: String?

    public init(status: SigningStatus, revokedCertificateID: String? = nil, revokeProblem: String? = nil) {
        self.status = status
        self.revokedCertificateID = revokedCertificateID
        self.revokeProblem = revokeProblem
    }
}

/// `POST /api/v1/signing/import`: a `.p12` (base64 in JSON) and its password.
public struct ImportSigningIdentityRequest: Codable, Equatable, Sendable, CustomStringConvertible {
    public var p12: Data
    public var password: String

    public init(p12: Data, password: String) {
        self.p12 = p12
        self.password = password
    }

    public var description: String { "<identity>" }
}

/// The identity in a VM archive job's assignment, for the guest's temporary keychain.
public struct JobSigningIdentity: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var p12: Data
    public var password: String

    public init(p12: Data, password: String) {
        self.p12 = p12
        self.password = password
    }

    public var description: String { "<identity>" }
    public var debugDescription: String { "<identity>" }
}

/// An App Store Connect API key as the server holds it (Settings › App Store Connect): never a variable, so never in
/// a job's environment. A `JobAssignment` carries it only to a worker that runs `xcodebuild` with it itself: the host
/// Mac's xcodebuild steps, or a VM Mac's host-side export and upload. It never enters a VM guest.
public struct AppStoreConnectKey: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var keyID: String
    /// Nil for an individual key; xcodebuild only accepts team keys.
    public var issuerID: String?
    /// The `.p8` file's contents.
    public var privateKey: String

    public init(keyID: String, issuerID: String?, privateKey: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKey = privateKey
    }

    public var isTeamKey: Bool { issuerID.map { !$0.isEmpty } ?? false }

    public var description: String { "<App Store Connect key \(keyID)>" }
    public var debugDescription: String { description }
}

/// `POST /api/v1/worker/jobs/{id}/provisioning`: a VM Mac's host asks, with its machine token, what its guest needs
/// to sign the archive without any App Store Connect key of the server's.
public struct JobProvisioningRequest: Codable, Equatable, Sendable {
    /// False when the host gives the guest its own identity (`vm identity import`): Hangar's profiles hold Hangar's
    /// certificate, not that one, so none are looked up.
    public var useServerIdentity: Bool

    public init(useServerIdentity: Bool = true) { self.useServerIdentity = useServerIdentity }
}

/// A development provisioning profile for one bundle ID of the app, with the server's signing certificate in it.
public struct JobProvisioningProfile: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var uuid: String
    /// A macOS profile is a `.provisionprofile`, the others `.mobileprovision`.
    public var isMac: Bool
    /// The signed profile file; it holds no private key.
    public var content: Data

    public init(bundleID: String, name: String, uuid: String, isMac: Bool, content: Data) {
        self.bundleID = bundleID
        self.name = name
        self.uuid = uuid
        self.isMac = isMac
        self.content = content
    }
}

/// A bundle ID of the app that has no usable development profile, and why.
public struct MissingProfile: Codable, Equatable, Sendable {
    public var bundleID: String
    public var reason: String

    public init(bundleID: String, reason: String) {
        self.bundleID = bundleID
        self.reason = reason
    }
}

/// What a VM archive's guest signs with. With `missing` empty the guest signs manually with `profiles`. Otherwise
/// the optional development key (Settings › App Store Connect, Developer role) comes too, and the guest's
/// `-allowProvisioningUpdates` uses it; without one an iOS-family archive fails before its VM boots. The server's
/// own key is never in it.
public struct JobProvisioning: Codable, Equatable, Sendable {
    public var profiles: [JobProvisioningProfile]
    public var missing: [MissingProfile]
    public var developmentKey: AppStoreConnectKey?
    /// What the server did, for the job's log ("created development profile …").
    public var notes: [String]

    public init(
        profiles: [JobProvisioningProfile] = [], missing: [MissingProfile] = [], developmentKey: AppStoreConnectKey? = nil,
        notes: [String] = []
    ) {
        self.profiles = profiles
        self.missing = missing
        self.developmentKey = developmentKey
        self.notes = notes
    }
}
