import Testing
import Foundation

// The scheduled tasks of the Claude app, from simulated session cards and reports.

private let runID = "local_12345678-1234-1234-1234-123456789abc"
private let created = Date(timeIntervalSince1970: 1_800_000_000)

private func card(_ fields: [String: Any] = [:]) -> Data {
    var json: [String: Any] = [
        "sessionId": runID,
        "scheduledTaskId": "releve-hebdo",
        "createdAt": created.timeIntervalSince1970 * 1000,
        "lastActivityAt": (created.timeIntervalSince1970 + 600) * 1000,
        "completedTurns": 1,
        "postTurnSummary": ["status_detail": "Relevé envoyé par mail.", "needs_action": false],
        "title": "Ignored",
    ]
    json.merge(fields) { _, new in new }
    return try! JSONSerialization.data(withJSONObject: json)
}

private func report(_ fields: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: fields)
}

@Suite struct ClaudeAppCardTests {
    @Test func aScheduledRunIsRead() throws {
        let run = try #require(ClaudeAppCard.decode(card()))
        #expect(run.sessionID == runID)
        #expect(run.routine == "releve-hebdo")
        #expect(run.created == created)
        #expect(run.lastActivity == created.addingTimeInterval(600))
        #expect(run.completedTurns == 1)
        #expect(run.summary == "Relevé envoyé par mail.")
        #expect(run.needsAction == false)
    }

    @Test func aSessionWithoutTaskIsNoRoutine() {
        #expect(ClaudeAppCard.decode(card(["scheduledTaskId": NSNull()]))?.routine == nil)
    }

    @Test func aRunThatNeverFinishedATurnHasZeroTurns() {
        var fields = try! JSONSerialization.jsonObject(with: card()) as! [String: Any]
        fields.removeValue(forKey: "completedTurns")
        fields.removeValue(forKey: "postTurnSummary")
        let run = ClaudeAppCard.decode(try! JSONSerialization.data(withJSONObject: fields))
        #expect(run?.completedTurns == 0)
        #expect(run?.summary == nil)
    }

    @Test func aSummaryOfTheWrongShapeIsLeftOut() {
        #expect(ClaudeAppCard.decode(card(["postTurnSummary": "texte"]))?.summary == nil)
    }

    @Test func aTaskNameThatCouldEscapeItsFolderIsRefused() {
        #expect(ClaudeAppCard.decode(card(["scheduledTaskId": "../secret"]))?.routine == nil)
    }

    @Test func somethingElseIsNil() {
        #expect(ClaudeAppCard.decode(Data("pas du json".utf8)) == nil)
        #expect(ClaudeAppCard.decode(card(["sessionId": "abc"])) == nil)
        #expect(ClaudeAppCard.decode(card(["createdAt": "hier"])) == nil)
    }
}

@Suite struct RoutineReportTests {
    @Test func aReportIsRead() throws {
        let read = try #require(RoutineReport.decode(report([
            "title": "Leads de la semaine", "status": "warn", "lines": ["12 leads", "3 à rappeler"],
            "link": "https://example.com/sheet", "at": "2027-01-15T08:00:00Z",
        ])))
        #expect(read.title == "Leads de la semaine")
        #expect(read.status == .warn)
        #expect(read.lines == ["12 leads", "3 à rappeler"])
        #expect(read.link?.absoluteString == "https://example.com/sheet")
        #expect(read.at == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func linesAreCutToThreeShortOnes() throws {
        let long = String(repeating: "mot ", count: 60)
        let read = try #require(RoutineReport.decode(report(["status": "ok", "lines": [long, "b", "c", "d"]])))
        #expect(read.lines.count == 3)
        #expect(read.lines[0].count <= 121)
    }

    @Test func onlyAWebLinkIsKept() {
        #expect(RoutineReport.decode(report(["status": "ok", "link": "file:///etc/passwd"]))?.link == nil)
        #expect(RoutineReport.decode(report(["status": "ok", "link": "javascript:alert(1)"]))?.link == nil)
    }

    @Test func anUnknownStatusOrAHugeFileIsIgnored() {
        #expect(RoutineReport.decode(report(["status": "great"])) == nil)
        #expect(RoutineReport.decode(report(["status": "ok", "lines": [String(repeating: "x", count: 70_000)]])) == nil)
    }
}

@Suite struct RoutineStatusTests {
    private let now = created.addingTimeInterval(3600)

    private func routine(turns: Int = 1, needsAction: Bool = false, lastActivity: TimeInterval = 600,
                         report: RoutineReport? = nil) -> Routine {
        var run = ClaudeAppCard.decode(card())!
        run.completedTurns = turns
        run.needsAction = needsAction
        run.lastActivity = created.addingTimeInterval(lastActivity)
        return Routine(id: "releve-hebdo", run: run, report: report)
    }

    @Test func aRunThatFinishedIsDone() {
        #expect(routine().status(now: now, waitingLive: false) == .done)
    }

    @Test func aRunWaitingForAClickComesFirst() {
        #expect(routine(report: RoutineReport(status: .fail)).status(now: now, waitingLive: true) == .waiting)
        #expect(routine(needsAction: true).status(now: now, waitingLive: false) == .waiting)
    }

    @Test func theReportSaysHowItWent() {
        #expect(routine(report: RoutineReport(status: .fail)).status(now: now, waitingLive: false) == .failed)
        #expect(routine(report: RoutineReport(status: .warn)).status(now: now, waitingLive: false) == .warning)
    }

    @Test func aReportOfAnEarlierRunDoesNotCount() {
        let old = RoutineReport(status: .fail, at: created.addingTimeInterval(-86_400))
        #expect(routine(report: old).status(now: now, waitingLive: false) == .done)
    }

    @Test func noTurnAndSilentForHalfAnHourIsUnfinished() {
        #expect(routine(turns: 0, lastActivity: 600).status(now: now, waitingLive: false) == .unfinished)
        #expect(routine(turns: 0, lastActivity: 3000).status(now: now, waitingLive: false) == .running)
    }

    @Test func theLatestRunOfEachTaskIsKept() {
        var older = ClaudeAppCard.decode(card())!
        older.created = created.addingTimeInterval(-86_400)
        older.completedTurns = 0
        let newer = ClaudeAppCard.decode(card())!
        var other = ClaudeAppCard.decode(card(["scheduledTaskId": "veille"]))!
        other.lastActivity = created.addingTimeInterval(1200)
        let routines = Routine.all(runs: [older, newer, other], reports: [:])
        #expect(routines.map(\.id) == ["veille", "releve-hebdo"])
        #expect(routines.last?.run?.completedTurns == 1)
    }

    @Test func aReportWithoutRunHasItsOwnLine() {
        let routines = Routine.all(runs: [], reports: ["script-maison": RoutineReport(title: "Sauvegarde", status: .ok)])
        #expect(routines.map(\.name) == ["Sauvegarde"])
        #expect(routines.first?.status(now: now, waitingLive: false) == .done)
    }

    @Test func theRowShowsTheReportBeforeTheSummary() {
        let row = routine(report: RoutineReport(status: .ok, lines: ["12 leads", "3 à rappeler"]))
            .row(now: now, waitingLive: false)
        #expect(row.title == "Releve hebdo")
        #expect(row.detail == "12 leads")
        #expect(row.details == ["12 leads", "3 à rappeler"])
        #expect(row.state == .success)
        #expect(row.action == "releve-hebdo")
        #expect(routine().row(now: now, waitingLive: false).detail == "Relevé envoyé par mail.")
    }
}
