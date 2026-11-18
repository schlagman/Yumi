import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The cover of a track: the picture Music gives, the address Spotify gives, the thumbnail of
/// the video for YouTube and YouTube Music (found from the address of their browser tab).
enum MusicArtwork {
    /// AppleScript that answers the address of the YouTube tab showing `title`, or "". nil for
    /// browsers that do not show their tabs to AppleScript (Firefox).
    static func tabScript(browser: String, title: String) -> String? {
        // An installed web app (YouTube Music) is a window of Chrome itself
        let id = browser.hasPrefix("com.google.Chrome.app.") ? "com.google.Chrome" : browser
        let name: String
        switch id {
        case "com.apple.Safari": name = "name"
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi":
            name = "title"
        default: return nil
        }
        let quoted = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application id "\(id)"
            repeat with w in windows
                repeat with t in tabs of w
                    if (URL of t) contains "youtube.com/" and (\(name) of t) contains "\(quoted)" then return URL of t
                end repeat
            end repeat
        end tell
        return ""
        """
    }

    /// Where to download the cover, from what the player or the browser answered.
    static func imageURL(from answer: String, player: MusicPlayer) -> URL? {
        switch player {
        case .spotify:
            var address = URLComponents(string: answer.trimmingCharacters(in: .whitespacesAndNewlines))
            address?.scheme = "https"
            return address?.host == nil ? nil : address?.url
        case .youtube, .youtubeMusic:
            // 16:9 without black bands, unlike the larger thumbnails
            return videoID(in: answer).flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") }
        default:
            return nil
        }
    }

    /// "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3" → "dQw4w9WgXcQ"; Shorts too.
    static func videoID(in address: String) -> String? {
        guard let range = address.range(of: #"([?&]v=|/shorts/)[A-Za-z0-9_-]{11}"#, options: .regularExpression) else { return nil }
        return String(address[range].suffix(11))
    }

    /// The picture made small, as JPEG: the island draws it at 54 points at most, and the
    /// snapshot carrying it is compared every second while a track plays.
    static func thumbnail(_ data: Data, side: Int = 256) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
