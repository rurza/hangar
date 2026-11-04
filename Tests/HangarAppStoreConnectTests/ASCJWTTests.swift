import CryptoKit
import Foundation
import Testing

@testable import HangarAppStoreConnect

struct ASCJWTTests {
    private func decodeSegment(_ segment: Substring) -> Data {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)!
    }

    @Test func producesVerifiableES256Token() throws {
        let key = P256.Signing.PrivateKey()
        let credentials = ASCCredentials(keyID: "KEY123", issuerID: "issuer-uuid", privateKeyPEM: key.pemRepresentation)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let token = try ASCJWT.token(credentials, now: now)

        #expect(!token.contains("=") && !token.contains("+") && !token.contains("/"))
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        let signature = decodeSegment(parts[2])
        #expect(signature.count == 64)  // raw r||s, not DER
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        #expect(key.publicKey.isValidSignature(ecdsa, for: Data("\(parts[0]).\(parts[1])".utf8)))

        let header = try #require(try JSONSerialization.jsonObject(with: decodeSegment(parts[0])) as? [String: Any])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEY123")
        #expect(header["typ"] as? String == "JWT")
        let claims = try #require(try JSONSerialization.jsonObject(with: decodeSegment(parts[1])) as? [String: Any])
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
        #expect(claims["iss"] as? String == "issuer-uuid")
        let iat = try #require(claims["iat"] as? Int)
        let exp = try #require(claims["exp"] as? Int)
        // Backdated 60 s against clock skew; exp is iat plus the 1200 s lifetime, so now + 1140.
        #expect(iat == 1_800_000_000 - 60)
        #expect(exp == 1_800_000_000 + 1140)
        #expect(ASCJWT.expiry(now: now, lifetime: 1200) == Date(timeIntervalSince1970: 1_800_000_000 + 1140))
    }

    @Test func invalidKeyThrowsWithoutEchoingIt() {
        let secret = "-----BEGIN PRIVATE KEY-----\nTOPSECRETMATERIAL\n-----END PRIVATE KEY-----"
        let credentials = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: secret)
        do {
            _ = try ASCJWT.token(credentials, now: Date())
            Issue.record("expected an error")
        } catch let error as ASCError {
            #expect(error == .invalidPrivateKey)
            #expect(!"\(error)".contains("TOPSECRETMATERIAL"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
