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
