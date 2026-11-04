import CryptoKit
import Foundation

public enum ASCJWT {
    /// ES256 token for the App Store Connect API (signature in raw r||s form, base64url without padding).
    public static func token(_ c: ASCCredentials, now: Date, lifetime: TimeInterval = 1200) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: c.privateKeyPEM)
        } catch {
            throw ASCError.invalidPrivateKey
        }
        let issuedAt = Int(now.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(["alg": "ES256", "kid": c.keyID, "typ": "JWT"])
        struct Claims: Encodable {
            var iss: String
            var iat: Int
            var exp: Int
            var aud: String
        }
        let claims = try encoder.encode(
            Claims(iss: c.issuerID, iat: issuedAt, exp: issuedAt + Int(lifetime), aud: "appstoreconnect-v1"))
        let signingInput = base64URL(header) + "." + base64URL(claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
