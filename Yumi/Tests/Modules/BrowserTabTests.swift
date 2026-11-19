import Testing
import Foundation

@Suite struct BrowserTabTests {
    @Test func asksDiaOnlyForItsYouTubeTabs() throws {
        let script = try #require(BrowserTab.script(browser: "company.thebrowser.dia"))
        #expect(script.contains("tell application id \"company.thebrowser.dia\""))
        #expect(script.contains("contains \"youtube.com/\"") && script.contains("execute t javascript"))
        // The probe sits inside an AppleScript string: no double quote, no backslash
        #expect(!BrowserTab.probe.contains("\"") && !BrowserTab.probe.contains("\\"))
        #expect(BrowserTab.script(browser: "com.google.Chrome") == nil)
    }

    @Test func readsTheTabsThePlayingOneFirst() {
        let answer = """
        Accueil - YouTube\thttps://www.youtube.com/\t{"t":0,"d":null,"p":true,"a":null}
        Lueur - Halo Nord - YouTube Music\thttps://music.youtube.com/watch?v=dQw4w9WgXcQ\t{"t":83.5,"d":214.2,"p":false,"a":"https://lh3.googleusercontent.com/cover=w544"}
        Direct - YouTube\thttps://www.youtube.com/watch?v=aaaaaaaaaaa\t{"t":12,"d":null,"p":false,"a":"http://insecure"}
        Sans JavaScript - YouTube\thttps://www.youtube.com/watch?v=bbbbbbbbbbb\t
        \thttps://www.youtube.com/watch?v=ccccccccccc\t
        """
        let tabs = BrowserTab.parse(answer)
        #expect(tabs.map(\.title) == ["Lueur - Halo Nord - YouTube Music", "Direct - YouTube", "Accueil - YouTube", "Sans JavaScript - YouTube"])
        #expect(tabs[0] == BrowserTab(title: "Lueur - Halo Nord - YouTube Music", address: "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
                                      position: 83.5, duration: 214.2, paused: false,
                                      artwork: URL(string: "https://lh3.googleusercontent.com/cover=w544")))
        // A live stream has no length, and a cover is only taken over https
        #expect(tabs[1].duration == nil && tabs[1].artwork == nil)
        // A browser that does not run the JavaScript still gives the title and the address
        #expect(tabs[3] == BrowserTab(title: "Sans JavaScript - YouTube", address: "https://www.youtube.com/watch?v=bbbbbbbbbbb"))
        #expect(BrowserTab.parse("").isEmpty)
    }

    @Test func movesTheVideoOfThatTab() throws {
        let script = try #require(BrowserTab.seekScript(browser: "company.thebrowser.dia",
                                                        address: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=\"3\"", to: 83.46))
        #expect(script.contains("is \"https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=\\\"3\\\"\""))
        #expect(script.contains("v.currentTime=83.5"))
        #expect(BrowserTab.seekScript(browser: "com.apple.Safari", address: "x", to: 1) == nil)
    }
}
