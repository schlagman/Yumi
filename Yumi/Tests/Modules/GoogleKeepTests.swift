import Testing
import Foundation

@Suite struct GoogleKeepTests {
    private let credentials = GoogleKeep.Credentials(clientID: "123.apps.googleusercontent.com", clientSecret: "GOCSPX-a+b",
                                                     refreshToken: "1//0g-token")

    private func form(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1].removingPercentEncoding ?? "" : "")
        })
    }

    @Test func needsAllThreeSecrets() {
        let all = [GoogleKeep.clientIDKey: "id", GoogleKeep.clientSecretKey: "secret", GoogleKeep.refreshTokenKey: "token"]
        #expect(GoogleKeep.credentials { all[$0] } == GoogleKeep.Credentials(clientID: "id", clientSecret: "secret", refreshToken: "token"))
        var missing = all
        missing[GoogleKeep.refreshTokenKey] = " "
        #expect(GoogleKeep.credentials { missing[$0] } == nil)
    }

    @Test func pkceChallengeIsTheSHA256OfTheVerifier() {
        // Computed apart, with Python's hashlib
        #expect(GoogleKeep.challenge(for: "dBjftJeZ4CVP-mJ92K9pYW8DwLY9EQ8gdIVJ6ZzEOdA") == "9ouR2eQoLkp7jbu6JbKR-zwg2M_qtix7j5myfmrlLCg")
        let verifier = GoogleKeep.randomString()
        #expect(verifier.count == 43 && verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(verifier != GoogleKeep.randomString())
    }

    @Test func asksForKeepOnlyWithPKCEAndAState() throws {
        let url = GoogleKeep.authorizationURL(clientID: "id", redirect: "http://127.0.0.1:5000", challenge: "ch", state: "st")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(url.host == "accounts.google.com")
        #expect(value("scope") == "https://www.googleapis.com/auth/keep")
        #expect(value("code_challenge_method") == "S256" && value("code_challenge") == "ch")
        #expect(value("state") == "st" && value("redirect_uri") == "http://127.0.0.1:5000")
        #expect(value("access_type") == "offline")
    }

    @Test func exchangesAndRefreshesWithAnEncodedForm() {
        let exchange = form(GoogleKeep.codeExchange(code: "4/0Ab", verifier: "v", redirect: "http://127.0.0.1:5000",
                                                    clientID: credentials.clientID, clientSecret: credentials.clientSecret))
        #expect(exchange["grant_type"] == "authorization_code" && exchange["code"] == "4/0Ab" && exchange["code_verifier"] == "v")
        #expect(exchange["client_secret"] == "GOCSPX-a+b")
        let refresh = GoogleKeep.refresh(credentials)
        #expect(refresh.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(String(data: refresh.httpBody ?? Data(), encoding: .utf8)?.contains("a%2Bb") == true)
        #expect(form(refresh)["grant_type"] == "refresh_token" && form(refresh)["refresh_token"] == "1//0g-token")
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

    @Test func readsWhatTheBrowserBroughtBack() {
        #expect(GoogleKeep.answer(inRequestLine: "GET /?state=st&code=4/0Ab&scope=x HTTP/1.1", state: "st") == .success("4/0Ab"))
        #expect(GoogleKeep.answer(inRequestLine: "GET /?error=access_denied&state=st HTTP/1.1", state: "st") == .failure(.refused("access_denied")))
        // Another page's answer, or the favicon, is not ours
        #expect(GoogleKeep.answer(inRequestLine: "GET /?state=other&code=4/0Ab HTTP/1.1", state: "st") == nil)
        #expect(GoogleKeep.answer(inRequestLine: "GET /favicon.ico HTTP/1.1", state: "st") == nil)
        #expect(GoogleKeep.answer(inRequestLine: "", state: "st") == nil)
    }

    @Test func saysGooglesWordNotItsBody() {
        #expect(GoogleKeep.reason(Data(#"{"error": "invalid_grant", "error_description": "Bad"}"#.utf8), status: 400) == "invalid_grant")
        #expect(GoogleKeep.reason(Data(#"{"error": {"code": 403, "status": "PERMISSION_DENIED"}}"#.utf8), status: 403) == "PERMISSION_DENIED")
        #expect(GoogleKeep.reason(Data("<html>".utf8), status: 502) == "HTTP 502")
    }
}
