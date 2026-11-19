import Testing
import Foundation

@Suite struct BrowserTabTests {
    @Test func asksDiaOnlyForItsYouTubeTabs() throws {
        let script = try #require(BrowserTab.script(browser: "company.thebrowser.dia"))
        #expect(script.contains("tell application id \"company.thebrowser.dia\"") && script.contains("contains \"youtube.com/\""))
        // Inside the browser's block, `tab` is its tab class, not the character: named before it
        let block = try #require(script.range(of: "tell application"))
        #expect(script[..<block.lowerBound].contains("set separator to tab"))
        #expect(!script[block.lowerBound...].contains("& tab &"))
        #expect(BrowserTab.script(browser: "com.google.Chrome") == nil)
    }

    @Test func findsTheTabOfWhatPlays() {
        let tabs = BrowserTab.parse("""
        Accueil - YouTube\thttps://www.youtube.com/
        (2) Lueur (clip officiel) - YouTube\thttps://www.youtube.com/watch?v=aaaaaaaaaaa
        YouTube Music\thttps://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD
        sans adresse
        """)
        #expect(tabs.count == 3)
        // A video is found by its title
        #expect(BrowserTab.playing("Lueur (clip officiel)", among: tabs)?.address == "https://www.youtube.com/watch?v=aaaaaaaaaaa")
        // A song of YouTube Music by its tab, whose title never names it
        #expect(BrowserTab.playing("Halo", among: tabs)?.isMusic == true)
        // YouTube Music away from its player page still tells the site, without a video for the cover
        let browsing = [BrowserTab(title: "YouTube Music", address: "https://music.youtube.com/library")]
        #expect(BrowserTab.playing("Halo", among: browsing)?.isMusic == true)
        #expect(BrowserTab.playing("Halo", among: [tabs[0]]) == nil)
    }
}
