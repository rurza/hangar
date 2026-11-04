import Foundation
import Testing
@testable import HangarCore

@Suite struct SecretMaskerTests {
    @Test func masksRawValue() {
        let masker = SecretMasker(secrets: ["hunter2-token"])
        #expect(masker.mask("token is hunter2-token ok") == "token is [masked] ok")
    }

    @Test func masksEachLineOfMultilineSecret() {
        let pem = "-----BEGIN KEY-----\nQUJDREVGR0hJSktM\n-----END KEY-----"
        let masker = SecretMasker(secrets: [pem])
        #expect(masker.mask("QUJDREVGR0hJSktM") == "[masked]")
        #expect(masker.mask("x \(pem) y") == "x [masked] y")
    }

    @Test func multilineHandlesCRLFAndBlankLines() {
        let masker = SecretMasker(secrets: ["line-one-secret\r\n\r\nline-two-secret\r\n"])
        #expect(masker.mask("line-one-secret|line-two-secret") == "[masked]|[masked]")
    }

    @Test func masksPercentEncodedValue() {
        let masker = SecretMasker(secrets: ["p@ss/word"])
        #expect(masker.mask("https://u:p%40ss%2Fword@host/") == "https://u:[masked]@host/")
    }

    @Test func masksBase64Value() {
        let secret = "s3cret-value"
        let b64 = Data(secret.utf8).base64EncodedString()
        let masker = SecretMasker(secrets: [secret])
        #expect(masker.mask("Authorization: Basic \(b64)") == "Authorization: Basic [masked]")
    }

    @Test func ignoresShortSecrets() {
        let masker = SecretMasker(secrets: ["ab"])
        #expect(masker.mask("abc") == "abc")
    }

    @Test func masksLongestFirst() {
        let masker = SecretMasker(secrets: ["abc12345", "abc12345-suffix"])
        #expect(masker.mask("v=abc12345-suffix") == "v=[masked]")
    }

    @Test func emptyMaskerIsIdentity() {
        let masker = SecretMasker(secrets: [])
        #expect(masker.mask("nothing to hide") == "nothing to hide")
    }

    @Test func masksSecretWithTrailingNewline() {
        for secret in ["abcdefgh\n", "abcdefgh\r\n"] {
            #expect(SecretMasker(secrets: [secret]).mask("tok abcdefgh end") == "tok [masked] end")
        }
    }

    @Test func masksUnreservedAndLowercasePercentForms() {
        let masker = SecretMasker(secrets: ["p@ss-word/x y"])
        #expect(masker.mask("a=p%40ss-word%2Fx%20y") == "a=[masked]")
        #expect(masker.mask("a=p%40ss%2dword%2fx%20y") == "a=[masked]")
        #expect(masker.mask("a=p%40ss-word%2Fx+y") == "a=[masked]")
    }

    @Test func masksSecretEmbeddedInBasicAuth() {
        let masker = SecretMasker(secrets: ["tok3n-value"])
        let header = "Authorization: Basic dXNlcjp0b2szbi12YWx1ZQ=="
        #expect(masker.mask(header).contains("[masked]"))
        #expect(!masker.mask("Basic dXNlcjp0b2szbi12YWx1ZQ==").contains("0b2szbi12YWx1"))
    }

    @Test func masksEmbeddedBase64AtEveryOffsetAndUrlSafe() {
        let masker = SecretMasker(secrets: ["tok3n-value?>"])
        for prefix in ["", "a:", "ab:", "abc:"] {
            let b64 = Data((prefix + "tok3n-value?>").utf8).base64EncodedString()
            #expect(masker.mask(b64).contains("tok3n") == false)
            #expect(masker.mask(b64) != b64)
            let url = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            #expect(masker.mask(url) != url)
        }
    }
}
