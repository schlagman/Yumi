import Testing
import Foundation

@Suite struct SystemNowPlayingTests {
    @Test func readsWhatMacOSSays() throws {
        let answer = #"{"bundle":"company.thebrowser.dia","parent":null,"playing":true,"title":"Lueur","artist":"Halo Nord","album":null,"duration":220.36,"elapsed":63.1,"timestamp":1000}"#
        let now = try #require(SystemNowPlaying.parse(answer))
        #expect(now.isFrom("company.thebrowser.dia") && !now.isFrom("com.spotify.client"))
        #expect(now.title == "Lueur" && now.artist == "Halo Nord" && now.album == nil && now.duration == 220.36)
        // It went on since macOS noted the place; paused, it stays there
        #expect(now.position(at: Date(timeIntervalSince1970: 1010)) == 73.1)
        var paused = now
        paused.playing = false
        #expect(paused.position(at: Date(timeIntervalSince1970: 1010)) == 63.1)
        // Nothing playing anywhere
        #expect(SystemNowPlaying.parse(#"{"bundle":null,"parent":null,"playing":false,"title":null,"artist":null,"album":null,"duration":null,"elapsed":null,"timestamp":null}"#)?.title == nil)
        #expect(SystemNowPlaying.parse("") == nil)
    }

    @Test func aHelperCountsForItsApp() {
        let helper = SystemNowPlaying(bundle: "company.thebrowser.browser.helper", parent: "company.thebrowser.dia", playing: true)
        #expect(helper.isFrom("company.thebrowser.dia"))
    }

    @Test func theWatchEndsWithYumi() {
        // Each change is one line, and the loop stops once Yumi is gone (its parent becomes launchd)
        #expect(SystemNowPlaying.watchScript.contains("line + '\\n'"))
        #expect(SystemNowPlaying.watchScript.contains("while ($.getppid() !== 1)"))
    }

    @Test func movesWithADotWhateverTheLanguage() {
        #expect(SystemNowPlaying.seekScript(to: 83.46).contains("MRMediaRemoteSetElapsedTime(83.5)"))
        #expect(SystemNowPlaying.seekScript(to: -4).contains("MRMediaRemoteSetElapsedTime(0.0)"))
    }
}
