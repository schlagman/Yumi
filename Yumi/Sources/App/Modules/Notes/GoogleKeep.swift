import AppKit
import CryptoKit
import Foundation
import Network

/// Google Keep, on a Google Workspace account whose administrator allowed Yumi's OAuth client
/// (domain-wide delegation, scope keep): Yumi creates the notes there. The client ID and secret
/// come from that administrator; they and the refresh token live in the Keychain, read by the
/// caller (no Keychain here). Nothing is read back from Keep.
enum GoogleKeep {
    static let clientIDKey = "google-keep-client-id"
    static let clientSecretKey = "google-keep-client-secret"
    static let refreshTokenKey = "google-keep-refresh-token"
    static let scope = "https://www.googleapis.com/auth/keep"
    static let webURL = URL(string: "https://keep.google.com")!

    struct Credentials: Equatable, Sendable {
        var clientID: String
        var clientSecret: String
        var refreshToken: String
    }

    enum Failure: Error, Equatable {
        /// No client ID or secret in the settings.
        case notConfigured
        /// Google said no: consent refused, client not allowed by the administrator, access revoked.
        case refused(String)
        /// Nobody came back from the browser within five minutes.
        case timedOut
    }

    /// The three secrets, when all are there.
    static func credentials(_ read: (String) -> String?) -> Credentials? {
        guard let id = read(clientIDKey)?.nonEmptyTrimmed, let secret = read(clientSecretKey)?.nonEmptyTrimmed,
              let token = read(refreshTokenKey)?.nonEmptyTrimmed else { return nil }
        return Credentials(clientID: id, clientSecret: secret, refreshToken: token)
    }

    // MARK: What is sent

    static func authorizationURL(clientID: String, redirect: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // A refresh token, so the browser is needed only once
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    static func codeExchange(code: String, verifier: String, redirect: String, clientID: String, clientSecret: String) -> URLRequest {
        tokenRequest(["code": code, "code_verifier": verifier, "redirect_uri": redirect, "client_id": clientID,
                      "client_secret": clientSecret, "grant_type": "authorization_code"])
    }

    static func refresh(_ credentials: Credentials) -> URLRequest {
        tokenRequest(["refresh_token": credentials.refreshToken, "client_id": credentials.clientID,
                      "client_secret": credentials.clientSecret, "grant_type": "refresh_token"])
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

    private static func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        return request
    }

    // MARK: PKCE (RFC 7636)

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomString(bytes: Int = 32) -> String {
        base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: What comes back

    /// What the browser brought back to the loopback address: the code, a refusal, or nil for
    /// anything else (the favicon, a request without our `state`).
    static func answer(inRequestLine line: String, state: String) -> Result<String, Failure>? {
        // "GET /?state=…&code=4/0Ab… HTTP/1.1"
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let items = URLComponents(string: String(parts[1]))?.queryItems,
              items.first(where: { $0.name == "state" })?.value == state else { return nil }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty { return .success(code) }
        return .failure(.refused(items.first { $0.name == "error" }?.value ?? "no code"))
    }

    /// Google's own word for a refusal ("invalid_grant", "PERMISSION_DENIED"), never the whole body.
    static func reason(_ data: Data, status: Int) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let word = json?["error"] as? String { return word }
        if let detail = json?["error"] as? [String: Any], let word = detail["status"] as? String { return word }
        return "HTTP \(status)"
    }

    // MARK: The network

    private struct Tokens: Decodable {
        var access_token: String
        var refresh_token: String?
    }

    /// Opens Google's consent page in the browser and waits for it to come back to Yumi.
    /// Returns the refresh token to keep in the Keychain.
    static func signIn(clientID: String, clientSecret: String) async throws -> String {
        let verifier = randomString(), state = randomString(bytes: 16)
        let (code, redirect) = try await LoopbackRedirect.wait(state: state) { redirect in
            let url = authorizationURL(clientID: clientID, redirect: redirect, challenge: challenge(for: verifier), state: state)
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        let data = try await send(codeExchange(code: code, verifier: verifier, redirect: redirect,
                                               clientID: clientID, clientSecret: clientSecret))
        guard let token = try JSONDecoder().decode(Tokens.self, from: data).refresh_token?.nonEmptyTrimmed else {
            throw Failure.refused("no refresh token")
        }
        return token
    }

    /// Creates `text` as a note of the account.
    static func add(_ text: String, with credentials: Credentials) async throws {
        let tokens = try JSONDecoder().decode(Tokens.self, from: try await send(refresh(credentials)))
        _ = try await send(createNote(text, accessToken: tokens.access_token))
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(reason(data, status: status)) }
        return data
    }
}

/// The browser's way back to Yumi: http://127.0.0.1:<port>/, listened to on this Mac only, for one
/// answer or five minutes, then closed.
private enum LoopbackRedirect {
    /// Everything runs on one serial queue: the state below is never touched from two threads.
    private final class Wait: @unchecked Sendable {
        var continuation: CheckedContinuation<(code: String, redirect: String), Error>?
        var redirect = ""

        init(_ continuation: CheckedContinuation<(code: String, redirect: String), Error>) { self.continuation = continuation }

        func finish(_ result: Result<(code: String, redirect: String), Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    static func wait(state expected: String, opening: @escaping @Sendable (String) -> Void) async throws -> (code: String, redirect: String) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "\(AppIdentity.notificationPrefix).keep-sign-in")
        return try await withCheckedThrowingContinuation { continuation in
            let wait = Wait(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    wait.redirect = "http://127.0.0.1:\(port)"
                    opening(wait.redirect)
                case .failed(let error):
                    wait.finish(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                    let answer = GoogleKeep.answer(inRequestLine: line, state: expected)
                    let page: String
                    switch answer {
                    case .success?: page = "C'est fait : Yumi peut écrire dans ton Google Keep. Tu peux fermer cet onglet."
                    case .failure?: page = "Google n'a pas donné l'accès. Reviens dans Yumi pour réessayer."
                    case nil: page = ""
                    }
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
                        + "<!doctype html><meta charset=utf-8><body style=\"font: 15px -apple-system; padding: 40px\">\(page)</body>"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    guard let answer else { return }
                    listener.cancel()
                    wait.finish(answer.map { (code: $0, redirect: wait.redirect) }.mapError { $0 as Error })
                }
            }
            queue.asyncAfter(deadline: .now() + 300) {
                listener.cancel()
                wait.finish(.failure(GoogleKeep.Failure.timedOut))
            }
            listener.start(queue: queue)
        }
    }
}
