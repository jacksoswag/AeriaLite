import AVFoundation
import Foundation
import QuartzCore
import WallpaperExtensionKit

/// AeriaLite's `com.apple.wallpaper` backend. `WallpaperAgent` hosts this process, asks it for one
/// `Wallpaper` per desktop, and composites the returned layer itself, so there is no window, no
/// desktop-level injection, and no Space bookkeeping here. This side owns video transport only.
@main
struct AeriaLiteWallpaperExtension: WallpaperExtension {
    init() {}

    func makeWallpaper(
        request: WallpaperCreationRequest,
        host: any WallpaperHostProxy
    ) async throws -> any Wallpaper {
        await NativeWallpaperSession()
    }
}

/// Owns the layer WallpaperAgent composites, and follows the menu app by polling the command
/// snapshot rather than holding a connection to it: the agent starts and stops this process on its
/// own schedule, so a file both sides replace atomically survives that where a socket would not.
private final class NativeWallpaperSession: Wallpaper, @unchecked Sendable {
    private let root: CALayer
    private let player = AVPlayer()
    private let video: AVPlayerLayer
    private var poller: Timer?
    private var endObserver: NSObjectProtocol?
    private var command: NativeIPC.Command?
    private var actionRevision: UInt64 = 0
    private var cursor = 0

    @MainActor init() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        root = CALayer()
        root.frame = CGRect(origin: .zero, size: bounds.size)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)

        video = AVPlayerLayer(player: player)
        video.frame = root.bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        video.videoGravity = .resizeAspectFill
        video.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(video)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.advance()
            }
        }

        // The run loop owns the timer, so a session the host has dropped would otherwise leave one
        // firing for the life of the process. The weak capture is what makes that detectable.
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
        tick()
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: Wallpaper

    nonisolated var layer: CALayer { root }

    /// The host has always called this on the main thread, but a wrong guess here would trap
    /// inside the process macOS is drawing the desktop from, so the off-thread case hops instead.
    nonisolated func invalidate() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.teardown() } }
        }
    }

    @MainActor private func teardown() {
        poller?.invalidate()
        poller = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    nonisolated func update(request: WallpaperUpdateRequest) async {
        // Placement, Space, and appearance changes are the host's; nothing here reads them.
    }

    /// The still the host shows wherever it cannot run the layer: Mission Control, the wallpaper
    /// grid in System Settings, and the desktop itself while presentation is idle. Refusing here
    /// does not fall back to a capture of the layer—it leaves whatever was on screen before—so the
    /// frame is decoded separately from the playing asset rather than skipped.
    nonisolated func snapshot() async throws -> WallpaperSnapshot {
        guard let playing = await currentAsset() else {
            throw NativeWallpaperError.nothingPlaying
        }
        let generator = AVAssetImageGenerator(asset: playing.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = playing.size
        // A keyframe either side of the playhead is indistinguishable in a wallpaper and spares
        // the generator a walk back through the GOP.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        return try WallpaperSnapshot(image: try await generator.image(at: playing.time).image)
    }

    @MainActor private func currentAsset() -> (asset: AVAsset, time: CMTime, size: CGSize)? {
        guard let item = player.currentItem else { return nil }
        let scale = root.contentsScale
        return (item.asset, player.currentTime(),
                CGSize(width: root.bounds.width * scale, height: root.bounds.height * scale))
    }

    // MARK: Transport

    @MainActor private func tick() {
        guard let next = NativeIPC.readCommand() else {
            player.pause()
            video.isHidden = true
            publishStatus()
            return
        }

        if command?.tracks != next.tracks {
            let showing = currentTrack?.id
            command = next
            if let showing, let moved = next.tracks.firstIndex(where: { $0.id == showing }) {
                cursor = moved
            } else if !next.tracks.indices.contains(cursor) {
                cursor = 0
            }
            if player.currentItem == nil, next.running { open(cursor) }
        } else {
            command = next
        }

        if next.actionRevision != actionRevision {
            actionRevision = next.actionRevision
            apply(next.action)
        }

        if !next.running || next.tracks.isEmpty {
            player.pause()
            video.isHidden = true
        } else {
            video.isHidden = false
            if player.currentItem == nil { open(cursor) }
            if next.paused { player.pause() }
            else if player.rate != Float(next.speed) { player.playImmediately(atRate: Float(next.speed)) }
        }

        publishStatus()
    }

    @MainActor private var currentTrack: NativeIPC.Track? {
        guard let command, command.tracks.indices.contains(cursor) else { return nil }
        return command.tracks[cursor]
    }

    @MainActor private func apply(_ action: NativeIPC.Action?) {
        guard let action, let command, !command.tracks.isEmpty else { return }
        switch action {
        case .play(let index):
            guard command.tracks.indices.contains(index) else { return }
            cursor = index
            open(cursor)
        case .previous:
            cursor = (cursor - 1 + command.tracks.count) % command.tracks.count
            open(cursor)
        case .next:
            advance()
        case .seek(let seconds):
            guard let duration = player.currentItem?.duration.seconds, duration.isFinite else { return }
            let target = min(max(0, seconds), max(0, duration - 0.05))
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    @MainActor private func advance() {
        guard let command, !command.tracks.isEmpty else { return }
        if command.repeatOne {
            player.seek(to: .zero)
        } else if command.shuffle, command.tracks.count > 1 {
            var next = cursor
            while next == cursor { next = Int.random(in: command.tracks.indices) }
            cursor = next
            open(cursor)
        } else {
            cursor = (cursor + 1) % command.tracks.count
            open(cursor)
        }
    }

    @MainActor private func open(_ index: Int) {
        guard let command, command.tracks.indices.contains(index) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let track = command.tracks[index]
        let url = URL(fileURLWithPath: track.path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return advancePastUnreadable() }
        cursor = index
        if url.standardizedFileURL.path.hasPrefix(NativeIPC.root.appendingPathComponent("Cache")
            .standardizedFileURL.path + "/") {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if command.running, !command.paused {
            player.playImmediately(atRate: Float(command.speed))
        }
    }

    @MainActor private func advancePastUnreadable() {
        guard let command, command.tracks.count > 1 else {
            player.replaceCurrentItem(with: nil)
            video.isHidden = true
            return
        }
        for step in 1..<command.tracks.count {
            let candidate = (cursor + step) % command.tracks.count
            if FileManager.default.isReadableFile(atPath: command.tracks[candidate].path) {
                return open(candidate)
            }
        }
        player.replaceCurrentItem(with: nil)
        video.isHidden = true
    }

    @MainActor private func publishStatus() {
        guard let track = currentTrack, let item = player.currentItem else {
            NativeIPC.write(NativeIPC.Status(heartbeat: Date()))
            return
        }
        let duration = item.duration.seconds
        let position = player.currentTime().seconds
        NativeIPC.write(NativeIPC.Status(
            position: position.isFinite ? position : 0,
            duration: duration.isFinite ? duration : 0,
            title: track.title,
            id: track.id,
            actionRevision: actionRevision,
            heartbeat: Date()
        ))
    }
}

private enum NativeWallpaperError: Error {
    case nothingPlaying
}
