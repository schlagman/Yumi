import Foundation

/// What macOS says is playing (the « Now Playing » of Control Center): the app, the title, the
/// artist, where the track is. Since macOS 15.4 only Apple's own programs may read it, so it is
/// asked through `osascript` (JavaScript for Automation), which is one. Whatever window is in
/// front, a browser's tab playing behind is found.
struct SystemNowPlaying: Decodable, Equatable, Sendable {
    var bundle: String?
    var parent: String?
    var playing: Bool
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    /// When `elapsed` was true, in seconds since 1970.
    var timestamp: Double?

    /// Prints the Now Playing as one line of JSON.
    static let readScript = """
    ObjC.import('Foundation');
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
    const R = $.NSClassFromString('MRNowPlayingRequest');
    const path = R.localNowPlayingPlayerPath, item = R.localNowPlayingItem;
    const info = item.isNil() ? null : item.nowPlayingInfo;
    const value = k => { if (!info || info.isNil()) return null; const x = info.objectForKey(k); return x.isNil() ? null : ObjC.unwrap(x); };
    const stamp = info && !info.isNil() ? info.objectForKey('kMRMediaRemoteNowPlayingInfoTimestamp') : null;
    JSON.stringify({
      bundle: path.isNil() ? null : ObjC.unwrap(path.client.bundleIdentifier),
      parent: path.isNil() ? null : ObjC.unwrap(path.client.parentApplicationBundleIdentifier),
      playing: ObjC.unwrap(R.localIsPlaying) === true,
      title: value('kMRMediaRemoteNowPlayingInfoTitle'), artist: value('kMRMediaRemoteNowPlayingInfoArtist'),
      album: value('kMRMediaRemoteNowPlayingInfoAlbum'), duration: value('kMRMediaRemoteNowPlayingInfoDuration'),
      elapsed: value('kMRMediaRemoteNowPlayingInfoElapsedTime'),
      timestamp: stamp && !stamp.isNil() ? stamp.timeIntervalSince1970 : null
    });
    """

    /// Moves the track macOS shows as playing to `seconds`.
    static func seekScript(to seconds: TimeInterval) -> String {
        """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
        ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
        $.MRMediaRemoteSetElapsedTime(\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))));
        delay(0.3);
        """
    }

    static func parse(_ answer: String) -> SystemNowPlaying? {
        try? JSONDecoder().decode(SystemNowPlaying.self, from: Data(answer.utf8))
    }

    /// True when it is `app` (or one of its helpers, which name it as their parent) that plays.
    func isFrom(_ app: String) -> Bool { bundle == app || parent == app }

    /// Where the track is at `now`: the last reported place, plus the time since while it plays.
    func position(at now: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        guard playing, let timestamp else { return elapsed }
        return elapsed + max(0, now.timeIntervalSince1970 - timestamp)
    }

    #if !APPSTORE
    /// Runs `script` in `osascript`, off the main thread, and gives back what it printed (nil on
    /// failure, or after five seconds).
    static func run(_ script: String, completion: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return completion(nil) }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            completion(process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
        }
    }
    #endif
}
