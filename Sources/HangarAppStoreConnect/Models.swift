import Foundation

public struct ASCCredentials: Sendable {
    public var keyID: String
    public var issuerID: String
    public var privateKeyPEM: String

    public init(keyID: String, issuerID: String, privateKeyPEM: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPEM = privateKeyPEM
    }
}

public struct ASCBuild: Sendable, Equatable {
    public var id: String
    /// Raw `CFBundleVersion`; integer validation is the caller's job.
    public var version: String
    /// PROCESSING, FAILED, INVALID or VALID.
    public var processingState: String
    /// IOS, MAC_OS, … from the included pre-release version.
    public var platform: String?
    public var uploadedDate: Date?

    public init(id: String, version: String, processingState: String, platform: String?, uploadedDate: Date?) {
        self.id = id
        self.version = version
        self.processingState = processingState
        self.platform = platform
        self.uploadedDate = uploadedDate
    }
}

public struct ASCBetaGroup: Sendable, Equatable {
    public var id: String
    public var name: String
    public var isInternal: Bool

    public init(id: String, name: String, isInternal: Bool) {
        self.id = id
        self.name = name
        self.isInternal = isInternal
    }
}

public enum ASCError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case http(status: Int, body: String)
    case decoding(String)
    case nonIntegerBuildNumber(version: String, buildID: String)
    /// The configured private key is not a valid P-256 PEM. Never carries the key itself.
    case invalidPrivateKey

    public var description: String {
        switch self {
        case .notConfigured: "App Store Connect credentials are not configured"
        case .http(let status, let body): "App Store Connect returned HTTP \(status): \(body)"
        case .decoding(let message): "Could not decode the App Store Connect response: \(message)"
        case .nonIntegerBuildNumber(let version, let buildID):
            "Build \(buildID) has the non-integer build number \"\(version)\""
        case .invalidPrivateKey:
            "The App Store Connect private key is not a valid PEM-encoded P-256 (.p8) key"
        }
    }
}
