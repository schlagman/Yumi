#if !APPSTORE
import AppKit
import SwiftUI

/// The track playing, on the lock screen: the cover, a card with its buttons, the line sung now.
/// No public API lets an app draw there: the window goes to a space of SkyLight (a private
/// framework) that stays above the lock screen. Found at run time, so on a macOS without it
/// nothing shows and nothing breaks. Never in the App Store build.
@MainActor
final class LockScreenMusic {
    private lazy var space = LockScreenSpace.make()
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { locked ? self?.show() : self?.hide() }
            })
        }
    }

    private func show() {
        guard let space, let screen = NSScreen.screens.first else { return }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let size = panel.frame.size
        // Between the clock and the user's picture, a little under the middle
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.frame.minY + screen.frame.height * 0.43 - size.height / 2))
        panel.orderFrontRegardless()
        space.add(panel)
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.contentView = NSHostingView(rootView: LockScreenMusicView(state: .shared))
        return panel
    }
}

/// A SkyLight space drawn above everything, the lock screen included. nil when this macOS no
/// longer has the functions.
private struct LockScreenSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private let connection: Int32
    private let space: UInt64
    private let addWindows: AddWindows

    static func make() -> LockScreenSpace? {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let main = dlsym(skyLight, "SLSMainConnectionID"), let create = dlsym(skyLight, "SLSSpaceCreate"),
              let level = dlsym(skyLight, "SLSSpaceSetAbsoluteLevel"), let show = dlsym(skyLight, "SLSShowSpaces"),
              let add = dlsym(skyLight, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return nil }
        let connection = unsafeBitCast(main, to: MainConnection.self)()
        let space = unsafeBitCast(create, to: SpaceCreate.self)(connection, 1, 0)
        guard space != 0 else { return nil }
        // SkyLight's absolute levels: 300 is the lock screen itself (anything lower shows only until
        // it draws), 400 the notifications shown over it
        _ = unsafeBitCast(level, to: SetLevel.self)(connection, space, 400)
        _ = unsafeBitCast(show, to: ShowSpaces.self)(connection, [NSNumber(value: space)] as CFArray)
        return LockScreenSpace(connection: connection, space: space, addWindows: unsafeBitCast(add, to: AddWindows.self))
    }

    func add(_ window: NSWindow) {
        _ = addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }
}

/// What the lock screen shows: the music module's snapshot, nothing when no track is playing or
/// paused a moment ago. Its buttons press the same actions as the island's.
private struct LockScreenMusicView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            if let music = state.modules.first(where: { $0.id == "music" }), let live = music.live {
                cover(music)
                card(music, live: live)
                if let line = music.lyrics.first {
                    Text(verbatim: line)
                        .font(.system(size: 17, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.45), radius: 6)
                        .frame(width: 320)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func cover(_ music: ModuleSnapshot) -> some View {
        ZStack {
            Color.white.opacity(0.12)
            if let image = music.artwork.flatMap(NSImage.init(data:)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 54)).foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private func card(_ music: ModuleSnapshot, live: ModuleLive) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: music.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(verbatim: music.subtitle).font(.system(size: 13)).opacity(0.65).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: music.colorHex))
                    .opacity(live.priority >= ModuleLivePriority.activity ? 1 : 0.35)
            }
            if let progress = music.progress {
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white.opacity(0.9))
                                .frame(width: geometry.size.width * min(max(progress.fraction, 0), 1))
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(verbatim: progress.leading)
                        Spacer()
                        Text(verbatim: progress.trailing)
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .opacity(0.65)
                }
            }
            // No controls: Yumi cannot drive this player, so no buttons either
            if !live.controls.isEmpty {
                HStack(spacing: 30) {
                    button("backward.fill", label: loc("Précédent"), action: ModuleAction.previous.rawValue)
                    ForEach(live.controls) { control in
                        button(control.symbol, label: control.label, action: control.id)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
    }

    private func button(_ symbol: String, label: String, action: String) -> some View {
        Button {
            NotificationCenter.default.post(name: .moduleAction, object: nil, userInfo: ["module": "music", "action": action])
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif
