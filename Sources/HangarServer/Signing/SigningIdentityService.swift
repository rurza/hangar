import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging

/// The server's one Apple Development identity, which every VM archive signs with (VM builds design, *Signing*).
///
/// Hangar creates a certificate only when the owner asks (Settings › Signing, `hangar signing create`), never from a
/// job, a worker or an MCP tool, and at most once:
/// - a valid identity refuses another (409 `signing_identity_exists`) until it is within 30 days of expiring;
/// - renewing creates the new certificate, switches to it, then revokes the old one only if Hangar created it, by
///   the App Store Connect ID it stored, never any other certificate;
/// - whatever happens, at most one certificate per 24 hours (429 `signing_rate_limited`).
/// Importing a `.p12` the owner already has creates nothing at Apple.
public actor SigningIdentityService {
    public static let renewalWindow: TimeInterval = TimeInterval(SigningStatus.renewalWindowDays) * 86_400
    public static let creationInterval: TimeInterval = 86_400

    nonisolated let repository: SigningIdentityRepository
    let crypto: SigningCrypto
    /// The configured App Store Connect key, nil when there is none; read on every use.
    let credentials: @Sendable () throws -> ASCCredentials?
    let factory: @Sendable (ASCCredentials) -> any AppStoreConnectClient
    let now: @Sendable () -> Date
    private let logger = Logger(label: "app.hangar.server.signing")
    /// Set while a create, import or remove runs: the actor is reentrant across its awaits, so a second request
    /// would otherwise see the identity as it was before the first one finished.
    private var busy = false

    init(
        repository: SigningIdentityRepository, crypto: SigningCrypto,
        credentials: @escaping @Sendable () throws -> ASCCredentials?,
        factory: @escaping @Sendable (ASCCredentials) -> any AppStoreConnectClient, now: @escaping @Sendable () -> Date
    ) {
        self.repository = repository
        self.crypto = crypto
        self.credentials = credentials
        self.factory = factory
        self.now = now
    }

    // MARK: Reading

    public nonisolated func status() throws -> SigningStatus {
        Self.status(info: try repository.info(), lastCreation: try repository.lastCreation(), now: now())
    }

    static func status(info: SigningIdentityInfo?, lastCreation: Date?, now: Date) -> SigningStatus {
        let state: SigningStatus.State
        if let info {
            if info.expiresAt <= now { state = .expired }
            else if info.expiresAt.timeIntervalSince(now) <= renewalWindow { state = .expiring }
            else { state = .active }
        } else {
            state = .none
        }
        let next = lastCreation.map { $0.addingTimeInterval(creationInterval) }.flatMap { $0 > now ? $0 : nil }
        var blocked: String?
        if state == .active, let info {
            blocked = "Hangar's signing certificate is valid until \(day(info.expiresAt)); it can be renewed from \(day(info.expiresAt.addingTimeInterval(-renewalWindow)))."
        } else if let next {
            blocked = "Hangar created a certificate less than 24 hours ago; the next one is possible from \(time(next))."
        }
        return SigningStatus(
            state: state, identity: info, canCreate: blocked == nil, createBlockedReason: blocked, nextCreationAt: next)
    }

    /// Why a VM archive cannot sign with the server's identity right now; nil when it can.
    public nonisolated func jobProblem() -> String? {
        guard let info = try? repository.info() else {
            return "Hangar has no signing certificate for VM archives: create or import one in Settings › Signing"
        }
        if info.expiresAt <= now() {
            return "Hangar's signing certificate expired on \(Self.day(info.expiresAt)): renew it in Settings › Signing"
        }
        return nil
    }

    /// The identity for a VM archive's assignment; nil when there is none or it has expired.
    public nonisolated func jobIdentity() throws -> JobSigningIdentity? {
        guard let info = try repository.info(), info.expiresAt > now() else { return nil }
        return try repository.identity()
    }

    // MARK: Changing

    /// Create or Renew: one `DEVELOPMENT` certificate through App Store Connect. The only path that creates one.
    public func create() async throws -> SigningCreateResponse {
        try begin()
        defer { busy = false }
        let started = now()
        let existing = try repository.info()
        let current = Self.status(info: existing, lastCreation: try repository.lastCreation(), now: started)
        if current.state == .active {
            throw APIError(code: "signing_identity_exists", message: current.createBlockedReason ?? "Hangar already has a signing certificate.")
        }
        if current.nextCreationAt != nil {
            throw APIError(code: "signing_rate_limited", message: current.createBlockedReason ?? "Try again tomorrow.")
        }
        guard let credentials = try credentials() else {
            throw APIError(code: "asc_not_configured", message: "Set the App Store Connect key in Settings first.")
        }
        guard credentials.issuerID != nil else {
            throw APIError(
                code: "team_key_required",
                message: "Creating a certificate needs a team App Store Connect key (with an issuer ID): individual keys cannot manage certificates.")
        }
        let client = factory(credentials)

        let (workspace, csr) = try await crypto.makeKeyAndCSR()
        defer { workspace.remove() }
        // Recorded before asking: if the answer is lost, the guard still counts the certificate that may exist.
        let creation = try repository.recordCreation(at: started)
        let certificate: ASCCertificate
        do {
            certificate = try await client.createCertificate(type: .development, csrPEM: csr)
        } catch ASCError.http(let status, let body) where (400..<500).contains(status) {
            // A definite refusal: nothing was created.
            try? repository.forgetCreation(creation)
            throw APIError(code: "asc_refused", message: "App Store Connect refused to create the certificate (HTTP \(status)): \(Self.detail(body))")
        }
        try repository.setCreationCertificate(creation, ascCertificateID: certificate.id)
        logger.notice("App Store Connect created development certificate \(certificate.id)")

        let facts = try CertificateFacts(der: certificate.content)
        let identity = try await crypto.makeP12(workspace, certificate: certificate.content, friendlyName: facts.commonName)
        let info = SigningIdentityInfo(
            name: facts.commonName, teamID: facts.teamID, serialNumber: certificate.serialNumber ?? facts.serialNumber,
            expiresAt: facts.notAfter, createdAt: started, origin: .created, ascCertificateID: certificate.id)
        try repository.save(identity, info: info)

        // The switch is done; now the old certificate, only if Hangar made it, by its own stored ID.
        var revoked: String?
        var revokeProblem: String?
        if let old = existing, old.origin == .created, let oldID = old.ascCertificateID, oldID != certificate.id {
            do {
                try await client.revokeCertificate(id: oldID)
                revoked = oldID
                logger.notice("revoked the previous Hangar development certificate \(oldID)")
            } catch {
                revokeProblem = "The old certificate (\(oldID)) could not be revoked: \(error). It stays valid until \(Self.day(old.expiresAt)); revoke it in the Apple Developer website if you like."
                logger.warning("could not revoke the previous Hangar development certificate \(oldID): \(error)")
            }
        }
        return SigningCreateResponse(status: try status(), revokedCertificateID: revoked, revokeProblem: revokeProblem)
    }

    /// Adopts an identity the owner already has. Creates nothing at Apple and never revokes it later.
    public func importIdentity(p12: Data, password: String) async throws -> SigningStatus {
        try begin()
        defer { busy = false }
        if let existing = try repository.info() {
            throw APIError(
                code: "signing_identity_exists",
                message: "Hangar already has a signing certificate (\(existing.name)). Remove it first to use another.")
        }
        guard !p12.isEmpty, p12.count <= 64 * 1024 else {
            throw APIError(code: "invalid_identity", message: "Choose a .p12 file exported from Keychain Access.")
        }
        let identity: JobSigningIdentity
        let facts: CertificateFacts
        do {
            let (repacked, certificate) = try await crypto.repack(p12: p12, password: password)
            identity = repacked
            facts = try CertificateFacts(der: certificate)
        } catch let error as SigningCryptoError {
            throw APIError(code: "invalid_identity", message: error.description)
        }
        guard facts.isDevelopment else {
            throw APIError(
                code: "invalid_identity",
                message: "“\(facts.commonName)” is not an Apple Development certificate. Distribution signing stays with App Store Connect.")
        }
        guard facts.notAfter > now() else {
            throw APIError(code: "invalid_identity", message: "This certificate expired on \(Self.day(facts.notAfter)).")
        }
        try repository.save(
            identity,
            info: SigningIdentityInfo(
                name: facts.commonName, teamID: facts.teamID, serialNumber: facts.serialNumber, expiresAt: facts.notAfter,
                createdAt: now(), origin: .imported))
        logger.notice("imported a development identity: \(facts.commonName)")
        return try status()
    }

    /// Deletes the stored copy. Revokes nothing: the certificate stays valid at Apple.
    public func remove() throws -> SigningStatus {
        try begin()
        defer { busy = false }
        if try repository.remove() { logger.notice("removed the stored signing identity (not revoked)") }
        return try status()
    }

    private func begin() throws {
        guard !busy else {
            throw APIError(code: "signing_busy", message: "Another change to the signing certificate is in progress.")
        }
        busy = true
    }

    // MARK: Copy

    /// App Store Connect's first error detail, else its body, shortened.
    static func detail(_ body: String) -> String {
        struct Errors: Decodable {
            struct Item: Decodable { var detail: String? }
            var errors: [Item]
        }
        let text = (try? JSONDecoder().decode(Errors.self, from: Data(body.utf8)))?.errors.first?.detail ?? body
        return String(text.prefix(300))
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy, HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
