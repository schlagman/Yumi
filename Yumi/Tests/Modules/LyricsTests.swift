import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@Suite struct LyricsTests {
    @Test func readsTimedLines() {
        let lrc = "[ar:Halo Nord]\n[00:12.50]Première ligne\n[00:20.00][01:05.00]Refrain\n[00:30.00]\nsans temps"
        #expect(Lyrics.parse(lrc) == [
            Lyrics.Line(time: 12.5, text: "Première ligne"),
            Lyrics.Line(time: 20, text: "Refrain"),
            Lyrics.Line(time: 30, text: ""),
            Lyrics.Line(time: 65, text: "Refrain"),
        ])
        #expect(Lyrics.parse("").isEmpty)
    }

    @Test func showsTheLineSungAndTheNext() {
        let lines = Lyrics.parse("[00:10.00]Un\n[00:20.00]\n[00:30.00]Trois\n[00:40.00]Quatre\n[00:50.00]Cinq")
        #expect(Lyrics.around(5, in: lines).isEmpty)
        #expect(Lyrics.around(10, in: lines) == ["Un", "♪", "Trois", "Quatre"])
        #expect(Lyrics.around(25, in: lines) == ["♪", "Trois", "Quatre", "Cinq"])
        #expect(Lyrics.around(99, in: lines) == ["Cinq"])
    }

    @Test func picksAResultOfTheSameLength() throws {
        let json = """
        [{"duration": 300, "syncedLyrics": "[00:01.00]Live"},
         {"duration": 214, "syncedLyrics": null},
         {"duration": 213, "syncedLyrics": "[00:01.00]Studio"}]
        """
        #expect(try Lyrics.decode(Data(json.utf8), duration: 212).map(\.text) == ["Studio"])
        #expect(try Lyrics.decode(Data(json.utf8), duration: nil).map(\.text) == ["Live"])
        #expect(try Lyrics.decode(Data(json.utf8), duration: 100).isEmpty)
        #expect(try Lyrics.decode(Data("[]".utf8), duration: nil).isEmpty)
    }

    @Test func findsTheSongInAVideoTitle() {
        for title in ["Halo Nord - Lueur (Clip officiel)", "Halo Nord - Lueur [Lyrics] | 4K", "Halo Nord - Lueur"] {
            let song = Lyrics.song(inVideoTitle: title)
            #expect(song?.title == "Lueur")
            #expect(song?.artist == "Halo Nord")
        }
        #expect(Lyrics.song(inVideoTitle: "Recette des crêpes en 5 minutes") == nil)
        #expect(Lyrics.song(inVideoTitle: "Halo Nord - (Live)") == nil)
    }

    @Test func asksLRCLIBForTitleAndArtistOnly() {
        let url = Lyrics.searchURL(title: "Lueur & co", artist: "Halo Nord")
        #expect(url.host == "lrclib.net")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["track_name", "artist_name"])
        #expect(items.first?.value == "Lueur & co")
    }
}

@Suite struct MusicArtworkTests {
    @Test func findsTheVideo() {
        #expect(MusicArtwork.videoID(in: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3") == "dQw4w9WgXcQ")
        #expect(MusicArtwork.videoID(in: "https://music.youtube.com/watch?list=RD&v=a1B2c3D4e5_") == "a1B2c3D4e5_")
        #expect(MusicArtwork.videoID(in: "https://www.youtube.com/shorts/a1B2c3D4e5-") == "a1B2c3D4e5-")
        #expect(MusicArtwork.videoID(in: "https://www.youtube.com/") == nil)
    }

    @Test func downloadsCoversOnlyFromWhatThePlayerSaid() {
        #expect(MusicArtwork.imageURL(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", player: .youtube)?.absoluteString
                == "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
        #expect(MusicArtwork.imageURL(from: "http://i.scdn.co/image/ab67\n", player: .spotify)?.absoluteString == "https://i.scdn.co/image/ab67")
        #expect(MusicArtwork.imageURL(from: "", player: .spotify) == nil)
        #expect(MusicArtwork.imageURL(from: "", player: .youtubeMusic) == nil)
        #expect(MusicArtwork.imageURL(from: "https://example.com/a.jpg", player: .music) == nil)
    }

    @Test func asksOnlyBrowsersThatShowTheirTabs() {
        let script = MusicArtwork.tabScript(browser: "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod", title: "Le \"vrai\" titre")
        #expect(script?.contains("tell application id \"com.google.Chrome\"") == true)
        #expect(script?.contains("contains \"Le \\\"vrai\\\" titre\"") == true)
        #expect(MusicArtwork.tabScript(browser: "com.apple.Safari", title: "x")?.contains("(name of t)") == true)
        #expect(MusicArtwork.tabScript(browser: "org.mozilla.firefox", title: "x") == nil)
    }

    @Test func makesTheCoverSmall() throws {
        let context = try #require(CGContext(data: nil, width: 1200, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.96, green: 0.54, blue: 0.85, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let small = try #require(MusicArtwork.thumbnail(png as Data))
        let source = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 256 && image.height == 256)
        #expect(MusicArtwork.thumbnail(Data("pas une image".utf8)) == nil)
    }
}

@Suite struct MusicSnapshotExtrasTests {
    private let lueur = NowPlaying(player: .spotify, title: "Lueur", artist: "Halo Nord", album: "", isPlaying: true, duration: 200)

    @Test func carriesTheCoverAndTheLinesOfThePosition() {
        let lines = Lyrics.parse("[00:10.00]Un\n[00:20.00]Deux")
        let snapshot = MusicSummary.snapshot(lueur, canControl: true, position: 12, artwork: Data([1, 2]), lyrics: lines)
        #expect(snapshot.artwork == Data([1, 2]))
        #expect(snapshot.lyrics == ["Un", "Deux"])
        // Without a position, no line: they would be out of step
        #expect(MusicSummary.snapshot(lueur, canControl: true, artwork: nil, lyrics: lines).lyrics.isEmpty)
        // Nothing playing: nothing left from the last track
        #expect(MusicSummary.snapshot(nil, canControl: true, position: 12, artwork: Data([1]), lyrics: lines).artwork == nil)
    }
}
