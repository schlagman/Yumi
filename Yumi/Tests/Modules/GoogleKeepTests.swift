import Testing
import Foundation
import Security

@Suite struct GoogleKeepTests {
    /// A throwaway RSA key, written as Google writes it in a service account's JSON: PEM, PKCS#8.
    private static func serviceAccountKey() throws -> (pem: String, publicKey: SecKey) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let rsa = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        // PrivateKeyInfo: version 0, rsaEncryption, then the RSA key in an OCTET STRING
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let info = der(0x30, [0x02, 0x01, 0x00] + algorithm + der(0x04, [UInt8](rsa)))
        let pem = "-----BEGIN PRIVATE KEY-----\n" + Data(info).base64EncodedString(options: .lineLength64Characters)
            + "\n-----END PRIVATE KEY-----\n"
        return (pem, try #require(SecKeyCopyPublicKey(key)))
    }

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let n = content.count
        let length: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
        return [tag] + length + content
    }

    private func base64URL(_ part: Substring) -> Data? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    @Test func needsAllThreeValues() {
        let all = [GoogleKeep.serviceAccountKey: "yumi@p.iam.gserviceaccount.com", GoogleKeep.privateKeyKey: "pem",
                   GoogleKeep.userKey: "julien@example.com"]
        #expect(GoogleKeep.credentials { all[$0] } == GoogleKeep.Credentials(serviceAccount: "yumi@p.iam.gserviceaccount.com",
                                                                              privateKey: "pem", user: "julien@example.com"))
        var missing = all
        missing[GoogleKeep.userKey] = " "
        #expect(GoogleKeep.credentials { missing[$0] } == nil)
    }

    @Test func readsOnlyAServiceAccountFile() throws {
        let file = #"{"type": "service_account", "project_id": "p", "client_email": "yumi@p.iam.gserviceaccount.com", "private_key": "-----BEGIN PRIVATE KEY-----\nAB\n-----END PRIVATE KEY-----\n"}"#
        let key = try GoogleKeep.serviceAccount(fromJSON: Data(file.utf8))
        #expect(key.email == "yumi@p.iam.gserviceaccount.com")
        #expect(key.privateKey == "-----BEGIN PRIVATE KEY-----\nAB\n-----END PRIVATE KEY-----\n")
        // An OAuth client's file, or anything else, is not one
        #expect(throws: GoogleKeep.Failure.badKey) {
            try GoogleKeep.serviceAccount(fromJSON: Data(#"{"installed": {"client_id": "x"}}"#.utf8))
        }
        #expect(throws: GoogleKeep.Failure.badKey) { try GoogleKeep.serviceAccount(fromJSON: Data("nope".utf8)) }
    }

    @Test func asksInThePersonsNameWithASignatureOfTheAccountKey() throws {
        let (pem, publicKey) = try Self.serviceAccountKey()
        let credentials = GoogleKeep.Credentials(serviceAccount: "yumi@p.iam.gserviceaccount.com", privateKey: pem, user: "julien@example.com")
        let request = try GoogleKeep.tokenRequest(credentials, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token" && request.httpMethod == "POST")

        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let prefix = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="
        #expect(body.hasPrefix(prefix))
        let parts = body.dropFirst(prefix.count).split(separator: ".")
        try #require(parts.count == 3)

        let header = try #require(base64URL(parts[0]).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(header == ["alg": "RS256", "typ": "JWT"])
        let claims = try #require(base64URL(parts[1]).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(claims["iss"] as? String == "yumi@p.iam.gserviceaccount.com")
        #expect(claims["sub"] as? String == "julien@example.com")
        #expect(claims["scope"] as? String == "https://www.googleapis.com/auth/keep")
        #expect(claims["aud"] as? String == "https://oauth2.googleapis.com/token")
        #expect(claims["iat"] as? Int == 1_800_000_000 && claims["exp"] as? Int == 1_800_003_600)

        let signature = try #require(base64URL(parts[2]))
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                                      signature as CFData, nil))
    }

    @Test func aKeyThatDoesNotReadIsSaidSo() {
        #expect(throws: GoogleKeep.Failure.badKey) {
            try GoogleKeep.privateKey(pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")
        }
        // Cut short, or another structure
        #expect(GoogleKeep.pkcs1(fromPKCS8: Data([0x30, 0x82, 0x04, 0xbd, 0x02])) == nil)
        #expect(GoogleKeep.pkcs1(fromPKCS8: Data([0x04, 0x01, 0x00])) == nil)
    }

    @Test func createsANoteWithItsTextOnly() throws {
        let request = GoogleKeep.createNote("Appeler Paul\nà 14 h", accessToken: "ya29.x")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://keep.googleapis.com/v1/notes")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.x")
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let text = ((json["body"] as? [String: Any])?["text"] as? [String: Any])?["text"] as? String
        #expect(text == "Appeler Paul\nà 14 h")
        #expect(Set(json.keys) == ["body"])
    }

    @Test func saysGooglesWordNotItsBody() {
        #expect(GoogleKeep.reason(Data(#"{"error": "unauthorized_client", "error_description": "Bad"}"#.utf8), status: 401) == "unauthorized_client")
        #expect(GoogleKeep.reason(Data(#"{"error": {"code": 403, "status": "PERMISSION_DENIED"}}"#.utf8), status: 403) == "PERMISSION_DENIED")
        #expect(GoogleKeep.reason(Data("<html>".utf8), status: 502) == "HTTP 502")
    }
}
