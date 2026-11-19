import Testing
import Foundation

@Suite struct GoogleTasksTests {
    private let credentials = GoogleTasks.Credentials(clientID: "123.apps.googleusercontent.com", clientSecret: "GOCSPX-a+b",
                                                      refreshToken: "1//0g-token")

    private func form(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1].removingPercentEncoding ?? "" : "")
        })
    }

    private func task(_ request: URLRequest) throws -> [String: String] {
        try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
    }

    @Test func needsAllThreeSecrets() {
        let all = [GoogleTasks.clientIDKey: "id", GoogleTasks.clientSecretKey: "secret", GoogleTasks.refreshTokenKey: "token"]
        #expect(GoogleTasks.credentials { all[$0] } == GoogleTasks.Credentials(clientID: "id", clientSecret: "secret", refreshToken: "token"))
        var missing = all
        missing[GoogleTasks.refreshTokenKey] = " "
        #expect(GoogleTasks.credentials { missing[$0] } == nil)
    }

    @Test func pkceChallengeIsTheSHA256OfTheVerifier() {
        // Computed apart, with Python's hashlib
        #expect(GoogleTasks.challenge(for: "dBjftJeZ4CVP-mJ92K9pYW8DwLY9EQ8gdIVJ6ZzEOdA") == "9ouR2eQoLkp7jbu6JbKR-zwg2M_qtix7j5myfmrlLCg")
        let verifier = GoogleTasks.randomString()
        #expect(verifier.count == 43 && verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(verifier != GoogleTasks.randomString())
    }

    @Test func asksForTasksOnlyWithPKCEAndAState() throws {
        let url = GoogleTasks.authorizationURL(clientID: "id", redirect: "http://127.0.0.1:5000", challenge: "ch", state: "st")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(url.host == "accounts.google.com")
        #expect(value("scope") == "https://www.googleapis.com/auth/tasks")
        #expect(value("code_challenge_method") == "S256" && value("code_challenge") == "ch")
        #expect(value("state") == "st" && value("redirect_uri") == "http://127.0.0.1:5000")
        #expect(value("access_type") == "offline")
    }

    @Test func exchangesAndRefreshesWithAnEncodedForm() {
        let exchange = form(GoogleTasks.codeExchange(code: "4/0Ab", verifier: "v", redirect: "http://127.0.0.1:5000",
                                                     clientID: credentials.clientID, clientSecret: credentials.clientSecret))
        #expect(exchange["grant_type"] == "authorization_code" && exchange["code"] == "4/0Ab" && exchange["code_verifier"] == "v")
        #expect(exchange["client_secret"] == "GOCSPX-a+b")
        let refresh = GoogleTasks.refresh(credentials)
        #expect(refresh.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(String(data: refresh.httpBody ?? Data(), encoding: .utf8)?.contains("a%2Bb") == true)
        #expect(form(refresh)["grant_type"] == "refresh_token" && form(refresh)["refresh_token"] == "1//0g-token")
    }

    @Test func aNoteBecomesATaskOfTheDefaultList() throws {
        let request = GoogleTasks.createTask("  Appeler Paul\nà 14 h, pour le devis\n", accessToken: "ya29.x")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.x")
        #expect(try task(request) == ["title": "Appeler Paul", "notes": "à 14 h, pour le devis"])
        // One line: a title and nothing else
        #expect(try task(GoogleTasks.createTask("Idée : mode nuit", accessToken: "t")) == ["title": "Idée : mode nuit"])
    }

    @Test func readsWhatTheBrowserBroughtBack() {
        #expect(GoogleTasks.answer(inRequestLine: "GET /?state=st&code=4/0Ab&scope=x HTTP/1.1", state: "st") == .success("4/0Ab"))
        #expect(GoogleTasks.answer(inRequestLine: "GET /?error=access_denied&state=st HTTP/1.1", state: "st") == .failure(.refused("access_denied")))
        // Another page's answer, or the favicon, is not ours
        #expect(GoogleTasks.answer(inRequestLine: "GET /?state=other&code=4/0Ab HTTP/1.1", state: "st") == nil)
        #expect(GoogleTasks.answer(inRequestLine: "GET /favicon.ico HTTP/1.1", state: "st") == nil)
        #expect(GoogleTasks.answer(inRequestLine: "", state: "st") == nil)
    }

    @Test func saysGooglesWordNotItsBody() {
        #expect(GoogleTasks.reason(Data(#"{"error": "invalid_grant", "error_description": "Bad"}"#.utf8), status: 400) == "invalid_grant")
        #expect(GoogleTasks.reason(Data(#"{"error": {"code": 403, "status": "PERMISSION_DENIED"}}"#.utf8), status: 403) == "PERMISSION_DENIED")
        #expect(GoogleTasks.reason(Data("<html>".utf8), status: 502) == "HTTP 502")
    }
}
