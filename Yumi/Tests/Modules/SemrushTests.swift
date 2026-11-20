import Foundation
import Testing

// The Semrush tile: its one free request, the units used since this morning, against simulated answers.

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var all: [URLRequest] { lock.withLock { requests } }
}

private func api(_ body: String, status: Int = 200, sent: Sent = Sent()) -> SemrushAPI {
    SemrushAPI(key: { "sm_secret+key" }, transport: { request in
        sent.add(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    })
}

private let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}()

private func at(_ day: Int, _ hour: Int) -> Date {
    paris.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

@Suite struct SemrushAPITests {
    @Test func theBalanceIsReadWhateverItsSeparators() throws {
        #expect(try SemrushAPI.remaining(from: "1,000") == 1000)
        #expect(try SemrushAPI.remaining(from: "47300") == 47300)
        #expect(try SemrushAPI.remaining(from: " 47 300\n") == 47300)
    }

    @Test func anErrorLineIsNeverANumber() {
        #expect(throws: SemrushError.keyRefused) { try SemrushAPI.remaining(from: "ERROR 120 :: WRONG KEY - ID PAIR") }
        #expect(throws: SemrushError.unexpected("ERROR 130")) { try SemrushAPI.remaining(from: "ERROR 130 :: API DISABLED") }
        #expect(throws: SemrushError.unexpected("")) { try SemrushAPI.remaining(from: "") }
        #expect(throws: SemrushError.unexpected("")) { try SemrushAPI.remaining(from: "<html>Bad gateway</html>") }
        // Only the code: the rest of the line may repeat the key.
        #expect(throws: SemrushError.unexpected("")) { try SemrushAPI.remaining(from: "ERROR for sm_secret+key") }
    }

    @Test func aRefusedKeyIsSaidWithoutRepeatingTheBody() async {
        for status in [400, 401, 403] {
            await #expect(throws: SemrushError.keyRefused) {
                try await api(#"{"code":\#(status),"message":"Invalid key sm_secret+key"}"#, status: status).balance()
            }
        }
    }

    @Test func theOneRequestIsTheFreeBalanceOverHTTPS() async throws {
        let sent = Sent()
        #expect(try await api("12,345", sent: sent).balance() == 12345)
        let url = try #require(sent.all.first?.url)
        #expect(url.scheme == "https" && url.host == "www.semrush.com" && url.path == "/users/countapiunits.html")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "key", value: "sm_secret+key")])
    }

    @Test func noKeySendsNothingAndFailuresKeepTheKeyOut() async {
        let noKey = SemrushAPI(key: { "  " }, transport: { _ in Issue.record("nothing must be sent"); throw URLError(.badURL) })
        await #expect(throws: SemrushError.noKey) { try await noKey.balance() }
        let down = SemrushAPI(key: { "sm_secret" }, transport: { request in throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: request.url!]) })
        await #expect(throws: SemrushError.network) { try await down.balance() }
        await #expect(throws: SemrushError.unexpected("HTTP 502")) { try await api("Bad gateway", status: 502).balance() }
        for error in [SemrushError.noKey, .keyRefused, .network, .unexpected("ERROR 130")] {
            #expect(!error.reason.isEmpty && !error.reason.contains("sm_secret"))
        }
    }
}

@Suite struct SemrushDayTests {
    @Test func theFirstReadingOfTheDayIsWhereTheCountStarts() {
        let day = SemrushDay.after(nil, reading: 50_000, at: at(20, 7), calendar: paris)
        #expect(day.start == 50_000 && day.latest == 50_000 && day.used == 0)
    }

    @Test func aLowerReadingCountsAndATopUpKeepsWhatTheDayUsed() {
        var day = SemrushDay.after(nil, reading: 50_000, at: at(20, 7), calendar: paris)
        day = SemrushDay.after(day, reading: 47_850, at: at(20, 11), calendar: paris)
        #expect(day.used == 2_150)
        // 100 000 units renewed at noon: the 2 150 of the morning still count.
        day = SemrushDay.after(day, reading: 147_850, at: at(20, 12), calendar: paris)
        #expect(day.used == 2_150)
        day = SemrushDay.after(day, reading: 146_850, at: at(20, 15), calendar: paris)
        #expect(day.used == 3_150)
    }

    @Test func anotherDayStartsFromZero() {
        let yesterday = SemrushDay.after(SemrushDay.after(nil, reading: 50_000, at: at(19, 8), calendar: paris),
                                         reading: 30_000, at: at(19, 18), calendar: paris)
        #expect(yesterday.used(on: at(20, 6), calendar: paris) == 0)
        let today = SemrushDay.after(yesterday, reading: 29_000, at: at(20, 6), calendar: paris)
        #expect(today.start == 29_000 && today.used == 0)
    }

    @Test func theStartOfTheDaySurvivesARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "semrush-day-\(UUID().uuidString)"))
        let day = SemrushDay.after(nil, reading: 50_000, at: at(20, 7), calendar: paris)
        day.save(to: defaults)
        #expect(SemrushDay.load(from: defaults) == day)
    }
}

/// Answers one body after the other, the last one again once they are used up.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String?]
    init(_ bodies: [String?]) { self.bodies = bodies }
    /// nil: the network fails.
    func next() -> String? { lock.withLock { bodies.count > 1 ? bodies.removeFirst() : bodies[0] } }
}

@MainActor
private func module(_ bodies: [String?], key: String? = "sm_secret", monthly: Int? = nil) -> SemrushModule {
    let answers = Answers(bodies)
    let defaults = UserDefaults(suiteName: "semrush-module-\(UUID().uuidString)")!
    if let monthly { defaults.set(monthly, forKey: SemrushModule.monthlyKey) }
    let api = SemrushAPI(key: { key }, transport: { request in
        guard let body = answers.next() else { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    return SemrushModule(api: api, defaults: defaults)
}

@MainActor
@Suite struct SemrushModuleTests {
    @Test func withoutAKeyTheTileLeadsToTheSettings() {
        let snapshot = module(["1,000"], key: nil).snapshot
        #expect(snapshot.status == loc("À brancher"))
        #expect(snapshot.primaryAction == loc("Ouvrir les réglages"))
        #expect(snapshot.progress == nil && snapshot.live == nil)
    }

    @Test func theUnitsLeftFillTheGaugeOfTheMonth() async {
        let tile = module(["47,300"])
        await tile.look()
        let snapshot = tile.snapshot
        #expect(snapshot.status == SemrushModule.units(47_300))
        #expect(snapshot.title.contains(SemrushModule.units(47_300)))
        #expect(snapshot.progress?.fraction == 0.473)
        #expect(snapshot.progress?.trailing.contains(SemrushModule.units(100_000)) == true)
        #expect(snapshot.live == nil && !snapshot.needsAttention)
    }

    @Test func theMonthOfTheSettingsIsTheGaugesTotal() async {
        let tile = module(["50000"], monthly: 200_000)
        await tile.look()
        #expect(tile.snapshot.progress?.fraction == 0.25)
    }

    @Test func overTheDailyCeilingTheFoldedIslandSaysSo() async {
        let tile = module(["100,000", "86,000"])
        await tile.look()
        await tile.look()
        #expect(tile.snapshot.subtitle.contains(SemrushModule.units(14_000)))
        #expect(tile.snapshot.live == nil)
        let over = module(["100,000", "84,500"])
        await over.look()
        await over.look()
        let snapshot = over.snapshot
        #expect(snapshot.needsAttention)
        #expect(snapshot.live?.text.contains(SemrushModule.units(15_500)) == true)
        // Above the music and a focus, below an approval.
        #expect(snapshot.live.map { $0.priority > ModuleLivePriority.activity && $0.priority < ModuleLivePriority.attention } == true)
    }

    @Test func anErrorKeepsTheLastBalanceAndSaysWhy() async {
        let refused = module(["ERROR 120 :: WRONG KEY - ID PAIR"])
        await refused.look()
        #expect(refused.snapshot.status == loc("Erreur"))
        #expect(refused.snapshot.subtitle.contains(FrenchText.sentenceStart(SemrushError.keyRefused.reason)))
        let down = module(["50,000", nil])
        await down.look()
        await down.look()
        #expect(down.snapshot.status == SemrushModule.units(50_000))
        #expect(down.snapshot.subtitle.contains(FrenchText.sentenceStart(SemrushError.network.reason)))
    }

    @Test func aBalanceOfZeroSaysTheKeyMayBeUnknown() async {
        // Semrush answers 0 to a key it does not know, as to an account with nothing left.
        let tile = module(["0"])
        await tile.look()
        #expect(tile.snapshot.subtitle == SemrushModule.emptyBalance)
    }

    @Test func aReadingCancelledInFlightChangesNothing() async {
        let defaults = UserDefaults(suiteName: "semrush-module-\(UUID().uuidString)")!
        // The settings change while the request is out: the polling is cancelled before the answer.
        let api = SemrushAPI(key: { "sm_secret" }, transport: { request in
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data("50,000".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let tile = SemrushModule(api: api, defaults: defaults)
        await Task { await tile.look() }.value
        #expect(SemrushDay.load(from: defaults) == nil)
        #expect(tile.snapshot.status == "…")
    }

    @Test func theTileLivesInTheWorkTab() {
        #expect(ModuleCategory.of(moduleID: "semrush") == .work)
    }
}
