import Foundation

// MARK: - Semrush, through its public API
// One request only: the remaining API units, which Semrush does not charge ("Price: 0 API units
// per request"). Pure HTTP, with an injectable transport: no view, no state, no Keychain here.

enum SemrushError: Error, Equatable, Sendable {
    /// No key saved.
    case noKey
    /// "ERROR 120 :: WRONG KEY - ID PAIR".
    case keyRefused
    case network
    /// Another answer: its code ("ERROR 130", "HTTP 502"), never the key nor the address.
    case unexpected(String)

    /// In words for the person.
    var reason: String {
        switch self {
        case .noKey: loc("il n'y a pas de clé Semrush dans les réglages")
        case .keyRefused: loc("Semrush refuse la clé, vérifie-la dans les réglages")
        case .network: loc("Semrush ne répond pas")
        case .unexpected(let code) where code.isEmpty: loc("Semrush a répondu quelque chose d'inattendu")
        case .unexpected(let code): loc("Semrush a répondu par une erreur (\(code))")
        }
    }
}

struct SemrushAPI: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let balanceURL = URL(string: "https://www.semrush.com/users/countapiunits.html")!

    var key: @Sendable () -> String?
    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    /// The units left on the account. The key goes in the address, as Semrush asks, over HTTPS only;
    /// the underlying error is dropped, since it carries that address.
    func balance() async throws(SemrushError) -> Int {
        guard let key = key()?.nonEmptyTrimmed else { throw .noKey }
        var components = URLComponents(url: Self.balanceURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components?.url else { throw .unexpected("") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(URLRequest(url: url, timeoutInterval: 20)) } catch { throw .network }
        let body = String(decoding: data, as: UTF8.self)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Semrush tells its errors in a line of text, whatever the status.
        if !(200..<300).contains(status), !body.uppercased().contains("ERROR") { throw .unexpected("HTTP \(status)") }
        return try Self.remaining(from: body)
    }

    /// "1,000", "47300", " 47 300\n": the number, whatever separates its thousands.
    static func remaining(from body: String) throws(SemrushError) -> Int {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("ERROR") {
            if text.uppercased().contains("WRONG KEY") || text.hasPrefix("ERROR 120") { throw .keyRefused }
            throw .unexpected(String(text.prefix { $0 != ":" }).trimmingCharacters(in: .whitespaces))
        }
        let digits = text.filter { !",. \u{00A0}\u{202F}".contains($0) }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else {
            throw .unexpected("")
        }
        return value
    }
}
