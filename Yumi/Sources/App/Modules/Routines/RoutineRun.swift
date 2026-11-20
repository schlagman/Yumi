import Foundation

/// What a routine says of its own run, in `Reports/<task id>.json` of Yumi's support folder.
/// Written by anyone who can write there, so read as untrusted text: bounded, links to the web only.
struct RoutineReport: Equatable, Sendable {
    enum Status: String, Sendable { case ok, warn, fail }

    var title: String? = nil
    var status: Status
    var lines: [String] = []
    var link: URL? = nil
    var at: Date? = nil

    static let maxBytes = 65_536

    static func decode(_ data: Data) -> RoutineReport? {
        guard data.count <= maxBytes,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = (json["status"] as? String).flatMap(Status.init(rawValue:)) else { return nil }
        let link = (json["link"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        return RoutineReport(title: (json["title"] as? String).flatMap { SessionText.oneLine($0, limit: 120) },
                             status: status,
                             lines: ((json["lines"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap { SessionText.oneLine($0, limit: 120) } }.prefix(3).map { $0 },
                             link: link,
                             at: (json["at"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
    }
}

/// How the last run of a routine went, the most pressing first.
enum RoutineStatus: Equatable, Sendable {
    case waiting, failed, warning, unfinished, running, done

    var rowState: ModuleRowState {
        switch self {
        case .waiting, .warning:   return .waiting
        case .failed, .unfinished: return .failure
        case .running:             return .busy
        case .done:                return .success
        }
    }

    var label: String {
        switch self {
        case .waiting:    return loc("attend ton clic")
        case .failed:     return loc("a un souci")
        case .warning:    return loc("à regarder")
        case .unfinished: return loc("pas finie")
        case .running:    return loc("tourne encore")
        case .done:       return loc("terminée")
        }
    }

    /// Worth the person's attention: something to do or something that went wrong.
    var needsLook: Bool { ![.running, .done].contains(self) }

    /// What Yumi says of it on his own: true "a problem", false "did not finish", nil nothing.
    /// A run waiting for a click is already in Claude Code's list, with its approval.
    var trouble: Bool? {
        switch self {
        case .failed, .warning:          return true
        case .unfinished:                return false
        case .waiting, .running, .done:  return nil
        }
    }
}

/// One scheduled task: its last run in the Claude app and the report it left, either may be missing.
struct Routine: Equatable, Sendable {
    let id: String
    var run: ClaudeAppCard?
    var report: RoutineReport?

    /// A run that finished no turn and did nothing for this long has stopped.
    static let silence: TimeInterval = 30 * 60

    var name: String {
        if let title = report?.title { return title }
        let words = id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var date: Date? { [run?.lastActivity, report?.at].compactMap { $0 }.max() }

    /// The report, unless it was left by an earlier run than the one shown.
    private var currentReport: RoutineReport? {
        guard let report, let run, let at = report.at else { return report }
        return at >= run.created ? report : nil
    }

    func status(now: Date, waitingLive: Bool) -> RoutineStatus {
        if waitingLive || run?.needsAction == true { return .waiting }
        switch currentReport?.status {
        case .fail: return .failed
        case .warn: return .warning
        default: break
        }
        guard let run, run.completedTurns == 0 else { return .done }
        return now.timeIntervalSince(run.lastActivity) > Self.silence ? .unfinished : .running
    }

    func row(now: Date, waitingLive: Bool) -> ModuleRow {
        let status = status(now: now, waitingLive: waitingLive)
        let lines = currentReport?.lines ?? []
        return ModuleRow(id: id, title: name, detail: lines.first ?? run?.summary ?? "", state: status.rowState,
                         label: status.label, date: date, action: id, details: lines)
    }

    /// One routine per task: the latest run of each, with its report; a report with no run has its own.
    /// The most recent first.
    static func all(runs: [ClaudeAppCard], reports: [String: RoutineReport]) -> [Routine] {
        var latest: [String: ClaudeAppCard] = [:]
        for run in runs {
            guard let id = run.routine else { continue }
            if latest[id].map({ $0.created < run.created }) ?? true { latest[id] = run }
        }
        let ids = Set(latest.keys).union(reports.keys)
        return ids.map { Routine(id: $0, run: latest[$0], report: reports[$0]) }
            .sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
    }
}
