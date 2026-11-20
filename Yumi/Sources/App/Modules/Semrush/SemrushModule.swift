import AppKit

/// Semrush, as a module: the API units left on the account, against the month's total set in the
/// settings, and how many went since this morning. Says so in the folded island once the day
/// goes over the team's ceiling. Reads with the one request Semrush does not charge.
@MainActor
final class SemrushModule: YumiModule {
    let id = "semrush"
    /// The request is free: every five minutes is plenty for a daily ceiling.
    static let interval: Duration = .seconds(300)
    /// The team's rule: no more than this many units in a session without asking first.
    static let dailyCeiling = 15_000
    static let monthlyKey = "semrush.monthlyUnits"
    static let defaultMonthly = 100_000
    static let settingsChanged = AppIdentity.notification("semrushSettingsChanged")
    /// Where Semrush shows the remaining units (its API documentation links there).
    static let unitsPage = URL(string: "https://www.semrush.com/accounts/subscription-info/api-units/")!

    private let api: SemrushAPI
    private let defaults: UserDefaults
    private let openSettings: @MainActor () -> Void
    private var day: SemrushDay?
    private var problem: SemrushError?
    private var onChange: (@MainActor () -> Void)?
    private var polling: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?

    init(api: SemrushAPI, defaults: UserDefaults = .standard, openSettings: @escaping @MainActor () -> Void = {}) {
        self.api = api
        self.defaults = defaults
        self.openSettings = openSettings
        day = SemrushDay.load(from: defaults)
    }

    /// The month's units of the settings, 100 000 when never set.
    static func monthly(in defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: monthlyKey)
        return value > 0 ? value : defaultMonthly
    }

    /// "47 300" in French, "47,300" in English.
    static func units(_ value: Int) -> String { value.formatted(.number.locale(AppLanguage.locale)) }

    private var hasKey: Bool { api.key()?.nonEmptyTrimmed != nil }

    var snapshot: ModuleSnapshot {
        var snapshot = ModuleSnapshot(id: id, name: "Semrush", colorHex: "#9AA0A6", status: "", title: "", subtitle: "",
                                      primaryAction: loc("Ouvrir"), symbol: "gauge.with.dots.needle.33percent")
        guard hasKey else {
            snapshot.status = loc("À brancher")
            snapshot.title = loc("Branche Semrush dans les réglages")
            snapshot.subtitle = loc("Ta clé d'API, pour suivre les unités restantes.")
            snapshot.primaryAction = loc("Ouvrir les réglages")
            return snapshot
        }
        guard let day else {
            snapshot.status = problem == nil ? "…" : loc("Erreur")
            snapshot.title = problem == nil ? loc("Lecture du solde…") : loc("Semrush ne répond pas comme prévu")
            snapshot.subtitle = problem.map { FrenchText.sentenceStart($0.reason) + "." } ?? ""
            return snapshot
        }
        let monthly = Self.monthly(in: defaults)
        let used = day.used(on: Date())
        snapshot.status = Self.units(day.latest)
        snapshot.title = loc("\(Self.units(day.latest)) unités restantes")
        snapshot.subtitle = problem.map { FrenchText.sentenceStart($0.reason) + "." }
            ?? (used == 0 ? loc("Rien de consommé depuis ce matin.") : loc("\(Self.units(used)) depuis ce matin."))
        let fraction = min(1, Double(day.latest) / Double(monthly))
        snapshot.progress = ModuleProgress(fraction: fraction,
                                           leading: fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.locale)),
                                           trailing: loc("sur \(Self.units(monthly))"))
        if used > Self.dailyCeiling {
            snapshot.needsAttention = true
            // Above a session at work and the turns to see, below the chat's own activity and an approval.
            snapshot.live = ModuleLive(text: loc("Semrush : \(Self.units(used)) unités aujourd'hui"),
                                       priority: ModuleLivePriority.activity - 5)
        }
        return snapshot
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        settingsObserver = NotificationCenter.default.addObserver(forName: Self.settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
        restart()
    }

    func stop() {
        onChange = nil
        polling?.cancel()
        polling = nil
        problem = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
    }

    func perform(_ action: ModuleAction) {
        if hasKey { NSWorkspace.shared.open(Self.unitsPage) } else { openSettings() }
    }

    /// One reading of the balance.
    func look() async {
        do {
            let next = SemrushDay.after(day, reading: try await api.balance(), at: Date())
            next.save(to: defaults)
            day = next
            problem = nil
        } catch {
            problem = error
        }
        onChange?()
    }

    // MARK: - Private

    /// After a change of the settings too: the day is read again (a new key starts it over).
    private func restart() {
        polling?.cancel()
        day = SemrushDay.load(from: defaults)
        problem = nil
        guard hasKey else {
            onChange?()
            return
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.look()
                try? await Task.sleep(for: Self.interval, tolerance: .seconds(10))
            }
        }
    }
}

/// The first balance read today and the latest one: how many units went since this morning, the
/// whole team included (the balance is the account's). Kept in the defaults, so a relaunch keeps it.
struct SemrushDay: Codable, Equatable, Sendable {
    static let key = "semrush.day"

    /// "2026-11-20", in the person's calendar.
    var day: String
    var start: Int
    var latest: Int

    var used: Int { max(0, start - latest) }

    /// What was used on `date`'s day: nothing yet when this reading is from another day.
    func used(on date: Date, calendar: Calendar = .current) -> Int {
        day == Self.name(of: date, calendar: calendar) ? used : 0
    }

    /// The day after a new reading. A new day, or a balance that went up (units renewed or bought),
    /// counts again from this reading.
    static func after(_ previous: SemrushDay?, reading balance: Int, at date: Date, calendar: Calendar = .current) -> SemrushDay {
        let day = name(of: date, calendar: calendar)
        guard var current = previous, current.day == day, balance <= current.latest else {
            return SemrushDay(day: day, start: balance, latest: balance)
        }
        current.latest = balance
        return current
    }

    static func load(from defaults: UserDefaults = .standard) -> SemrushDay? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SemrushDay.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    private static func name(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
