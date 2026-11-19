import Foundation
import Security

/// Google Keep, on a Google Workspace account. Google lets no one open Keep to an app by
/// themselves: only an administrator can, through a service account allowed for the domain
/// (domain-wide delegation, scope keep). Yumi signs in as that account on behalf of the
/// person's address and creates the notes there. The account's address and private key, and
/// the person's address, live in the Keychain, read by the caller (no Keychain here). Nothing
/// is read back from Keep.
enum GoogleKeep {
    static let serviceAccountKey = "google-keep-service-account"
    static let privateKeyKey = "google-keep-private-key"
    static let userKey = "google-keep-user"
    static let scope = "https://www.googleapis.com/auth/keep"
    static let webURL = URL(string: "https://keep.google.com")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    struct Credentials: Equatable, Sendable {
        /// "yumi@projet.iam.gserviceaccount.com"
        var serviceAccount: String
        /// PEM, PKCS#8, as Google gives it in the account's JSON key.
        var privateKey: String
        /// The person whose Keep receives the notes.
        var user: String
    }

    enum Failure: Error, Equatable {
        /// Not a service account's JSON key, or a private key that does not read.
        case badKey
        /// Google said no: the account is not allowed for Keep, the key was revoked, the address is wrong.
        case refused(String)
    }

    /// The three values, when all are there.
    static func credentials(_ read: (String) -> String?) -> Credentials? {
        guard let account = read(serviceAccountKey)?.nonEmptyTrimmed, let key = read(privateKeyKey)?.nonEmptyTrimmed,
              let user = read(userKey)?.nonEmptyTrimmed else { return nil }
        return Credentials(serviceAccount: account, privateKey: key, user: user)
    }

    /// The address and private key in a service account's JSON key file.
    static func serviceAccount(fromJSON data: Data) throws -> (email: String, privateKey: String) {
        struct File: Decodable { var type: String; var client_email: String; var private_key: String }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.type == "service_account" else {
            throw Failure.badKey
        }
        return (file.client_email, file.private_key)
    }

    // MARK: What is sent

    /// The account asks for an access token in the person's name (RFC 7523), signed with its key.
    static func tokenRequest(_ credentials: Credentials, now: Date = Date()) throws -> URLRequest {
        let jwt = try assertion(credentials, now: now)
        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // A JWT is made of letters, digits, "-", "_" and ".": nothing to encode
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)".utf8)
        return request
    }

    static func assertion(_ credentials: Credentials, now: Date) throws -> String {
        struct Claims: Encodable { var iss, sub, scope, aud: String; var iat, exp: Int }
        let issued = Int(now.timeIntervalSince1970)
        let claims = try JSONEncoder().encode(Claims(iss: credentials.serviceAccount, sub: credentials.user, scope: scope,
                                                     aud: tokenURL.absoluteString, iat: issued, exp: issued + 3600))
        let key = try privateKey(pem: credentials.privateKey)
        let signed = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)) + "." + base64URL(claims)
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil) as Data? else {
            throw Failure.badKey
        }
        return signed + "." + base64URL(signature)
    }

    /// A note with only a text: Keep shows it as it was typed.
    static func createNote(_ text: String, accessToken: String) -> URLRequest {
        struct Note: Encodable {
            struct Body: Encodable { struct Text: Encodable { var text: String }; var text: Text }
            var body: Body
        }
        var request = URLRequest(url: URL(string: "https://keep.googleapis.com/v1/notes")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(Note(body: .init(text: .init(text: text))))
        return request
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: The key

    /// The RSA key of a PEM "PRIVATE KEY". The Security framework reads only the RSA key itself
    /// (PKCS#1), so the PKCS#8 wrapper is taken off first.
    static func privateKey(pem: String) throws -> SecKey {
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64), let rsa = pkcs1(fromPKCS8: der) else { throw Failure.badKey }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(rsa as CFData, attributes as CFDictionary, nil) else { throw Failure.badKey }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }:
    /// the content of the OCTET STRING.
    static func pkcs1(fromPKCS8 der: Data) -> Data? {
        var reader = DERReader(bytes: [UInt8](der))
        guard reader.enter(0x30), reader.skip(0x02), reader.skip(0x30), let key = reader.read(0x04) else { return nil }
        return Data(key)
    }

    private struct DERReader {
        let bytes: [UInt8]
        var at = 0

        /// Moves past the header of the element at `at` when its tag is `tag`: its length.
        mutating func header(_ tag: UInt8) -> Int? {
            guard at + 1 < bytes.count, bytes[at] == tag else { return nil }
            var length = Int(bytes[at + 1])
            at += 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), at + count <= bytes.count else { return nil }
                length = bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
                at += count
            }
            return at + length <= bytes.count ? length : nil
        }

        mutating func enter(_ tag: UInt8) -> Bool { header(tag) != nil }

        mutating func skip(_ tag: UInt8) -> Bool {
            guard let length = header(tag) else { return false }
            at += length
            return true
        }

        mutating func read(_ tag: UInt8) -> ArraySlice<UInt8>? {
            guard let length = header(tag) else { return nil }
            defer { at += length }
            return bytes[at..<at + length]
        }
    }

    // MARK: What comes back

    /// Google's own word for a refusal ("unauthorized_client", "PERMISSION_DENIED"), never the whole body.
    static func reason(_ data: Data, status: Int) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let word = json?["error"] as? String { return word }
        if let detail = json?["error"] as? [String: Any], let word = detail["status"] as? String { return word }
        return "HTTP \(status)"
    }

    // MARK: The network

    private struct Token: Decodable { var access_token: String }

    /// Asks Google for an access token, and nothing else: whether the administrator allowed the account.
    static func check(_ credentials: Credentials) async throws {
        _ = try await send(tokenRequest(credentials))
    }

    /// Creates `text` as a note of the person's Keep.
    static func add(_ text: String, with credentials: Credentials) async throws {
        let token = try JSONDecoder().decode(Token.self, from: try await send(tokenRequest(credentials)))
        _ = try await send(createNote(text, accessToken: token.access_token))
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(reason(data, status: status)) }
        return data
    }
}
