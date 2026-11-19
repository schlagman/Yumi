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

    /// Prints the Now Playing as one line of JSON each time it changes, looking twice a second,
    /// until Yumi is gone (its parent becomes launchd).
    static let watchScript = """
    ObjC.import('Foundation');
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
    ObjC.bindFunction('getppid', ['int', []]);
    const R = $.NSClassFromString('MRNowPlayingRequest');
    const stdout = $.NSFileHandle.fileHandleWithStandardOutput;
    function read() {
      const path = R.localNowPlayingPlayerPath, item = R.localNowPlayingItem;
      const info = item.isNil() ? null : item.nowPlayingInfo;
      const value = k => { if (!info || info.isNil()) return null; const x = info.objectForKey(k); return x.isNil() ? null : ObjC.unwrap(x); };
      const stamp = info && !info.isNil() ? info.objectForKey('kMRMediaRemoteNowPlayingInfoTimestamp') : null;
      return JSON.stringify({
        bundle: path.isNil() ? null : ObjC.unwrap(path.client.bundleIdentifier),
        parent: path.isNil() ? null : ObjC.unwrap(path.client.parentApplicationBundleIdentifier),
        playing: ObjC.unwrap(R.localIsPlaying) === true,
        title: value('kMRMediaRemoteNowPlayingInfoTitle'), artist: value('kMRMediaRemoteNowPlayingInfoArtist'),
        album: value('kMRMediaRemoteNowPlayingInfoAlbum'), duration: value('kMRMediaRemoteNowPlayingInfoDuration'),
        elapsed: value('kMRMediaRemoteNowPlayingInfoElapsedTime'),
        timestamp: stamp && !stamp.isNil() ? stamp.timeIntervalSince1970 : null
      });
    }
    let last = '';
    while ($.getppid() !== 1) {
      const line = read();
      if (line !== last) { stdout.writeData($(line + '\\n').dataUsingEncoding($.NSUTF8StringEncoding)); last = line; }
      delay(0.5);
    }
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
    /// `watchScript` running in `osascript`: each line it prints is handed to `onChange` on the
    /// main thread. Started again by `start` when it ended.
    @MainActor
    final class Watch {
        private var process: Process?

        var isRunning: Bool { process?.isRunning == true }

        func start(onChange: @escaping @MainActor @Sendable (SystemNowPlaying?) -> Void) {
            guard !isRunning else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", SystemNowPlaying.watchScript]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let lines = LineBuffer()
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                // Only the newest line counts: it says what plays now
                guard let line = lines.append(data).last else { return }
                let now = SystemNowPlaying.parse(line)
                Task { @MainActor in onChange(now) }
            }
            do { try process.run() } catch { return }
            self.process = process
        }

        func stop() {
            process?.terminate()
            process = nil
        }
    }

    /// The bytes of a line not yet ended, kept for the next read. Touched from one reading
    /// thread at a time.
    private final class LineBuffer: @unchecked Sendable {
        private var pending = Data()

        func append(_ data: Data) -> [String] {
            pending.append(data)
            guard let end = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
            let complete = pending[..<end]
            pending = Data(pending[pending.index(after: end)...])
            return complete.split(separator: UInt8(ascii: "\n")).compactMap { String(data: Data($0), encoding: .utf8) }
        }
    }

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
