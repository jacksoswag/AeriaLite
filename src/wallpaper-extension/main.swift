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

/// One of the two video paths the session alternates between.
///
/// The second exists so the next clip can be decoding, and handing out frames, while the one before
/// it is still on screen. With transitions off it is never given an item at all, and even with them
/// on it is empty for all but the last second or two of every clip.
private final class Deck {
    let player = AVPlayer()
    let layer: AVPlayerLayer
    private(set) var output: AVPlayerItemVideoOutput?
    private var observer: Any?

    @MainActor init(in bounds: CGRect, scale: CGFloat) {
        layer = AVPlayerLayer(player: player)
        layer.frame = bounds
        // CoreAnimation propagates contentsScale through an NSView's layer tree, and this tree has
        // no view in it. Left at 1 the player layer is composited at the point size and scaled up
        // to the framebuffer, which on this display is half the resolution the clip was encoded
        // for and reads exactly like a bad encode.
        layer.contentsScale = scale
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.isHidden = true
    }

    /// Close enough to the tail of a clip to start a blend within a frame or two of where it has
    /// to start, and free in between: a periodic observer is a timer the player already owns.
    @MainActor func watch(_ body: @escaping () -> Void) {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { _ in MainActor.assumeIsolated { body() } }
    }

    /// `tapped` attaches the video output a blend reads frames through. It is what forces decoded
    /// frames to be copied out of the player at all, so a rotation that will never blend — the
    /// feature turned off, or a switch the configuration asks to stay instant — never pays for it.
    @MainActor func load(_ url: URL, tapped: Bool) {
        let item = AVPlayerItem(url: url)
        output = tapped ? Blend.makeOutput() : nil
        if let output { item.add(output) }
        player.replaceCurrentItem(with: item)
    }

    @MainActor func clear() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        output = nil
        layer.isHidden = true
    }

    @MainActor func release() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        clear()
    }
}

/// Owns the layer WallpaperAgent composites, and follows the menu app by polling the command
/// snapshot rather than holding a connection to it: the agent starts and stops this process on its
/// own schedule, so a file both sides replace atomically survives that where a socket would not.
private final class NativeWallpaperSession: Wallpaper, @unchecked Sendable {
    private let root: CALayer
    private let decks: [Deck]
    /// Which deck is the clip the desktop is nominally showing. During a blend it is already the
    /// incoming one, so status, transport and the next switch all address the right clip.
    private var active = 0
    private var blend: Blend?
    /// Cleared for the life of the process the first time the compositor cannot be built, which is
    /// what turns a machine that cannot run the shader into one that simply cuts.
    private var blendUsable = true
    private var blending = false
    private var blendDeadline: CFTimeInterval = 0
    /// Set once, permanently, if the compositor ever stops producing frames.
    private var surrendered = false
    private let scale: CGFloat
    private var poller: Timer?
    private var endObserver: NSObjectProtocol?
    private var command: NativeIPC.Command?
    private var actionRevision: UInt64 = 0
    private var cursor = 0

    @MainActor init() {
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        root = CALayer()
        root.frame = CGRect(origin: .zero, size: bounds.size)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)

        // Every layer in this tree is told the display's backing scale explicitly. Nothing here
        // inherits it: the host hands this process a bare CALayer, and CoreAnimation only
        // propagates contentsScale down an NSView's own layer tree.
        let mode = CGDisplayCopyDisplayMode(display)
        let backing = mode.map { CGFloat($0.pixelWidth) / max(1, bounds.width) } ?? 2
        scale = min(2, max(1, backing))

        root.contentsScale = scale
        decks = [Deck(in: root.bounds, scale: scale), Deck(in: root.bounds, scale: scale)]
        for deck in decks { root.addSublayer(deck.layer) }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                // During a blend the active deck is already the incoming clip, so the outgoing
                // one reaching its end — which is what the window was timed against — is not an
                // advance. It is the transition finishing on schedule.
                guard let self,
                      note.object as? AVPlayerItem === self.decks[self.active].player.currentItem
                else { return }
                self.advance(manual: false)
            }
        }

        for index in decks.indices {
            decks[index].watch { [weak self] in self?.tail(index) }
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
        blending = false
        blend?.stop()
        for deck in decks { deck.release() }
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
        let player = decks[active].player
        guard let item = player.currentItem else { return nil }
        let scale = root.contentsScale
        return (item.asset, player.currentTime(),
                CGSize(width: root.bounds.width * scale, height: root.bounds.height * scale))
    }

    // MARK: Transport

    @MainActor private func tick() {
        if blending, CACurrentMediaTime() > blendDeadline { settleBlend() }
        // Giving up has to be rarer than being interrupted. A link that stops because the system
        // is not compositing this layer — Mission Control, a sleeping display — is normal and
        // `revive` above simply keeps asking. Only two things are actual faults: a rebuilt link
        // that never once calls back, and callbacks that never become frames.
        if let blend, !surrendered, let command, command.running, !command.paused,
           decks[active].player.currentItem != nil,
           blend.revivals > 25 || blend.isDrawingButNotPresenting {
            surrender()
        }

        guard let next = NativeIPC.readCommand() else {
            idle()
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
            if decks[active].player.currentItem == nil, next.running { open(cursor, manual: false) }
        } else {
            command = next
        }

        if next.actionRevision != actionRevision {
            actionRevision = next.actionRevision
            apply(next.action)
        }

        if !next.running || next.tracks.isEmpty {
            idle()
        } else {
            // Pausing mid-blend would leave two clips stopped at two different points with a
            // half-drawn frame between them, so the transition lands first and the pause applies
            // to the clip that won.
            if next.paused { settleBlend() }
            if decks[active].player.currentItem == nil { open(cursor, manual: false) }
            blend?.resume()
            blend?.revive()
            if !blending { showActiveDeck() }
            let player = decks[active].player
            if next.paused { player.pause() }
            else if player.rate != Float(next.speed) { player.playImmediately(atRate: Float(next.speed)) }
            // Building the compositor costs a shader compile on this thread, so it waits for the
            // first clip to be up and running: the host is awaiting `makeWallpaper` on the first
            // of these ticks, and a clip's worth of runway is left either way.
            if next.blend.isEnabled, player.currentItem?.status == .readyToPlay { _ = compositor() }
        }

        publishStatus()
    }

    @MainActor private func idle() {
        settleBlend()
        for deck in decks {
            deck.player.pause()
            deck.layer.isHidden = true
        }
        // Stopped is the state a wallpaper sits in for hours, so the compositor stops drawing
        // rather than spinning a display link over a frame nobody asked for.
        blend?.suspend()
        blend?.layer.isHidden = true
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
            open(index, manual: true)
        case .previous:
            open((cursor - 1 + command.tracks.count) % command.tracks.count, manual: true)
        case .next:
            advance(manual: true)
        case .seek(let seconds):
            guard let duration = decks[active].player.currentItem?.duration.seconds,
                  duration.isFinite else { return }
            scrub(to: min(max(0, seconds), max(0, duration - 0.05)))
        }
    }

    @MainActor private func advance(manual: Bool) {
        guard let command, !command.tracks.isEmpty else { return }
        if command.repeatOne {
            // A single clip on repeat is the one case where the seam was visible whatever was
            // playing, because it is always the same two frames. Blending it means a second copy
            // of the same asset overlapping itself, which is worth the decoder for a second.
            guard command.blend.isEnabled, blendUsable else {
                return decks[active].player.seek(to: .zero)
            }
            return open(cursor, manual: manual)
        }
        if command.shuffle, command.tracks.count > 1 {
            var next = cursor
            while next == cursor { next = Int.random(in: command.tracks.indices) }
            return open(next, manual: manual)
        }
        open((cursor + 1) % command.tracks.count, manual: manual)
    }

    /// Starts the next clip early enough that the outgoing one runs out exactly as the blend
    /// window closes. The lead is measured in the clip's own time, so a rate other than 1 still
    /// spends the configured number of wall-clock seconds blending.
    @MainActor private func tail(_ deck: Int) {
        guard deck == active, !blending, let command,
              command.running, !command.paused, command.blend.isEnabled, blend != nil else { return }
        let player = decks[deck].player
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds, at = item.currentTime().seconds
        guard duration.isFinite, at.isFinite, duration > 0 else { return }
        let lead = command.blend.seconds * Double(max(0.05, player.rate))
        // A clip barely longer than the window would spend most of itself dissolving, and on
        // repeat would overlap itself almost end to end. Those cut, as they always did.
        guard duration > lead * 3, duration - at <= lead else { return }
        advance(manual: false)
    }

    @MainActor private func open(_ index: Int, manual: Bool) {
        guard let command, command.tracks.indices.contains(index) else {
            settleBlend()
            decks[active].clear()
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

        let config = command.blend
        // A second switch arriving mid-blend lands the first one rather than queueing behind it:
        // there are two decks, and the deck the outgoing clip is on is the one the new clip needs.
        settleBlend()

        let outgoing = active
        let wanted = config.isEnabled && (!manual || config.manual)
            && command.running && !command.paused
            && hasRunway(decks[outgoing])
        guard wanted, let blend = compositor(), !surrendered else {
            decks[1 - outgoing].clear()
            decks[outgoing].load(url, tapped: !surrendered && blendUsable)
            compositor()?.show(decks[outgoing].output)
            showActiveDeck()
            if command.running, !command.paused {
                decks[outgoing].player.playImmediately(atRate: Float(command.speed))
            }
            return
        }

        let incoming = 1 - outgoing
        decks[incoming].load(url, tapped: true)
        decks[incoming].player.playImmediately(atRate: Float(command.speed))
        handOver(to: incoming, config: config, using: blend)
    }

    /// Landing somewhere else in the clip that is already playing is as much of a cut as changing
    /// clip: the frame arrived at has nothing to do with the frame left behind, and a seek
    /// backwards is the most jarring of the lot because the eye recognises where it has been.
    /// So it blends the same way, with the outgoing deck left running exactly where it was and a
    /// second copy of the same clip opened at the destination.
    @MainActor private func scrub(to target: Double) {
        let time = CMTime(seconds: target, preferredTimescale: 600)
        settleBlend()
        let outgoing = active
        let plain = { self.decks[outgoing].player.seek(to: time, toleranceBefore: .zero,
                                                       toleranceAfter: .zero) }
        guard !surrendered else { return plain() }
        guard let command, let track = currentTrack else { return plain() }
        let config = command.blend
        let wanted = config.isEnabled && config.manual
            && command.running && !command.paused
            && hasRunway(decks[outgoing])
        let url = URL(fileURLWithPath: track.path)
        guard wanted, FileManager.default.isReadableFile(atPath: url.path),
              let blend = compositor() else { return plain() }

        let incoming = 1 - outgoing
        decks[incoming].load(url, tapped: true)
        // Exact rather than tolerant: the slider's whole job is to land where it was dropped, and
        // the blend's priming window already covers the decode this costs.
        decks[incoming].player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        decks[incoming].player.playImmediately(atRate: Float(command.speed))
        handOver(to: incoming, config: config, using: blend)
    }

    /// The incoming deck becomes the playing clip here, before a single frame of it has been
    /// drawn: the compositor is what puts it on screen, and everything else — status, transport,
    /// the next switch — should already be addressing it rather than the clip on its way out.
    @MainActor private func handOver(to incoming: Int, config: Transition, using blend: Blend) {
        active = incoming
        guard let into = decks[incoming].output else { return showActiveDeck() }
        blending = true
        blendDeadline = CACurrentMediaTime() + config.seconds + Blend.primingGrace + 0.5
        blend.begin(into: into, config: config)
    }

    /// Whether the outgoing clip has any clip left to play.
    ///
    /// Blending out of a frame that has already run out is a still dissolving into video, not a
    /// transition, and it is what every route to `open` that is not the tail watcher would produce
    /// at the end of a clip: the end-of-item notification fires with the player already stopped on
    /// its last frame. The tail watcher exists to get there first, and where it cannot — a clip
    /// too short to give a window up, or the compositor not built in time — the cut is the honest
    /// answer and this is what falls back to it.
    @MainActor private func hasRunway(_ deck: Deck) -> Bool {
        guard let item = deck.player.currentItem else { return false }
        let remaining = item.duration.seconds - item.currentTime().seconds
        return !remaining.isFinite || remaining > 0.1
    }

    /// The player layers draw nothing while the compositor is working; they are the fallback the
    /// stall watchdog reaches for, and only then. `surrendered` is what makes this the desktop.
    @MainActor private func showActiveDeck() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        decks[active].layer.isHidden = !surrendered
        decks[1 - active].layer.isHidden = true
        blend?.layer.isHidden = surrendered
        CATransaction.commit()
    }

    /// Hands the desktop back to the player layers for the life of the process.
    ///
    /// Nothing else is watching: with the compositor drawing every frame there is no player layer
    /// visible behind it, so a display link that stops firing does not cost a transition, it
    /// freezes the desktop. That is the one outcome worse than a visible seam, and this is the
    /// only thing standing between the two.
    @MainActor private func surrender() {
        guard !surrendered else { return }
        surrendered = true
        blending = false
        blend?.stop()
        showActiveDeck()
        decks[active].player.play()
    }

    /// Ends a transition wherever it has got to and gives the desktop back to the incoming deck.
    /// Taking the blend layer down and hiding the outgoing one in a single transaction is what
    /// keeps the last frame of a clip from flashing back over the first frame of the next.
    /// Ends a transition wherever it has got to and retires the clip it came from. Nothing on
    /// screen changes hands here: the compositor was already drawing the incoming clip, and it
    /// simply stops drawing the other one as well.
    @MainActor private func settleBlend() {
        guard blending else { return }
        blending = false
        blend?.settleNow()
        decks[1 - active].clear()
    }

    /// Built once, on demand, and never retried after a failure: a machine that cannot compile the
    /// shader or make a Metal device is one where every switch is the cut it always was.
    @MainActor private func compositor() -> Blend? {
        if let blend { return blend }
        guard blendUsable else { return nil }
        // The compositor is the only thing that draws now, so failing to build one is not the loss
        // of a transition, it is the loss of the desktop. Hand it straight back to the players.
        guard let made = Blend.make() else {
            blendUsable = false
            surrender()
            return nil
        }
        made.place(in: root.bounds, scale: scale)
        root.addSublayer(made.layer)
        made.onSettle = { [weak self] in MainActor.assumeIsolated { self?.settleBlend() } }
        blend = made
        return made
    }

    @MainActor private func advancePastUnreadable() {
        guard let command, command.tracks.count > 1 else {
            settleBlend()
            decks[active].clear()
            return
        }
        for step in 1..<command.tracks.count {
            let candidate = (cursor + step) % command.tracks.count
            if FileManager.default.isReadableFile(atPath: command.tracks[candidate].path) {
                return open(candidate, manual: false)
            }
        }
        settleBlend()
        decks[active].clear()
    }

    @MainActor private func publishStatus() {
        let player = decks[active].player
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
