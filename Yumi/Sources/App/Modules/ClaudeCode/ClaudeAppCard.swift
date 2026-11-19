import Foundation

/// What Yumi reads from the Claude app's file of one session
/// (`~/Library/Application Support/Claude/claude-code-sessions/*/*/local_….json`). That file is not
/// documented: only these fields are read, and a file of another shape gives nil, never a crash.
struct ClaudeAppCard: Equatable, Sendable {
    /// The app's own id of the session, `local_…`: opens it with `claude://claude.ai/epitaxy/<id>`.
    var sessionID: String
    /// The scheduled task that started this session (its folder in `~/.claude/scheduled-tasks/`). Nil for a session started by hand.
    var routine: String?
    var created: Date
    var lastActivity: Date
    /// Turns finished so far: 0 for a run that never got to the end of one.
    var completedTurns: Int
    /// The app's summary of the last turn, nil without one.
    var summary: String?
    /// The app says the session waits for the person.
    var needsAction: Bool

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    static func decode(_ data: Data) -> ClaudeAppCard? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["sessionId"] as? String, id.wholeMatch(of: /local_[0-9a-f-]{36}/) != nil,
              let created = json["createdAt"] as? Double, let last = json["lastActivityAt"] as? Double else { return nil }
        let summary = json["postTurnSummary"] as? [String: Any]
        // The task id names a file of Yumi's reports: never a path.
        let routine = (json["scheduledTaskId"] as? String).flatMap { $0.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._-]{0,99}/) != nil ? $0 : nil }
        return ClaudeAppCard(sessionID: id, routine: routine,
                             created: Date(timeIntervalSince1970: created / 1000),
                             lastActivity: Date(timeIntervalSince1970: last / 1000),
                             completedTurns: json["completedTurns"] as? Int ?? 0,
                             summary: (summary?["status_detail"] as? String).flatMap { SessionText.oneLine($0, limit: 140) },
                             needsAction: summary?["needs_action"] as? Bool ?? false)
    }

    /// The runs of scheduled tasks, from the app's files. Files of other sessions are skipped before
    /// being parsed, and files over 5 MB are not read (same limit as the hook script).
    static func scheduledRuns(in folder: URL = folder) -> [ClaudeAppCard] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var runs: [ClaudeAppCard] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("local_"),
                  ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) <= 5_000_000,
                  let data = try? Data(contentsOf: url), data.range(of: Data("scheduledTaskId".utf8)) != nil,
                  let card = decode(data), card.routine != nil else { continue }
            runs.append(card)
        }
        return runs
    }
}
