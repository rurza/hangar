import Foundation
import HangarCore
import Security

/// The key, CSR and PKCS#12 work behind the server's signing identity. The private key is made in process (Security
/// framework, not stored in any keychain); `/usr/bin/openssl` (LibreSSL) builds the CSR and the `.p12`. Secrets reach
/// it only through 0600 files in a private 0700 directory, or on standard input (`-passin stdin`, `-passout stdin`),
/// never on its command line; the directory is deleted when the work is done.
///
/// The `.p12` is LibreSSL's default (3DES, SHA-1 MAC), which `security import` in every macOS guest reads.
struct SigningCrypto: Sendable {
    static let openssl = "/usr/bin/openssl"

    let runner: any ProcessRunner
    /// Where the private work directories are made: the server's data directory, never a shared temp.
    let workParent: String

    init(runner: any ProcessRunner = LiveProcessRunner(), workParent: String) {
        self.runner = runner
        self.workParent = workParent
    }

    /// A new RSA 2048 key, in a work directory, and a CSR for it. The caller deletes the workspace.
    func makeKeyAndCSR() async throws -> (SigningWorkspace, csrPEM: String) {
        let workspace = try SigningWorkspace(parent: workParent)
        do {
            try workspace.write(try Self.newPrivateKeyPEM(), to: workspace.key)
            // Apple replaces the subject; this one only has to be well formed.
            let csr = try await output(
                ["req", "-new", "-sha256", "-key", workspace.key, "-subj", "/CN=Hangar/C=US"], what: "make the certificate request")
            guard csr.contains("BEGIN CERTIFICATE REQUEST") else { throw SigningCryptoError.failed("make the certificate request") }
            return (workspace, csr)
        } catch {
            workspace.remove()
            throw error
        }
    }

    /// The `.p12` of the workspace's key and `certificate` (DER), under a new random password.
    func makeP12(_ workspace: SigningWorkspace, certificate: Data, friendlyName: String) async throws -> JobSigningIdentity {
        try workspace.write(Data(Self.pem(certificate, label: "CERTIFICATE").utf8), to: workspace.certificate)
        let password = Self.randomPassword()
        try workspace.write(Data(), to: workspace.p12)
        try await require(
            ["pkcs12", "-export", "-inkey", workspace.key, "-in", workspace.certificate, "-name", friendlyName,
             "-passout", "stdin", "-out", workspace.p12],
            input: password, what: "build the .p12")
        guard let p12 = FileManager.default.contents(atPath: workspace.p12), !p12.isEmpty else {
            throw SigningCryptoError.failed("build the .p12")
        }
        return JobSigningIdentity(p12: p12, password: password)
    }

    /// Opens an owner's `.p12`: its certificate and key, checked to belong together, then packed again as a `.p12`
    /// under a new random password, so the owner's password is not kept and every stored identity is alike.
    func repack(p12: Data, password: String) async throws -> (JobSigningIdentity, certificate: Data) {
        guard !password.contains(where: \.isNewline) else { throw SigningCryptoError.wrongPassword }
        let workspace = try SigningWorkspace(parent: workParent)
        defer { workspace.remove() }
        let source = workspace.directory + "/source.p12"
        try workspace.write(p12, to: source)
        let certificatePEM: String
        do {
            certificatePEM = try await output(
                ["pkcs12", "-in", source, "-clcerts", "-nokeys", "-passin", "stdin"], input: password, what: "open the .p12")
        } catch SigningCryptoError.failed {
            throw SigningCryptoError.wrongPassword
        }
        guard let certificate = Self.firstPEMBlock(certificatePEM, label: "CERTIFICATE") else { throw SigningCryptoError.noCertificate }
        try workspace.write(Data(), to: workspace.key)
        try await require(
            ["pkcs12", "-in", source, "-nocerts", "-nodes", "-passin", "stdin", "-out", workspace.key],
            input: password, what: "read the .p12's private key")
        guard let key = FileManager.default.contents(atPath: workspace.key),
            String(decoding: key, as: UTF8.self).contains("PRIVATE KEY")
        else { throw SigningCryptoError.noPrivateKey }
        try workspace.write(Data(Self.pem(certificate, label: "CERTIFICATE").utf8), to: workspace.certificate)
        let keyPublic = try await output(["pkey", "-in", workspace.key, "-pubout"], what: "read the key")
        let certificatePublic = try await output(["x509", "-in", workspace.certificate, "-pubkey", "-noout"], what: "read the certificate")
        guard Self.firstPEMBlock(keyPublic, label: "PUBLIC KEY") == Self.firstPEMBlock(certificatePublic, label: "PUBLIC KEY") else {
            throw SigningCryptoError.keyMismatch
        }
        let name = (try? CertificateFacts(der: certificate).commonName) ?? "Apple Development"
        return (try await makeP12(workspace, certificate: certificate, friendlyName: name), certificate)
    }

    // MARK: Plumbing

    private func output(_ arguments: [String], input: String? = nil, what: String) async throws -> String {
        let outcome = try await runner.run(command(arguments, input: input), onLine: { _ in })
        guard outcome.exitCode == 0 else { throw SigningCryptoError.failed(what) }
        return outcome.output
    }

    private func require(_ arguments: [String], input: String? = nil, what: String) async throws {
        _ = try await output(arguments, input: input, what: what)
    }

    /// Standard error is dropped: LibreSSL prints "MAC verified OK" there, and stdout is parsed.
    private func command(_ arguments: [String], input: String?) -> ProcessCommand {
        ProcessCommand(
            executable: Self.openssl, arguments: arguments, environment: ["PATH": "/usr/bin:/bin"],
            discardsStandardError: true, standardInput: input.map { SensitiveText($0 + "\n") })
    }

    /// RSA 2048 from the Security framework, never added to a keychain; PKCS#1 PEM.
    static func newPrivateKeyPEM() throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
            let der = SecKeyCopyExternalRepresentation(key, &error) as Data?
        else { throw SigningCryptoError.failed("make the private key") }
        return Data(pem(der, label: "RSA PRIVATE KEY").utf8)
    }

    /// 32 random bytes, base64url: the stored `.p12`'s password.
    static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }

    /// The DER of the first `label` block in `text`.
    static func firstPEMBlock(_ text: String, label: String) -> Data? {
        guard let start = text.range(of: "-----BEGIN \(label)-----"),
            let end = text.range(of: "-----END \(label)-----", range: start.upperBound..<text.endIndex)
        else { return nil }
        let body = text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(body))
    }
}

/// A private directory for one piece of signing work: 0700, under the server's data directory, deleted afterwards.
struct SigningWorkspace: Sendable {
    let directory: String
    var key: String { directory + "/key.pem" }
    var certificate: String { directory + "/certificate.pem" }
    var p12: String { directory + "/identity.p12" }

    init(parent: String) throws {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        directory = parent + "/.signing-\(UUID().uuidString)"
        guard mkdir(directory, 0o700) == 0 else { throw SigningCryptoError.failed("make a private work directory") }
    }

    /// Writes `data` 0600, without following a symlink; openssl's `-out` keeps the mode of a file that exists.
    func write(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SigningCryptoError.failed("write a work file") }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SigningCryptoError.failed("write a work file") }
        let written = data.withUnsafeBytes { buffer in
            buffer.count == 0 ? 0 : Foundation.write(descriptor, buffer.baseAddress!, buffer.count)
        }
        guard written == data.count else { throw SigningCryptoError.failed("write a work file") }
    }

    func remove() { try? FileManager.default.removeItem(atPath: directory) }

    /// Deletes what a server that stopped in the middle of signing work left behind.
    static func sweep(parent: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        for name in names where name.hasPrefix(".signing-") {
            try? FileManager.default.removeItem(atPath: parent + "/" + name)
        }
    }
}

enum SigningCryptoError: Error, Equatable, CustomStringConvertible {
    /// What could not be done; never carries key material, passwords or tool output.
    case failed(String)
    case wrongPassword
    case noCertificate
    case noPrivateKey
    case keyMismatch
    case unreadableCertificate

    var description: String {
        switch self {
        case .failed(let what): "Could not \(what)."
        case .wrongPassword: "The password does not open this .p12."
        case .noCertificate: "The .p12 holds no certificate."
        case .noPrivateKey: "The .p12 holds no private key: export the identity (certificate and key), not just the certificate."
        case .keyMismatch: "The .p12's private key does not belong to its certificate."
        case .unreadableCertificate: "The certificate cannot be read."
        }
    }
}

/// What a certificate says about itself, read with the Security framework (no keychain involved).
struct CertificateFacts: Equatable, Sendable {
    var commonName: String
    var teamID: String?
    /// Upper-case hex, no separators.
    var serialNumber: String
    var notAfter: Date

    init(der: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw SigningCryptoError.unreadableCertificate
        }
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        guard let commonName = name as String? else { throw SigningCryptoError.unreadableCertificate }
        self.commonName = commonName
        var error: Unmanaged<CFError>?
        guard let serial = SecCertificateCopySerialNumberData(certificate, &error) as Data? else {
            throw SigningCryptoError.unreadableCertificate
        }
        serialNumber = serial.map { String(format: "%02X", $0) }.joined()
        let keys = [kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1SubjectName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]],
            let notAfter = (values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue
        else { throw SigningCryptoError.unreadableCertificate }
        self.notAfter = Date(timeIntervalSinceReferenceDate: notAfter)
        let subject = values[kSecOIDX509V1SubjectName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        teamID = subject.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationalUnitName as String) }?[
            kSecPropertyKeyValue as String] as? String
    }

    /// An Apple Development certificate, or one of its predecessors.
    var isDevelopment: Bool {
        ["Apple Development:", "iPhone Developer:", "Mac Developer:"].contains { commonName.hasPrefix($0) }
    }
}
