import Testing
import Foundation

// What each Claude Code session is working on, from simulated hooks.

private func hook(_ name: String, session: String = "s1", _ extra: [String: Any] = [:]) -> [String: Any] {
    var payload: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/Users/me/dev/yumi"]
    payload.merge(extra) { _, new in new }
    return payload
}

private func note(_ payload: [String: Any], last: String? = nil) -> SessionNote.Kind? {
    SessionNote.from(payload, transcript: { _ in last.map { assistantLine($0) } })?.kind
}

/// One line of a transcript: Claude's answer, with what the turn cost in tokens when given.
private func assistantLine(_ text: String, usage: [String: Int]? = nil) -> String {
    var message: [String: Any] = ["content": [["type": "text", "text": text]]]
    if let usage { message["usage"] = usage }
    let data = try! JSONSerialization.data(withJSONObject: ["type": "assistant", "message": message])
    return String(data: data, encoding: .utf8)!
}

private var todos: [String: Any] { ["todos": [
    ["content": "Lire le code", "activeForm": "Lit le code", "status": "completed"],
    ["content": "Écrire le test", "activeForm": "Écrit le test", "status": "in_progress"],
    ["content": "Lancer les tests", "status": "pending"],
]] }

@Suite struct ClaudeSessionJournalTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func journal(_ payloads: [[String: Any]], last: String? = nil) -> SessionJournal {
        var journal = SessionJournal(started: start)
        for (index, payload) in payloads.enumerated() {
            if let kind = note(payload, last: last) { journal.apply(kind, now: start.addingTimeInterval(Double(index))) }
        }
        return journal
    }

    @Test func theRequestIsKeptOnOneLine() {
        let long = "Corrige le repli de l'île\nquand on clique dehors, et ajoute un test qui le vérifie bien, avec plusieurs cas, et explique-moi"
        let j = journal([hook("UserPromptSubmit", ["prompt": long])])
        #expect(j.request?.hasPrefix("Corrige le repli de l'île quand on clique dehors") == true)
        #expect(j.request?.hasSuffix("…") == true)
        #expect((j.request?.count ?? 0) <= 91)
    }

    @Test func theTodoListGivesTheTaskAndTheProgress() {
        let j = journal([hook("UserPromptSubmit", ["prompt": "Ajoute le test"]), hook("PreToolUse", ["tool_name": "TodoWrite", "tool_input": todos])])
        #expect(j.progress == "1/3")
        #expect(j.currentTask == "Écrit le test")
    }

    @Test func eachToolSaysWhatItDoesOnWhat() {
        let edit = ToolStep(tool: "Edit", input: ["file_path": "/a/b/IslandModel.swift"])
        #expect(edit.sentence == "Modifie IslandModel.swift")
        #expect(ToolStep(tool: "Bash", input: ["command": "swift test"]).sentence == "Lance swift test")
        #expect(ToolStep(tool: "Read", input: ["file_path": "/x/README.md"]).sentence == "Lit README.md")
        #expect(ToolStep(tool: "Grep", input: ["pattern": "TODO"]).sentence == "Cherche TODO")
        #expect(ToolStep(tool: "Write", input: ["file_path": "/x/new.swift"]).sentence == "Écrit new.swift")
    }

    @Test func theActionInProgressThenTheHistory() {
        var j = journal([hook("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/a/Model.swift"]])])
        #expect(j.current?.sentence == "Modifie Model.swift")
        if let kind = note(hook("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/a/Model.swift"]])) { j.apply(kind, now: start) }
        #expect(j.current == nil)
        #expect(j.history.map(\.sentence) == ["Modifie Model.swift"])
        #expect(j.filesTouched == ["/a/Model.swift"])
        for n in 0..<20 {
            if let kind = note(hook("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "echo \(n)"]])) { j.apply(kind, now: start) }
        }
        #expect(j.history.count == SessionJournal.historyLength)
        #expect(j.history.last?.sentence == "Lance echo 19")
        #expect(j.commands == 20)
    }

    @Test func theEndOfATurnSaysWhatWasDone() {
        let edit: [String: Any] = ["tool_name": "Edit", "tool_input": ["file_path": "/a/One.swift"]]
        let edit2: [String: Any] = ["tool_name": "Write", "tool_input": ["file_path": "/a/Two.swift"]]
        let bash: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "swift test"]]
        let done: [String: Any] = ["todos": [["content": "a", "status": "completed"], ["content": "b", "status": "completed"]]]
        let j = journal([hook("UserPromptSubmit", ["prompt": "Fais-le"]), hook("PostToolUse", edit), hook("PostToolUse", edit2),
                         hook("PostToolUse", bash), hook("PostToolUse", ["tool_name": "TodoWrite", "tool_input": done]),
                         hook("Stop", ["transcript_path": "/tmp/t.jsonl"])],
                        last: "J'ai ajouté le test et tout passe. Le reste est inchangé.")
        #expect(j.summary == "Deux fichiers modifiés, une commande, 2/2 tâches. J'ai ajouté le test et tout passe.")
    }

    @Test func aNewRequestStartsAFreshTurn() {
        var j = journal([hook("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), hook("Stop")])
        #expect(j.summary != nil)
        if let kind = note(hook("UserPromptSubmit", ["prompt": "Et maintenant ?"])) { j.apply(kind, now: start) }
        #expect(j.summary == nil && j.commands == 0 && j.request == "Et maintenant ?")
    }

    @Test func secretsAreMasked() {
        #expect(SecretMask.mask("OPENAI_API_KEY=sk-abc123 npm start") == "OPENAI_API_KEY=••• npm start")
        #expect(SecretMask.mask("curl -H 'Authorization: Bearer abc.def' https://x") == "curl -H 'Authorization: Bearer •••' https://x")
        #expect(SecretMask.mask("gh auth login --token ghp_abcdefghijklmnopqrstuvwxyz12") == "gh auth login --token •••")
        #expect(SecretMask.mask("git clone https://me:hunter2@github.com/me/x") == "git clone https://me:•••@github.com/me/x")
        #expect(SecretMask.mask("echo sk-ant-api03-abcdefghijklmnopqrstuv") == "echo •••")
        #expect(SecretMask.mask("swift test --filter Island") == "swift test --filter Island")
        let step = ToolStep(tool: "Bash", input: ["command": "export GITHUB_TOKEN=ghp_secret && deploy"])
        #expect(!step.target.contains("ghp_secret"))
    }

    @Test func theLastMessageIsReadFromTheTranscript() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"Salut"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Premier."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"C'est fait, les tests passent."}]}}
        """
        #expect(SessionText.lastAssistantText(transcript: transcript) == "C'est fait, les tests passent.")
    }

    @Test func severalSessionsKeepTheirOwnJournal() {
        let journals = ClaudeSessionJournalsTestDouble()
        journals.apply(hook("UserPromptSubmit", session: "a", ["prompt": "Un"]))
        journals.apply(hook("UserPromptSubmit", session: "b", ["prompt": "Deux"]))
        journals.apply(hook("PreToolUse", session: "b", ["tool_name": "Bash", "tool_input": ["command": "make"]]))
        #expect(journals.items["a"]?.request == "Un" && journals.items["a"]?.current == nil)
        #expect(journals.items["b"]?.current?.sentence == "Lance make")
    }
}

/// The same bookkeeping as ClaudeSessionJournals, without the shared instance.
private final class ClaudeSessionJournalsTestDouble {
    var items: [String: SessionJournal] = [:]
    func apply(_ payload: [String: Any]) {
        guard let note = SessionNote.from(payload) else { return }
        var journal = items[note.session] ?? SessionJournal(started: .now)
        journal.apply(note.kind, now: .now)
        items[note.session] = journal
    }
}

@Suite struct ClaudeSessionsShowTheWorkTests {
    private func session(_ id: String, working: Bool) -> Session {
        var session = Session(id: SessionID(id), agent: ClaudeHookTranslator.agent, title: "yumi")
        session.origin = SessionOrigin(workingDirectory: "/dev/yumi")
        session.isTurnActive = working
        session.activity = working ? .thinking : .idle
        return session
    }

    @Test func theFoldedIslandSaysWhatTheSessionIsOn() {
        var journal = SessionJournal(started: .now)
        if let kind = SessionNote.from(["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Edit",
                                        "tool_input": ["file_path": "/x/IslandModel.swift"]])?.kind {
            journal.apply(kind, now: .now)
        }
        let live = ClaudeSessions.live([session("s", working: true)], journals: ["s": journal])
        #expect(live?.text == "yumi · Modifie IslandModel.swift")
        #expect(live?.priority == ClaudeSessions.workingPriority)
        #expect(ClaudeSessions.live([session("s", working: true)]) == nil)
    }

    @Test func aRowShowsTheActionTheProgressAndUnfolds() {
        var journal = SessionJournal(started: .now)
        if let kind = SessionNote.from(["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "TodoWrite", "tool_input": todos])?.kind {
            journal.apply(kind, now: .now)
        }
        var row = ModuleRow(id: "s", title: "yumi", detail: "Réfléchit.", state: .busy, label: "travaille")
        row = SessionBoard.enriched(row, journal, now: .now)
        #expect(row.detail == "Écrit le test")
        #expect(row.progress == "1/3")
        #expect(row.details.contains("Tâche 1/3 : Écrit le test"))
    }

}

/// How full each session's context is, from the end of its transcript.
@Suite struct ClaudeSessionContextTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)


    @Test func theContextIsWhatTheLastAnswerCost() {
        let transcript = [
            "ng\":\"tronquée au début\"}",
            assistantLine("Avant", usage: ["input_tokens": 1_000, "cache_read_input_tokens": 9_000]),
            #"{"type":"user","message":{"content":"et ensuite ?"}}"#,
            assistantLine("Après", usage: ["input_tokens": 2_000, "cache_read_input_tokens": 150_000, "cache_creation_input_tokens": 8_000]),
            assistantLine("Sans usage"),
        ].joined(separator: "\n")
        #expect(SessionText.contextTokens(transcript: transcript) == 160_000)
        #expect(SessionText.contextTokens(transcript: assistantLine("Rien")) == nil)
        #expect(SessionText.contextTokens(transcript: assistantLine("Sans cache", usage: ["input_tokens": 500])) == 500)
    }

    @Test func theShareIsOfTheModelsWindow() {
        #expect(SessionText.contextShare(tokens: 160_000, model: nil) == 80)
        #expect(SessionText.contextShare(tokens: 160_000, model: "claude-opus-5-5[1m]") == 16)
        // Past 200 000 tokens the window can only be the large one
        #expect(SessionText.contextShare(tokens: 300_000, model: nil) == 30)
        #expect(SessionText.contextShare(tokens: 0, model: nil) == 0)
        #expect(SessionText.contextShare(tokens: 2_000_000, model: nil) == 100)
    }

    @Test func aFinishedTurnTellsTheContextAndSuggestsCompactingWhenFull() {
        let stop = hook("Stop", ["transcript_path": "/tmp/t.jsonl", "host_model": "claude-opus-5-5"])
        let kind = SessionNote.from(stop, transcript: { _ in
            assistantLine("Fini.", usage: ["input_tokens": 1_000, "cache_read_input_tokens": 169_000])
        })?.kind
        var journal = SessionJournal(started: start)
        if let kind { journal.apply(kind, now: start) }
        #expect(journal.context == 85)
        #expect(journal.details(now: start).contains("Contexte 85 %"))
        let row = SessionBoard.enriched(ModuleRow(id: "s1", title: "yumi", detail: "", state: .success, label: "a fini"), journal, now: start)
        #expect(row.detail == "Contexte à 85 %, pense à /compact")
        // The next request keeps the gauge until the next answer
        if let next = note(hook("UserPromptSubmit", ["prompt": "Continue"])) { journal.apply(next, now: start) }
        #expect(journal.context == 85)
    }

    @Test func aCompactStartsTheGaugeAgain() {
        var journal = SessionJournal(started: start, context: 85)
        if let kind = note(hook("SessionStart", ["source": "compact"])) { journal.apply(kind, now: start) }
        #expect(journal.context == nil)
        var resumed = SessionJournal(started: start, context: 40)
        if let kind = note(hook("SessionStart", ["source": "resume"])) { resumed.apply(kind, now: start) }
        #expect(resumed.context == 40)
    }

    @Test func aRoomyContextLeavesTheSummary() {
        var journal = SessionJournal(started: start)
        if let kind = SessionNote.from(hook("Stop", ["transcript_path": "/tmp/t.jsonl"]), transcript: { _ in
            assistantLine("J'ai fini le test.", usage: ["input_tokens": 40_000])
        })?.kind { journal.apply(kind, now: start) }
        let row = SessionBoard.enriched(ModuleRow(id: "s1", title: "yumi", detail: "", state: .success, label: "a fini"), journal, now: start)
        #expect(row.detail.hasSuffix("J'ai fini le test."))
        #expect(journal.details(now: start).contains("Contexte 20 %"))
    }
}
