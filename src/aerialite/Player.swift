import AVFoundation

/// Plays an ordered list of clips without ever holding a decoded frame. The reader runs in
/// passthrough (outputSettings nil), so what crosses this process is compressed samples of a
/// few tens of KB; decode happens inside the layer's own VideoToolbox session against
/// IOSurfaces the compositor already owns. No display link is involved, so none of the
/// clock-death behaviour that bites a window-tied CAMetalDisplayLink applies.
///
/// Two values carry the timeline. `offset` is the synchroniser time at which the current
/// reader's first sample is shown, and `clipStart` is how far into the clip that reader began.
/// Position inside the clip is therefore clipStart + (now - offset), which survives seeking.
///
/// Everything mutable belongs to the feed queue. pump() advances the playlist there, so calls
/// arriving from the UI hop rather than race it. The only exception is `status`, which the
/// panel polls while it is open and which reads a lock-protected snapshot.
final class Player {
    struct Status { var position = 0.0, duration = 0.0, gop = 0.0; var title = "", id = "" }

    /// Fires on the feed queue the moment a new clip is loaded, so cache work runs on the
    /// transition itself rather than being noticed by a poll some seconds later.
    var onClipChange: ((String) -> Void)?

    let layer = AVSampleBufferDisplayLayer()
    private let sync = AVSampleBufferRenderSynchronizer()
    // userInitiated, not utility: this queue feeds the display layer, and at a background QoS it
    // gets descheduled under load, which shows up as late samples and micro-stutter
    private let feed = DispatchQueue(label: "aerialite.feed", qos: .userInitiated)
    private let label: String

    private var queue: [URL] = []
    private var cursor = 0
    private var clip: Clip?
    private var reader: AVAssetReader?
    private var samples: AVAssetReaderTrackOutput?

    private var offset = CMTime.zero
    private var clipStart = CMTime.zero
    private var origin: CMTime?
    private var readSinceOpen = 0
    private var misses = 0

    private var live = false             // the wall is up and a reader exists
    private var paused = false
    private var speed: Float = 1
    private var repeatOne = false
    private var shuffle = false
    private var history: [Int] = []      // indices already played, so previous() can walk back
    private var resumeAt: CMTime?        // where a gate pause left off, so resuming picks it up
    private var gop = 0.0                // measured after playback starts, never before it

    /// The reader runs ahead of the picture, so a clip is opened seconds before the compositor
    /// reaches it. Recording one segment per clip and choosing by the synchroniser's clock keeps
    /// the readout describing what is on screen rather than what has merely been read.
    private struct Segment { let start, clipStart, duration: CMTime; let title, id: String }
    private let lock = NSLock()
    private var segments: [Segment] = []

    init(label: String) {
        self.label = label
        layer.videoGravity = .resizeAspectFill
        sync.addRenderer(layer)
    }

    // MARK: what the panel reads

    var status: Status {
        let now = CMTimeGetSeconds(sync.currentTime())
        lock.lock()
        while segments.count > 1, CMTimeGetSeconds(segments[1].start) <= now { segments.removeFirst() }
        let segment = segments.first
        lock.unlock()
        guard let segment, now.isFinite else { return Status() }
        let duration = CMTimeGetSeconds(segment.duration)
        guard duration.isFinite, duration > 0 else { return Status() }
        let position = CMTimeGetSeconds(segment.clipStart) + max(0, now - CMTimeGetSeconds(segment.start))
        return Status(position: min(position, duration), duration: duration, gop: gop,
                      title: segment.title, id: segment.id)
    }

    // MARK: what the panel drives

    /// Edits the queue in place. Whatever is on screen keeps playing at its own position as long
    /// as it is still in the list, so reordering, renaming, adding and removing other entries all
    /// leave the picture alone. Only losing the current clip forces a restart.
    func setPlaylist(_ urls: [URL]) {
        feed.async {
            let showing = self.queue.indices.contains(self.cursor) ? self.queue[self.cursor] : nil
            self.queue = urls
            self.history.removeAll { !urls.indices.contains($0) }
            if let showing, let moved = urls.firstIndex(of: showing) { return self.cursor = moved }
            // whatever is up plays out even when it leaves the list, so changing a filter never
            // cuts the current wallpaper; the new queue only decides what follows it
            self.cursor = -1
            guard !self.live, !urls.isEmpty else { return }
            self.cursor = 0
            self.begin()
        }
    }

    func setSpeed(_ rate: Float) {
        feed.async {
            self.speed = rate
            if self.live && !self.paused { self.sync.rate = rate }
        }
    }

    func setRepeat(_ on: Bool) { feed.async { self.repeatOne = on } }

    /// Playback order only. The list itself is never reordered, so what the panel shows stays
    /// the order you set.
    func setShuffle(_ on: Bool) { feed.async { self.shuffle = on } }

    /// Steps back to whatever actually played before this clip, which is not simply the previous
    /// row once the list has been reordered mid-playback.
    func previous() {
        feed.async {
            guard self.live, !self.queue.isEmpty else { return }
            let back = self.history.popLast() ?? (self.cursor - 1 + self.queue.count) % self.queue.count
            self.jump(to: back)
        }
    }

    func next() {
        feed.async {
            guard self.live, self.queue.count > 1 else { return }
            self.remember(self.cursor)
            self.jump(to: self.step(from: self.cursor))
        }
    }

    private func remember(_ index: Int) {
        history.append(index)
        if history.count > 64 { history.removeFirst() }
    }

    /// Gate transitions only. Pausing keeps the last frame, the queue position and the play
    /// head, so coming back from a fullscreen space carries on rather than restarting the list.
    func setActive(_ on: Bool) { feed.async { on ? self.begin() : self.suspend() } }

    /// The panel's stop button: forget everything and start from the top next time.
    func stop() { feed.async { self.teardown() } }

    func play(at index: Int) {
        feed.async {
            guard self.live, self.queue.indices.contains(index), index != self.cursor else { return }
            self.remember(self.cursor)
            self.jump(to: index)
        }
    }

    func setPaused(_ on: Bool) {
        feed.async {
            self.paused = on
            guard self.live else { return }
            self.sync.rate = on ? 0 : self.speed
        }
    }

    /// Snaps to the nearest sync sample. The reader falls back to the preceding keyframe when the
    /// requested time sits mid-GOP, which puts the picture up to a GOP behind what the readout
    /// claims; landing on the grid instead keeps the two agreeing. The epsilon covers float error
    /// that would otherwise round just short and cost a whole GOP.
    func seek(to seconds: Double) {
        feed.async {
            guard self.live, let clip = self.clip else { return }
            let limit = CMTimeGetSeconds(clip.duration)
            var want = min(max(0, seconds), max(0, limit - 0.05))
            if self.gop > 0 { want = (want / self.gop).rounded() * self.gop + self.gop / 1000 }
            self.restart(at: CMTime(seconds: min(want, max(0, limit - 0.05)), preferredTimescale: 600))
        }
    }

    // MARK: engine

    private func begin() {
        guard !live, !queue.isEmpty else { return }
        clearSegments()
        offset = .zero
        origin = nil
        misses = 0
        let at = resumeAt ?? .zero
        resumeAt = nil
        guard load(cursor, from: at) else { return log("nothing playable in \(queue.count) files") }
        live = true
        layer.requestMediaDataWhenReady(on: feed) { [weak self] in self?.pump() }
        sync.setRate(paused ? 0 : speed, time: .zero)
        log("playing")
    }

    /// Gate pause. Releases the decoder and the clock but keeps the last frame on screen and
    /// records the play head, so this is a freeze rather than a stop.
    private func suspend() {
        guard live else { return }
        resumeAt = CMTime(seconds: status.position, preferredTimescale: 600)
        live = false
        sync.rate = 0
        layer.stopRequestingMediaData()
        layer.flush()                    // drops queued samples, leaves the still frame up
        reader?.cancelReading()
        reader = nil
        samples = nil
        log("paused")
    }

    /// Full stop. Same release, but the queue position goes with it.
    private func teardown() {
        guard live else { return }
        live = false
        clearSegments()
        history.removeAll()
        resumeAt = nil
        sync.rate = 0
        layer.stopRequestingMediaData()
        layer.flush()
        reader?.cancelReading()
        reader = nil
        samples = nil
        clip = nil
        cursor = 0
        log("gated")
    }

    /// Re-opens the current clip at `time` and lands its first sample at the present instant,
    /// so the picture changes the moment the scrubber moves.
    private func restart(at time: CMTime) {
        guard let clip else { return }
        let resume = sync.rate
        sync.rate = 0
        layer.stopRequestingMediaData()
        layer.flush()
        offset = sync.currentTime()
        clipStart = time
        origin = nil
        let held = currentSegment()
        guard openReader(clip, from: time) else { return }
        publish(duration: clip.duration, replacing: true,
                title: held.0, id: held.1)                                  // a seek redefines the timeline
        layer.requestMediaDataWhenReady(on: feed) { [weak self] in self?.pump() }
        sync.rate = paused ? 0 : (resume == 0 ? speed : resume)
    }

    private func pump() {
        while layer.isReadyForMoreMediaData {
            guard let next = samples?.copyNextSampleBuffer() else {
                guard advance() else { return teardown() }
                continue
            }
            readSinceOpen += 1
            layer.enqueue(retimed(next))
        }
    }

    private func advance() -> Bool {
        if readSinceOpen > 0, let done = clip {
            offset = offset + (done.duration - clipStart)
            misses = 0
        } else {
            misses += 1
        }
        guard misses < max(queue.count, 1) else { return false }
        origin = nil
        if !repeatOne {
            remember(cursor)
            cursor = step(from: cursor)
        }
        return load(cursor, from: .zero) || advance()
    }

    private func step(from index: Int) -> Int {
        guard queue.indices.contains(index) else { return 0 }   // the clip up left the queue
        guard queue.count > 1 else { return index }
        guard shuffle else { return (index + 1) % queue.count }
        var pick = index
        while pick == index { pick = Int.random(in: 0..<queue.count) }
        return pick
    }

    /// Cuts to another entry straight away, landing its first sample at the present instant.
    private func jump(to index: Int) {
        layer.stopRequestingMediaData()
        layer.flush()
        offset = sync.currentTime()
        origin = nil
        cursor = index
        guard load(index, from: .zero, replacing: true) else { return }
        layer.requestMediaDataWhenReady(on: feed) { [weak self] in self?.pump() }
        if !paused { sync.rate = speed }
    }

    private func load(_ index: Int, from time: CMTime, replacing: Bool = false) -> Bool {
        guard queue.indices.contains(index), let next = Clip.load(queue[index]) else { return false }
        clip = next
        // a conformed file can be shorter than the master it replaced, so a carried-over
        // position may sit past the end
        clipStart = CMTimeMinimum(time, CMTimeMaximum(.zero, next.duration - CMTime(value: 1, timescale: 2)))
        guard openReader(next, from: clipStart) else { return false }
        publish(duration: next.duration, replacing: replacing,
                title: Library.title(for: queue[index].deletingPathExtension().lastPathComponent),
                id: queue[index].lastPathComponent)
        onClipChange?(queue[index].lastPathComponent)
        // measured only after the picture is up, never before it
        gop = 0
        let target = next
        DispatchQueue.global(qos: .utility).async {
            let measured = Clip.measureGop(target.asset, target.track)
            self.feed.async { if self.clip?.asset === target.asset { self.gop = measured } }
        }
        return true
    }

    private func openReader(_ clip: Clip, from time: CMTime) -> Bool {
        guard let r = try? AVAssetReader(asset: clip.asset) else { return false }
        if time > .zero { r.timeRange = CMTimeRange(start: time, duration: .positiveInfinity) }
        let out = AVAssetReaderTrackOutput(track: clip.track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return false }
        r.add(out)
        guard r.startReading() else { return false }
        reader?.cancelReading()
        reader = r
        samples = out
        readSinceOpen = 0
        return true
    }

    private func publish(duration: CMTime, replacing: Bool = false, title: String, id: String) {
        lock.lock()
        if replacing { segments.removeAll() }
        segments.append(Segment(start: offset, clipStart: clipStart, duration: duration,
                                title: title, id: id))
        lock.unlock()
    }

    private func clearSegments() { lock.lock(); segments.removeAll(); lock.unlock() }

    /// Rebases each clip onto the running timeline. Without it a stream-copied file whose first
    /// pts is 90s would sit blank until the timebase caught up.
    private func retimed(_ s: CMSampleBuffer) -> CMSampleBuffer {
        var t = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(s, at: 0, timingInfoOut: &t) == noErr else { return s }
        if origin == nil { origin = t.presentationTimeStamp }
        let shift = offset - origin!
        guard shift != .zero else { return s }
        t.presentationTimeStamp = t.presentationTimeStamp + shift
        if t.decodeTimeStamp.isValid { t.decodeTimeStamp = t.decodeTimeStamp + shift }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: s,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &t,
                                              sampleBufferOut: &copy)
        return copy ?? s
    }

    // alive-but-not-playing is indistinguishable from working without these lines
    private func log(_ state: String) { print("aerialite: \(label) \(state)") }
}

extension Player {
    /// What the compositor is showing right now, so a seek does not relabel its own clip.
    fileprivate func currentSegment() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (segments.first?.title ?? "", segments.first?.id ?? "")
    }
}
