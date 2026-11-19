import AppKit

/// The track playing in Music or Spotify. Track changes are pushed by the players; the module
/// only talks to them (AppleScript) when the user presses a button.
@MainActor
final class MusicModule: YumiModule {
    let id = "music"

    #if APPSTORE
    /// The sandbox does not let the app send commands to the players.
    private static let canControl = false
    #else
    private static let canControl = true
    #endif

    private var playing: NowPlaying?
    private var onChange: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// When the current track was paused; nil while it plays.
    private var pausedAt: Date?
    private var lingering: Task<Void, Never>?

    /// Where the track is, kept between two reports of the player.
    private var clock: PlaybackClock?
    private var ticking: Task<Void, Never>?

    /// The cover and the synced lyrics of the current track, once they arrived.
    private var artwork: Data?
    private var lyrics: [Lyrics.Line] = []

    var snapshot: ModuleSnapshot {
        let now = Date()
        return MusicSummary.snapshot(playing, canControl: Self.canControl,
                                     pausedFor: pausedAt.map { now.timeIntervalSince($0) },
                                     position: clock?.position(at: now), artwork: artwork, lyrics: lyrics)
    }

    // MARK: Lifecycle

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        for player in MusicPlayer.allCases {
            guard let name = player.notificationName else { continue }
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] note in
                let update = MusicSummary.update(from: note.userInfo, player: player)
                MainActor.assumeIsolated {
                    self?.receive(update)
                    // Music does not say where the track is: ask, if it is already allowed.
                    if player == .music, case .track(let track) = update, track.isPlaying { self?.askWhatIsPlaying(player) }
                }
            }
            observers.append(observer)
            askWhatIsPlaying(player)
        }
        #if !APPSTORE
        watchTitles()
        seekObserver = NotificationCenter.default.addObserver(forName: .musicSeek, object: nil, queue: .main) { [weak self] note in
            let fraction = note.userInfo?["fraction"] as? Double
            MainActor.assumeIsolated {
                if let fraction { self?.seek(to: fraction) }
            }
        }
        #endif
    }

    // MARK: Players read from their window

    private var titleWatch: Task<Void, Never>?
    /// What the window titles showed at the last look, by player.
    private var titled: [MusicPlayer: NowPlaying] = [:]
    /// When play or pause was last pressed in the island, by player read from its title.
    private var pressedAt: [MusicPlayer: Date] = [:]
    /// How long a press is trusted over the sound: a browser keeps its sound running a moment after a pause.
    private static let pressTrust: TimeInterval = 10
    /// The browsers heard at the last look while showing no known site.
    private var heardBrowsers: Set<String> = []
    /// The browser of the page shown as `.web`, to bring it forward.
    private var webBrowser: String?
    /// The app each player was read in at the last look (a browser, Deezer), to ask it for the cover.
    private var titledIn: [MusicPlayer: String] = [:]
    /// The YouTube tabs of the browsers in `BrowserTab.browsers`, from their last answer.
    private var browserTabs: [String: [BrowserTab]] = [:]
    /// What macOS said was playing at its last change, watched while Dia plays.
    private var systemNowPlaying: SystemNowPlaying?
    #if !APPSTORE
    private let nowPlayingWatch = SystemNowPlaying.Watch()
    #endif
    /// The tab address the cover was looked for from.
    private var artworkFrom: String?
    /// The browsers asked for their tabs right now, and those that refused Yumi.
    private var askingTabs: Set<String> = []
    private var tabsRefused: Set<String> = []
    /// The tab each player was read from at the last look, for its cover and to move in its video.
    private var tabOf: [MusicPlayer: BrowserTab] = [:]
    private var seekObserver: NSObjectProtocol?

    #if !APPSTORE
    /// Every three seconds, the titles of the windows of Deezer, YouTube Music and the browsers:
    /// read through Accessibility (the permission Yumi already has for window titles), only
    /// while the module is selected. Whether the app plays is asked to Core Audio, which needs
    /// no permission: a YouTube page open in front but never started is not a track. A browser
    /// that sends sound with no known site in its windows shows its window title (`.web`).
    private func watchTitles() {
        titleWatch?.cancel()
        titleWatch = Task { [weak self] in
            while !Task.isCancelled {
                self?.lookAtTitles()
                try? await Task.sleep(for: .seconds(3), tolerance: .seconds(1))
            }
        }
    }

    private func lookAtTitles() {
        guard AXIsProcessTrusted() else { return }
        var found: [MusicPlayer: NowPlaying] = [:]
        var foundIn: [MusicPlayer: String] = [:]
        // Asked once per look, and only when a title names a track
        var audible: Set<String>??
        let now = Date()
        // The browsers showing no known site, in case one of them is playing
        var unknowns: [(id: String, name: String, titles: [String])] = []
        var foundTabs: [MusicPlayer: BrowserTab] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let name = app.localizedName ?? ""
            let id = app.bundleIdentifier ?? ""
            let browser = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox", "company.thebrowser.Browser",
                           "company.thebrowser.dia", "com.apple.Safari", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"].contains(id)
            guard browser || id == MusicPlayer.deezer.rawValue || id.hasPrefix("com.google.Chrome.app.")
                    || name.localizedCaseInsensitiveContains("Deezer") || name.localizedCaseInsensitiveContains("YouTube Music") else { continue }
            let titles = Self.windowTitles(of: app.processIdentifier)
            var knownSite = false
            if BrowserTab.browsers.contains(id) {
                if audible == nil { audible = .some(AudioActivity.audibleBundleIDs()) }
                let sound = (audible ?? nil).map { TitlePlayback.isAudible(id, among: $0) }
                // Asked while it plays, and while its track is shown paused, to see it resume or stop
                let shown = playing.map { titledIn[$0.player] == id && (pausedAt.map { now.timeIntervalSince($0) < MusicSummary.pausedLinger } ?? true) } ?? false
                if sound == true || shown {
                    watchNowPlaying()
                    askTabs(of: id)
                } else if nowPlayingWatch.isRunning || systemNowPlaying != nil {
                    nowPlayingWatch.stop()
                    systemNowPlaying = nil
                }
                // What macOS says it plays, whatever the window in front
                if let system = systemNowPlaying, system.isFrom(id), let title = system.title?.nonEmptyTrimmed {
                    let tab = BrowserTab.playing(title, among: browserTabs[id] ?? [])
                    let player: MusicPlayer = tab.map { $0.isMusic ? .youtubeMusic : .youtube } ?? .web
                    if found[player] == nil {
                        // A YouTube video keeps its title whole, as from a window: its channel is not an artist
                        let artist = player == .youtube ? "" : system.artist?.nonEmptyTrimmed ?? (player == .web ? name : "")
                        found[player] = NowPlaying(player: player, title: title, artist: artist, album: player == .youtube ? "" : system.album ?? "",
                                                   isPlaying: system.playing, duration: system.duration, position: system.position(at: now))
                        foundIn[player] = id
                        foundTabs[player] = tab
                        if player == .web { webBrowser = id }
                    }
                    continue
                }
            }
            for title in titles {
                guard let track = MusicTitles.parse(title, appName: name) else { continue }
                knownSite = true
                guard found[track.player] == nil else { continue }
                // A title does not say whether it is paused: the sound of its app does
                if audible == nil { audible = .some(AudioActivity.audibleBundleIDs()) }
                let sound = (audible ?? nil).map { TitlePlayback.isAudible(id, among: $0) }
                let pressed = pressedAt[track.player].map { now.timeIntervalSince($0) < Self.pressTrust } ?? false
                guard let isPlaying = TitlePlayback.isPlaying(title: track.title, previous: titled[track.player],
                                                              audible: sound, pressedRecently: pressed) else { continue }
                found[track.player] = NowPlaying(player: track.player, title: track.title, artist: track.artist, album: "", isPlaying: isPlaying)
                foundIn[track.player] = id
            }
            // Not Dia's: the page in front is rarely what plays there (a contact card is not a song)
            if browser, !knownSite, BrowserFallback.canTellItsSound(id), !BrowserTab.browsers.contains(id) { unknowns.append((id, name, titles)) }
        }
        var heard: Set<String> = []
        // A page of Dia's that macOS says plays is already shown as `.web`
        if !unknowns.isEmpty, found[.web] == nil {
            if audible == nil { audible = .some(AudioActivity.audibleBundleIDs()) }
            let sounds = (audible ?? nil)
            for browser in unknowns where sounds.map({ TitlePlayback.isAudible(browser.id, among: $0) }) == true { heard.insert(browser.id) }
            // The one playing, or else the one already shown, to show it paused
            if let unknown = unknowns.first(where: { heard.contains($0.id) }) ?? unknowns.first(where: { $0.name == titled[.web]?.artist }) {
                let sound = sounds.map { TitlePlayback.isAudible(unknown.id, among: $0) }
                // The page already shown, if it is still this browser's
                let previous = titled[.web].flatMap { $0.artist == unknown.name ? $0 : nil }
                let pressed = pressedAt[.web].map { now.timeIntervalSince($0) < Self.pressTrust } ?? false
                if let title = BrowserFallback.title(among: unknown.titles, previous: previous?.title),
                   let isPlaying = BrowserFallback.isPlaying(title: title, previous: previous, audible: sound,
                                                             heardBefore: heardBrowsers.contains(unknown.id), pressedRecently: pressed) {
                    found[.web] = NowPlaying(player: .web, title: title, artist: unknown.name, album: "", isPlaying: isPlaying)
                    webBrowser = unknown.id
                }
            }
        }
        heardBrowsers = heard
        titledIn = foundIn
        tabOf = foundTabs
        for player in Set(titled.keys).subtracting(found.keys) { receive(.stopped(player)) }
        for (_, track) in found where titled[track.player] != track { receive(.track(track)) }
        titled = found
        // The tab went on to another song after the cover was looked for: look again
        if let playing, let tab = tabOf[playing.player], tab.address != artworkFrom { fetchArtwork(playing) }
    }

    private static func windowTitles(of pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.prefix(12).compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
            return title as? String
        }
    }

    /// Asks `browser` for its YouTube tabs, for the next look. The first time may show the
    /// system's Automation dialog; refused, it is not asked again until Yumi restarts.
    private func askTabs(of browser: String) {
        guard !askingTabs.contains(browser), !tabsRefused.contains(browser), let script = BrowserTab.script(browser: browser) else { return }
        askingTabs.insert(browser)
        PlayerScripting.run(script, on: .youtube, askingFirst: true) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.askingTabs.remove(browser)
                switch result {
                case .success(let answer):
                    let tabs = BrowserTab.parse(answer.text)
                    guard tabs != self.browserTabs[browser] else { return }
                    self.browserTabs[browser] = tabs
                    // A tab gone on to the next song: its cover, at once
                    if self.titleWatch != nil { self.lookAtTitles() }
                case .failure(.notAllowed): self.tabsRefused.insert(browser); self.browserTabs[browser] = nil
                case .failure: self.browserTabs[browser] = nil
                }
            }
        }
    }

    /// Watches what macOS says plays: a change (another song, a pause) is looked at at once,
    /// without waiting for the next look, as Spotify's own news are.
    private func watchNowPlaying() {
        nowPlayingWatch.start { [weak self] now in
            guard let self, self.titleWatch != nil else { return }
            self.systemNowPlaying = now
            self.lookAtTitles()
        }
    }

    /// The Mac's media keys: whatever app plays (a browser tab, Deezer) receives them.
    static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                                 windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
    #endif

    func stop() {
        onChange = nil
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers = []
        titleWatch?.cancel()
        titleWatch = nil
        titled = [:]
        pressedAt = [:]
        heardBrowsers = []
        webBrowser = nil
        titledIn = [:]
        browserTabs = [:]
        #if !APPSTORE
        nowPlayingWatch.stop()
        #endif
        systemNowPlaying = nil
        artworkFrom = nil
        tabOf = [:]
        if let seekObserver { NotificationCenter.default.removeObserver(seekObserver) }
        seekObserver = nil
        artwork = nil
        lyrics = []
        playing = nil
        pausedAt = nil
        lingering?.cancel()
        lingering = nil
        clock = nil
        ticking?.cancel()
        ticking = nil
    }

    private func receive(_ update: PlayerUpdate) {
        let next = MusicSummary.apply(update, to: playing)
        guard next != playing, onChange != nil else { return }
        let wasPaused = playing.map { !$0.isPlaying } ?? false
        let newTrack = !(next.map { new in playing?.isSameTrack(as: new) ?? false } ?? false)
        clock = PlaybackClock.next(clock, from: playing, to: next, now: Date())
        playing = next
        if newTrack { trackChanged() }
        notePause(wasPaused: wasPaused)
        syncTicking()
        onChange?()
    }

    /// Another track, or none: its cover and its lyrics are asked again.
    private func trackChanged() {
        artwork = nil
        lyrics = []
        guard let playing else { return }
        #if !APPSTORE
        fetchArtwork(playing)
        #endif
        fetchLyrics(playing)
    }

    /// The synced lyrics of `track` from LRCLIB, when the user turned them on. A YouTube video is
    /// looked up only when its title names an artist; a page that is not a known site never is.
    private func fetchLyrics(_ track: NowPlaying) {
        guard UserDefaults.standard.bool(forKey: Lyrics.enabledKey), track.player != .web,
              let song = track.artist.isEmpty ? Lyrics.song(inVideoTitle: track.title) : (title: track.title, artist: track.artist)
        else { return }
        Task { [weak self] in
            let lines = await Lyrics.fetch(title: song.title, artist: song.artist, duration: track.duration)
            // Arrived after the track changed: not this one's
            guard let self, !lines.isEmpty, self.playing?.isSameTrack(as: track) == true else { return }
            self.lyrics = lines
            self.syncTicking()
            self.onChange?()
        }
    }

    #if !APPSTORE
    /// The cover of `track`: the picture itself from Music, its address from Spotify, the video's
    /// thumbnail for YouTube and YouTube Music (from the address of their tab). Asking the app may
    /// show the system's Automation dialog once.
    private func fetchArtwork(_ track: NowPlaying) {
        let script: String
        switch track.player {
        case .music:   script = "tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track"
        case .spotify: script = "tell application id \"com.spotify.client\" to get artwork url of current track"
        case .youtube, .youtubeMusic:
            // Read from the tab: its address, and maybe its cover, are already known
            if let tab = tabOf[track.player] {
                // The tab still shows the song before: its cover comes once it moves on
                guard tab.address != artworkFrom else { return }
                artworkFrom = tab.address
                guard let url = MusicArtwork.imageURL(from: tab.address, player: track.player) else { return }
                Task { @MainActor [weak self] in
                    guard let download = try? await URLSession.shared.data(from: url) else { return }
                    guard let self, self.playing?.isSameTrack(as: track) == true, let small = MusicArtwork.thumbnail(download.0) else { return }
                    self.artwork = small
                    self.onChange?()
                }
                return
            }
            guard let browser = titledIn[track.player], let tab = MusicArtwork.tabScript(browser: browser, title: track.title) else { return }
            script = tab
        default: return
        }
        PlayerScripting.run(script, on: track.player, askingFirst: true) { [weak self] result in
            guard case .success(let answer) = result else { return }
            Task { @MainActor in
                var picture = answer.data
                if track.player != .music {
                    guard let url = MusicArtwork.imageURL(from: answer.text, player: track.player),
                          let download = try? await URLSession.shared.data(from: url) else { return }
                    picture = download.0
                }
                guard let self, self.playing?.isSameTrack(as: track) == true, let small = MusicArtwork.thumbnail(picture) else { return }
                self.artwork = small
                self.onChange?()
            }
        }
    }
    #endif

    /// The playback bar moves every second while a track with a known position plays, and so do
    /// the lyrics: for a player read from its title, from the moment Yumi saw the track start.
    private func syncTicking() {
        if clock?.isRunning == true, playing?.duration != nil || !lyrics.isEmpty, onChange != nil {
            guard ticking == nil else { return }
            ticking = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    self?.onChange?()
                }
            }
        } else {
            ticking?.cancel()
            ticking = nil
        }
    }

    /// A paused track leaves the folded island after a while: report again when that moment comes.
    private func notePause(wasPaused: Bool) {
        guard let playing, !playing.isPlaying else {
            pausedAt = nil
            lingering?.cancel()
            lingering = nil
            return
        }
        // Still paused (the player only refreshed its details): the clock keeps running.
        if wasPaused, pausedAt != nil { return }
        pausedAt = Date()
        lingering?.cancel()
        lingering = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MusicSummary.pausedLinger(for: playing.player) + 1))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    // MARK: Actions

    func perform(_ action: ModuleAction) {
        guard let playing, Self.canControl else {
            open(playing?.player ?? .music)
            return
        }
        #if !APPSTORE
        guard playing.player.isScriptable else {
            // NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18
            Self.mediaKey(action == .primary ? 16 : action == .secondary ? 17 : 18)
            if action == .primary {
                var toggled = playing
                toggled.isPlaying.toggle()
                titled[playing.player] = toggled
                pressedAt[playing.player] = Date()
                receive(.track(toggled))
            }
            return
        }
        let command = action == .primary ? "playpause" : action == .secondary ? "next track" : "previous track"
        PlayerScripting.run("tell application id \"\(playing.player.rawValue)\" to \(command)", on: playing.player, askingFirst: true) { result in
            // Refused: the only way back is the Automation pane of System Settings.
            if case .failure(.notAllowed) = result {
                Task { @MainActor in NSWorkspace.shared.open(PrivacySettings.automation) }
            }
        }
        #endif
    }

    #if !APPSTORE
    /// Moves in the track, to `fraction` of its length: Music and Spotify through AppleScript, a
    /// browser's track through macOS. Nothing for a track of unknown length.
    private func seek(to fraction: Double) {
        guard Self.canControl, let playing, let duration = playing.duration, duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * duration
        if playing.player.isScriptable {
            PlayerScripting.run("tell application id \"\(playing.player.rawValue)\" to set player position to \(Int(seconds))",
                                on: playing.player, askingFirst: true) { _ in }
        } else if let browser = titledIn[playing.player], BrowserTab.browsers.contains(browser) {
            // Its track is the one macOS shows as playing: moved through macOS
            SystemNowPlaying.run(SystemNowPlaying.seekScript(to: seconds)) { _ in }
            // Until macOS answers again, its last answer says the new place
            systemNowPlaying?.elapsed = seconds
            systemNowPlaying?.timestamp = Date().timeIntervalSince1970
        } else {
            return
        }
        // The bar goes there at once, without waiting for the player to say so
        clock = PlaybackClock(position: seconds, since: Date(), isRunning: playing.isPlaying)
        onChange?()
    }
    #endif

    /// What the agent asks (`control_music`), with the module's own buttons. nil when done,
    /// otherwise why not. With nothing playing, « play » opens the player.
    func control(_ command: MusicCommand) -> String? {
        switch command {
        case .play:
            if playing?.isPlaying == true { return nil }
            perform(.primary)
        case .pause:
            guard playing?.isPlaying == true else { return loc("rien ne joue en ce moment") }
            perform(.primary)
        case .next, .previous:
            guard playing != nil else { return loc("rien ne joue en ce moment") }
            perform(command == .next ? .secondary : .previous)
        }
        return nil
    }

    private func open(_ player: MusicPlayer) {
        if player == .web {
            if let webBrowser { NSRunningApplication.runningApplications(withBundleIdentifier: webBrowser).first?.activate() }
            return
        }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else {
            if let url = player.webURL { NSWorkspace.shared.open(url) }
            return
        }
        NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    // MARK: Initial state

    /// A track already playing when the module starts was announced before Yumi listened.
    /// Ask the player, but only if it is running and the user already allowed Yumi to talk to it:
    /// this never opens an app and never shows a permission dialog.
    private func askWhatIsPlaying(_ player: MusicPlayer) {
        #if !APPSTORE
        guard player.isScriptable else { return }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == player.rawValue }) else { return }
        let script = """
        tell application id "\(player.rawValue)"
            if player state is stopped then return ""
            set t to current track
            return (name of t) & tab & (artist of t) & tab & (album of t) & tab & (player state as text) & tab & (player position as text) & tab & (duration of t as text)
        end tell
        """
        PlayerScripting.run(script, on: player, askingFirst: false) { [weak self] result in
            guard case .success(let answer) = result else { return }
            let update = MusicSummary.update(fromScriptResult: answer.text, player: player)
            Task { @MainActor in
                // Only a track that is playing is news: a stopped player says nothing, and a track
                // found paused was paused at an unknown time, not just now.
                if case .track(let track) = update, track.isPlaying { self?.receive(update) }
            }
        }
        #endif
    }
}

#if !APPSTORE
/// Sends AppleScript to a player, off the main thread: the first command can wait on a permission dialog.
private enum PlayerScripting {
    enum Failure: Error { case notAllowed, failed }

    private static let queue = DispatchQueue(label: "\(AppIdentity.notificationPrefix).player-scripting")
    /// AppleScript error for a refused Automation permission.
    private static let notAuthorized = -1743

    /// What a script answered: as text, and as raw bytes (a picture).
    struct Answer: Sendable {
        var text: String
        var data: Data
    }

    /// - Parameter askingFirst: false to give up silently when the permission was never granted,
    ///   instead of showing the system dialog.
    static func run(_ source: String, on player: MusicPlayer, askingFirst: Bool,
                    completion: @escaping @Sendable (Result<Answer, Failure>) -> Void) {
        let allowedKey = "playerAllowed.\(player.rawValue)"
        // The system can tell whether the permission was granted (AEDeterminePermissionToAutomateTarget),
        // but that call sometimes never returns, and it held every later pause and next behind it
        // on this queue. Yumi remembers instead that a command to this player went through.
        if !askingFirst, !UserDefaults.standard.bool(forKey: allowedKey) {
            completion(.failure(.notAllowed))
            return
        }
        queue.async {
            var error: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int
                if code == notAuthorized { UserDefaults.standard.set(false, forKey: allowedKey) }
                completion(.failure(code == notAuthorized ? .notAllowed : .failed))
            } else {
                UserDefaults.standard.set(true, forKey: allowedKey)
                completion(.success(Answer(text: output?.stringValue ?? "", data: output?.data ?? Data())))
            }
        }
    }
}
#endif
