import Foundation

/// A YouTube tab, asked to the browser through AppleScript: for browsers whose window titles do
/// not name the site (Dia cuts them short), or whose video plays in a tab behind. When the browser
/// runs JavaScript sent with Apple Events, the tab also says where its video is and the cover its
/// page gives the system (the album's, on YouTube Music).
struct BrowserTab: Equatable, Sendable {
    var title: String
    var address: String
    var position: TimeInterval?
    var duration: TimeInterval?
    var paused: Bool?
    var artwork: URL?

    /// shortcut: Dia only, the browser whose window titles are cut; add a Chromium browser here to read its tabs too.
    static let browsers: Set<String> = ["company.thebrowser.dia"]

    /// The video of the page and its media session, as one line of JSON. Single quotes only: it
    /// sits inside an AppleScript string.
    static let probe = "(function(){var v=document.querySelector('video.html5-main-video')||document.querySelector('video');"
        + "var m=navigator.mediaSession&&navigator.mediaSession.metadata;var a=m&&m.artwork&&m.artwork.length?m.artwork[m.artwork.length-1].src:null;"
        + "return JSON.stringify({t:v?v.currentTime:null,d:v&&isFinite(v.duration)?v.duration:null,p:v?v.paused:null,a:a})})()"

    /// AppleScript answering one line per YouTube tab: title, address, and what `probe` found (or
    /// nothing), separated by tabs. nil for a browser not in `browsers`.
    static func script(browser: String) -> String? {
        guard browsers.contains(browser) else { return nil }
        return """
        with timeout of 5 seconds
            tell application id "\(browser)"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) contains "youtube.com/" then
                            set found to ""
                            try
                                set found to execute t javascript "\(probe)"
                            end try
                            set out to out & (title of t) & tab & (URL of t) & tab & found & linefeed
                        end if
                    end repeat
                end repeat
                return out
            end tell
        end timeout
        """
    }

    /// The tabs in what `script` answered; the one playing first.
    static func parse(_ answer: String) -> [BrowserTab] {
        struct Probe: Decodable { var t: Double?; var d: Double?; var p: Bool?; var a: String? }
        let tabs = answer.split(whereSeparator: \.isNewline).compactMap { line -> BrowserTab? in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { return nil }
            let probe = fields.count > 2 ? try? JSONDecoder().decode(Probe.self, from: Data(fields[2].utf8)) : nil
            return BrowserTab(title: fields[0], address: fields[1], position: probe?.t, duration: probe?.d.flatMap { $0 > 0 ? $0 : nil },
                              paused: probe?.p, artwork: probe?.a.flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil })
        }
        return tabs.filter { $0.paused == false } + tabs.filter { $0.paused != false }
    }

    /// AppleScript moving the video of the tab at `address` to `seconds`.
    static func seekScript(browser: String, address: String, to seconds: TimeInterval) -> String? {
        guard browsers.contains(browser) else { return nil }
        let quoted = address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let at = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        return """
        with timeout of 5 seconds
            tell application id "\(browser)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is "\(quoted)" then
                            execute t javascript "(function(){var v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(v)v.currentTime=\(at)})()"
                            return
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        """
    }
}
