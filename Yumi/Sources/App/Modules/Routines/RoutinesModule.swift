import AppKit

/// The scheduled tasks of the Claude app: the last run of each, how it went, and the report it left
/// in `Reports/` of Yumi's support folder. Reads files only, on this Mac; nothing runs on a timer:
/// it looks again when a session of the Claude app stops, ends or asks, when a report changes,
/// and when the Mac wakes.
@MainActor
final class RoutinesModule: YumiModule {
    let id = "routines"

    /// Runs seen by the person, and runs Yumi already spoke about: once each.
    private static let seenKey = "routinesSeen", toldKey = "routinesTold"
    /// A run that went wrong longer ago than this no longer asks for attention.
    private static let recent: TimeInterval = 12 * 3600

    static var reportsFolder: URL { AppIdentity.supportDirectory.appendingPathComponent("Reports") }

    private let defaults: UserDefaults
    private let onTrouble: @MainActor (_ name: String, _ failed: Bool) -> Void
    private var routines: [Routine] = []
    /// The Claude app's files already read, so that only the ones that changed are read again.
    private var known: [String: ClaudeAppCard.Seen] = [:]
    /// The Claude app ids of the sessions waiting for the person right now.
    private var waiting: Set<String> = []
    private var onChange: (@MainActor () -> Void)?
    private var scanning: Task<Void, Never>?
    /// Asked again while reading: read once more right after.
    private var again = false
    private var nextChange: Task<Void, Never>?
    private var folderWatch: DispatchSourceFileSystemObject?
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, onTrouble: @escaping @MainActor (_ name: String, _ failed: Bool) -> Void = { _, _ in }) {
        self.defaults = defaults
        self.onTrouble = onTrouble
    }

    // MARK: Snapshot

    var snapshot: ModuleSnapshot {
        let now = Date()
        let rows = routines.map { $0.row(now: now, waitingLive: isWaiting($0)) }
        let toLook = routines.filter { needsLook($0, now: now) && !seen.contains(Self.key(of: $0)) }
        let first = toLook.first ?? routines.first
        return ModuleSnapshot(
            id: id, name: loc("Routines"), colorHex: "#6FD3A8",
            status: !toLook.isEmpty ? loc("\(toLook.count) à voir") : routines.count == 1 ? loc("1 routine") : loc("\(routines.count) routines"),
            title: first.map { loc("\($0.name) : \($0.status(now: now, waitingLive: isWaiting($0)).label)") } ?? loc("Aucune routine pour l'instant"),
            subtitle: first.map { $0.row(now: now, waitingLive: isWaiting($0)).detail }
                ?? loc("Les tâches planifiées de l'app Claude s'afficheront ici."),
            primaryAction: loc("Voir"), secondaryAction: nil,
            needsAttention: !toLook.isEmpty,
            symbol: "clock.arrow.circlepath",
            rows: rows)
    }

    private func isWaiting(_ routine: Routine) -> Bool {
        routine.run.map { waiting.contains($0.sessionID) } ?? false
    }

    private func needsLook(_ routine: Routine, now: Date) -> Bool {
        guard let date = routine.date, now.timeIntervalSince(date) < Self.recent else { return false }
        return routine.status(now: now, waitingLive: isWaiting(routine)).needsLook
    }

    /// One run: its session, or the date of its report when it has no run.
    private static func key(of routine: Routine) -> String {
        "\(routine.id)@\(routine.run?.sessionID ?? routine.report?.at?.timeIntervalSince1970.description ?? "")"
    }

    private var seen: Set<String> { Set(defaults.stringArray(forKey: Self.seenKey) ?? []) }

    private func remember(_ keys: [String], under name: String) {
        // The last runs are enough: the list never grows past a few dozen.
        let kept = (defaults.stringArray(forKey: name) ?? []).filter { !keys.contains($0) } + keys
        defaults.set(Array(kept.suffix(60)), forKey: name)
    }

    // MARK: Lifecycle

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        observers = [
            NotificationCenter.default.addObserver(forName: .moduleRowAction, object: nil, queue: .main) { [weak self] note in
                guard note.userInfo?["module"] as? String == "routines", let row = note.userInfo?["row"] as? String else { return }
                MainActor.assumeIsolated { self?.open(row) }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scan() }
            },
        ]
        watchReports()
        scan(after: 0)
    }

    func stop() {
        onChange = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        folderWatch?.cancel()
        folderWatch = nil
        scanning?.cancel()
        scanning = nil
        nextChange?.cancel()
        nextChange = nil
    }

    func receive(_ event: YumiEvent, sessions: [SessionID: Session]) {
        let waitingNow = Set(sessions.values.filter { $0.status == .waitingForUser }.compactMap { $0.origin?.hostSessionID }.filter { !$0.isEmpty })
        switch event {
        case .taskCompleted, .sessionEnded, .permissionRequested, .questionRequested:
            // Only a session of the Claude app can be a routine's run; one already gone may have been.
            if let id = event.sessionID, sessions[id]?.origin.map({ $0.hostSessionID.isEmpty }) != true { scan() }
        default: break
        }
        guard waitingNow != waiting else { return }
        waiting = waitingNow
        changed()
    }

    // MARK: Reading

    /// Reads the runs and the reports again, off the main thread. Calls close together make one read.
    private func scan(after delay: TimeInterval = 1) {
        guard onChange != nil else { return }
        guard scanning == nil else { return again = true }
        scanning = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            let folder = Self.reportsFolder, known = self?.known ?? [:]
            let (found, read) = await Task.detached(priority: .utility) {
                let runs = ClaudeAppCard.scheduledRuns(known: known)
                return (Routine.all(runs: runs.runs, reports: Self.reports(in: folder)), runs.known)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.scanning = nil
            self.known = read
            if self.again {
                self.again = false
                self.scan(after: 0)
            }
            guard found != self.routines else { return }
            self.routines = found
            self.changed()
        }
    }

    /// The reports, by task. One without `at` is dated by its file, so that each new one counts
    /// as new and one left by an earlier run is not taken for the last run's.
    nonisolated static func reports(in folder: URL) -> [String: RoutineReport] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        var reports: [String: RoutineReport] = [:]
        for url in files where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._-]{0,99}/) != nil,
                  let values = try? url.resourceValues(forKeys: keys), (values.fileSize ?? .max) <= RoutineReport.maxBytes,
                  let data = try? Data(contentsOf: url), var report = RoutineReport.decode(data) else { continue }
            if report.at == nil { report.at = values.contentModificationDate }
            reports[id] = report
        }
        return reports
    }

    /// A report written, replaced or removed is read within a second.
    /// shortcut: watching the folder sees files added, renamed or removed, not a file rewritten in
    /// place; that one is read at the next event of a Claude app session (a routine's own end).
    /// Writers replace a report by renaming a new file over it (docs/architecture.md). Upgrade to
    /// FSEvents file events if scripts that rewrite in place become common.
    private func watchReports() {
        let folder = Self.reportsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = Darwin.open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan(after: 0.3) } }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        folderWatch = source
    }

    /// Something changed: say so, tell about a run that went wrong, and wake up when a running
    /// run would count as stopped, since no event comes for a run that just stops.
    private func changed() {
        let now = Date()
        let told = Set(defaults.stringArray(forKey: Self.toldKey) ?? [])
        for routine in routines where needsLook(routine, now: now) && !told.contains(Self.key(of: routine)) {
            let status = routine.status(now: now, waitingLive: isWaiting(routine))
            // A run waiting for a click is already in Claude Code's list, with its approval.
            guard status != .waiting else { continue }
            remember([Self.key(of: routine)], under: Self.toldKey)
            onTrouble(routine.name, status == .failed)
        }
        nextChange?.cancel()
        let quiet = routines.compactMap { routine -> Date? in
            guard let run = routine.run, routine.status(now: now, waitingLive: false) == .running else { return nil }
            return run.lastActivity.addingTimeInterval(Routine.silence + 1)
        }.min()
        if let quiet {
            nextChange = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, quiet.timeIntervalSinceNow)), tolerance: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.changed()
            }
        }
        onChange?()
    }

    // MARK: Actions

    /// "Voir": the routine that needs a look, or else the latest one.
    func perform(_ action: ModuleAction) {
        guard action == .primary else { return }
        let now = Date()
        if let routine = routines.first(where: { needsLook($0, now: now) }) ?? routines.first { open(routine.id) }
    }

    /// Opens the run in the Claude app, or the report's page when there is no run. Seen from then on.
    private func open(_ id: String) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        remember([Self.key(of: routine)], under: Self.seenKey)
        if let link = SessionHost.deepLink(for: SessionOrigin(hostSessionID: routine.run?.sessionID ?? "")) ?? routine.report?.link {
            NSWorkspace.shared.open(link)
        }
        onChange?()
    }
}
