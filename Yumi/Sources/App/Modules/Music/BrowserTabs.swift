import Foundation

/// A YouTube tab, asked to the browser through AppleScript: its title and address. It tells
/// YouTube from YouTube Music for the track macOS says the browser plays, and gives the video
/// whose thumbnail is the cover. (Dia runs no JavaScript sent with Apple Events unless started
/// with a developer flag, so nothing more is asked.)
struct BrowserTab: Equatable, Sendable {
    var title: String
    var address: String

    /// shortcut: Dia only, the browser whose window titles are cut; add a browser here to read its tabs too.
    static let browsers: Set<String> = ["company.thebrowser.dia"]

    /// AppleScript answering one line per YouTube tab, title and address separated by a tab.
    /// nil for a browser not in `browsers`.
    static func script(browser: String) -> String? {
        guard browsers.contains(browser) else { return nil }
        // The tab character is named outside the browser's block: inside it, `tab` is the browser's tab class
        return """
        set separator to tab
        with timeout of 5 seconds
            tell application id "\(browser)"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) contains "youtube.com/" then set out to out & (title of t) & separator & (URL of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
        end timeout
        """
    }

    /// The tabs in what `script` answered.
    static func parse(_ answer: String) -> [BrowserTab] {
        answer.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return fields.count == 2 ? BrowserTab(title: fields[0], address: fields[1]) : nil
        }
    }

    /// The tab playing `title`: a YouTube video named so, or else the YouTube Music tab, on a song
    /// first (its title stays « YouTube Music »). nil when no tab is a match.
    static func playing(_ title: String, among tabs: [BrowserTab]) -> BrowserTab? {
        tabs.first { !$0.isMusic && !title.isEmpty && $0.title.localizedCaseInsensitiveContains(title) }
            ?? tabs.first { $0.isMusic && MusicArtwork.videoID(in: $0.address) != nil }
            ?? tabs.first(where: \.isMusic)
    }

    var isMusic: Bool { address.contains("music.youtube.com") }
}
