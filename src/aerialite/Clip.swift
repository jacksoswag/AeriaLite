import AVFoundation

/// A source file parsed once. Every screen's player and the encoder read the same
/// AVAssetTrack, so the container is demuxed at startup instead of on every loop.
struct Clip {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: CMTime
    let fps: Float
    let bitrate: Float             // estimatedDataRate, what the default bitrate is derived from
    let frameDuration: CMTime      // exact source cadence, so 30000/1001 survives as itself
    let size: CGSize


    /// Blocks on the async loaders, which is only ever called before the runloop starts.
    static func load(_ url: URL) -> Clip? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let done = DispatchSemaphore(value: 0)
        var clip: Clip?
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let duration = try? await asset.load(.duration),
               let (fps, rate) = try? await (track.load(.nominalFrameRate), track.load(.estimatedDataRate)),
               let (step, size) = try? await (track.load(.minFrameDuration), track.load(.naturalSize)) {
                clip = Clip(asset: asset, track: track, duration: duration, fps: fps,
                            bitrate: rate, frameDuration: step, size: size)
            }
            done.signal()
        }
        done.wait()
        return clip
    }

    /// Gap between the first two sync samples. A passthrough reader cannot begin mid-GOP, so this
    /// is the only grid a seek can land on, and the position slider quantises to it. Never call
    /// this on the path to first frame: on a 4K 240 master it reads ~1200 samples before
    /// returning, which is seconds of delay between a click and a picture.
    static func measureGop(_ asset: AVURLAsset, _ track: AVAssetTrack) -> Double {
        guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
        // 5s, not 30: two sync samples is all this needs, and at 240fps a 30s window is thousands
        // of samples read before the first frame can show
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return 0 }
        reader.add(out)
        guard reader.startReading() else { return 0 }
        defer { reader.cancelReading() }

        var first: CMTime?
        while let sample = out.copyNextSampleBuffer() {
            guard isSync(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let start = first else { first = pts; continue }
            return max(0.02, CMTimeGetSeconds(pts - start))
        }
        return 0
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let all = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = all.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}
