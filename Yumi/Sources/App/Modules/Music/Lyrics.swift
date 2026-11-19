import Foundation

/// Synced lyrics from LRCLIB (lrclib.net): free, no key, no account. Asked only when the user
/// turned them on in Settings; the title and the artist of the track are all it receives.
enum Lyrics {
    static let enabledKey = "musicLyricsEnabled"

    /// One line and the second of the track it starts at.
    struct Line: Equatable, Sendable {
        var time: TimeInterval
        var text: String
    }

    static func searchURL(title: String, artist: String) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        return components.url!
    }

    /// The lines of `title`, empty when LRCLIB has no synced lyrics for it or cannot be reached.
    static func fetch(title: String, artist: String, duration: TimeInterval?) async -> [Line] {
        var request = URLRequest(url: searchURL(title: title, artist: artist), timeoutInterval: 10)
        // LRCLIB asks its clients to say who they are
        request.setValue("Yumi (https://github.com/estebanbaigts/Yumi)", forHTTPHeaderField: "User-Agent")
        guard let answer = try? await URLSession.shared.data(for: request),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? decode(answer.0, duration: duration)) ?? []
    }

    /// The synced lyrics of the first result, and when the track's length is known, of the first
    /// one within three seconds of it: another version of the song would be out of step.
    static func decode(_ data: Data, duration: TimeInterval?) throws -> [Line] {
        struct Result: Decodable {
            let duration: Double?
            let syncedLyrics: String?
        }
        let match = try JSONDecoder().decode([Result].self, from: data).first { result in
            guard let lyrics = result.syncedLyrics, !lyrics.isEmpty else { return false }
            guard let duration, let length = result.duration else { return true }
            return abs(length - duration) <= 3
        }
        return parse(match?.syncedLyrics ?? "")
    }

    /// "[01:02.50] words" lines, in time order. Tags that are not a time ("[ar:Artist]") are
    /// dropped; a line with several times comes back once for each.
    static func parse(_ lrc: String) -> [Line] {
        var lines: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let parts = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { break }
                times.append(minutes * 60 + seconds)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { Line(time: $0, text: text) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// The song a YouTube title names: "Halo Nord - Lueur (Clip officiel)" → "Lueur" by "Halo
    /// Nord". nil when it names no artist: a video that is not a song is not looked up.
    static func song(inVideoTitle title: String) -> (title: String, artist: String)? {
        let parts = title.components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }
        // "(Official Video)", "[Lyrics]", "| Clip officiel"
        let song = parts[1].replacingOccurrences(of: #"\s*[(\[|].*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let artist = parts[0].trimmingCharacters(in: .whitespaces)
        guard !song.isEmpty, !artist.isEmpty else { return nil }
        return (song, artist)
    }

    /// The line sung at `position` and the next three: the wide tile shows them all, the narrow
    /// one the first two. Empty before the first line; a pause in the singing shows as a note.
    static func around(_ position: TimeInterval, in lines: [Line]) -> [String] {
        guard let index = lines.lastIndex(where: { $0.time <= position }) else { return [] }
        return lines[index...].prefix(4).map { $0.text.isEmpty ? "♪" : $0.text }
    }
}
