import Foundation

/// An App Store Connect API key. A team key has an issuer ID; an individual key (tied to one user) has none.
public struct ASCCredentials: Sendable {
    public var keyID: String
    /// Nil for an individual key.
    public var issuerID: String?
    public var privateKeyPEM: String

    public init(keyID: String, issuerID: String?, privateKeyPEM: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPEM = privateKeyPEM
    }
}

/// One upload of a build (`buildUploads`): its state, and App Store Connect's own words when it refused it.
public struct ASCBuildUpload: Sendable, Equatable {
    public struct Issue: Sendable, Equatable {
        /// "90284", as in ITMS-90284.
        public var code: String
        public var description: String

        public init(code: String, description: String) {
            self.code = code
            self.description = description
        }
    }

    public var version: String
    /// IOS, MAC_OS, …
    public var platform: String?
    /// AWAITING_UPLOAD, PROCESSING, FAILED or COMPLETE.
    public var state: String
    public var errors: [Issue]

    public init(version: String, platform: String?, state: String, errors: [Issue] = []) {
        self.version = version
        self.platform = platform
        self.state = state
        self.errors = errors
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

public struct ASCApp: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var bundleID: String

    public init(id: String, name: String, bundleID: String) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
    }
}

public struct ASCBetaGroup: Sendable, Equatable {
    public var id: String
    public var name: String
    public var isInternal: Bool
    /// `hasAccessToAllBuilds`: the group gets every build of the app on its own (an internal group with automatic
    /// distribution). App Store Connect refuses to assign a build to such a group by hand (HTTP 422, "Builds cannot
    /// be assigned to this internal group").
    public var receivesEveryBuild: Bool

    public init(id: String, name: String, isInternal: Bool, receivesEveryBuild: Bool = false) {
        self.id = id
        self.name = name
        self.isInternal = isInternal
        self.receivesEveryBuild = receivesEveryBuild
    }
}

/// TestFlight's test information in one locale. External beta review needs a `description` (the Beta App
/// Description) in at least one.
public struct ASCBetaAppLocalization: Sendable, Equatable {
    public var locale: String
    public var description: String?

    public init(locale: String, description: String?) {
        self.locale = locale
        self.description = description
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

extension ASCError {
    /// What App Store Connect said when it refused a request: the `detail` (else `title`) of each entry of its
    /// JSON:API `errors`, joined; nil for any other error or a body that is not such a list.
    public var refusalDetail: String? {
        struct Body: Decodable {
            struct Entry: Decodable {
                var title: String?
                var detail: String?
            }
            var errors: [Entry]
        }
        guard case .http(_, let text) = self,
            let body = try? JSONDecoder().decode(Body.self, from: Data(text.utf8))
        else { return nil }
        let parts = body.errors.compactMap { entry in
            [entry.detail, entry.title].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// `certificateType` of `POST /v1/certificates`. `DEVELOPMENT` is the "Apple Development" certificate that signs
/// development builds of every platform (the API has no `APPLE_DEVELOPMENT`); the per-platform types are legacy.
public enum ASCCertificateType: String, Sendable, Codable {
    case development = "DEVELOPMENT"
}

/// A certificate App Store Connect created; `content` is the DER certificate (no private key: that never leaves
/// the server that made the request).
public struct ASCCertificate: Sendable, Equatable {
    public var id: String
    public var serialNumber: String?
    public var name: String?
    public var expirationDate: Date?
    public var content: Data

    public init(id: String, serialNumber: String?, name: String?, expirationDate: Date?, content: Data) {
        self.id = id
        self.serialNumber = serialNumber
        self.name = name
        self.expirationDate = expirationDate
        self.content = content
    }
}

/// The development profile types Hangar reads and creates. Distribution types are deliberately absent: Hangar never
/// reads, creates or changes a distribution profile (exports are signed by Apple's cloud-managed signing).
public enum ASCDevelopmentProfileType: String, Sendable, Codable, CaseIterable {
    case iOS = "IOS_APP_DEVELOPMENT"
    case macOS = "MAC_APP_DEVELOPMENT"
    case tvOS = "TVOS_APP_DEVELOPMENT"

    /// The device platform (`/v1/devices` `filter[platform]`) whose devices a profile of this type lists.
    public var devicePlatform: String {
        switch self {
        case .iOS, .tvOS: "IOS"
        case .macOS: "MAC_OS"
        }
    }

    /// The bundle ID platforms (`IOS`, `MAC_OS`, `UNIVERSAL`) a profile of this type can be made for.
    public var bundleIDPlatforms: Set<String> {
        switch self {
        case .iOS, .tvOS: ["IOS", "UNIVERSAL"]
        case .macOS: ["MAC_OS", "UNIVERSAL"]
        }
    }
}

/// A registered bundle ID (`/v1/bundleIds`): `id` is App Store Connect's resource ID, `identifier` the bundle ID.
public struct ASCBundleIdentifier: Sendable, Equatable {
    public var id: String
    public var identifier: String
    public var platform: String

    public init(id: String, identifier: String, platform: String) {
        self.id = id
        self.identifier = identifier
        self.platform = platform
    }
}

/// A development provisioning profile and what it is for. `content` is the signed `.mobileprovision` or
/// `.provisionprofile` file; it holds no private key.
public struct ASCProfile: Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: ASCDevelopmentProfileType
    public var uuid: String
    public var content: Data
    public var expirationDate: Date?
    /// The bundle ID's resource ID.
    public var bundleIDResourceID: String?
    public var certificateIDs: [String]

    public init(
        id: String, name: String, type: ASCDevelopmentProfileType, uuid: String, content: Data, expirationDate: Date?,
        bundleIDResourceID: String?, certificateIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.uuid = uuid
        self.content = content
        self.expirationDate = expirationDate
        self.bundleIDResourceID = bundleIDResourceID
        self.certificateIDs = certificateIDs
    }
}
