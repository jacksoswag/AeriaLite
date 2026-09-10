import AVFoundation
import AppKit
import VideoToolbox

/// Transcodes a source clip to the profile native playback wants: HEVC in MP4, no audio track,
/// at a chosen size, cadence and bitrate. Hardware encodes through VideoToolbox, which is
/// what AVAssetWriter picks for HEVC on Apple silicon.
enum Prep {
    static func main(_ args: [String]) {
        guard let first = args.first, !first.hasPrefix("-") else {
            fail("usage: aerialite prep <input> [-o <output>] [--keep 0-1] [--size WxH] [--bitrate BPS]")
        }
        let cfg = Settings.load().downloads
        let input = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
        var output = Paths.wallpapers.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                                      .appendingPathExtension("mp4")
        var keep = cfg.framesKept, bitrate = cfg.bitrate
        var size = cfg.size
        var keyframe = cfg.keyframeSeconds
        var maxSeconds = cfg.maxSeconds

        var rest = Array(args.dropFirst())
        while let flag = rest.first {
            guard rest.count >= 2 else { fail("\(flag) needs a value") }
            let value = rest[1]
            switch flag {
            case "-o": output = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--keep":
                guard let n = Double(value), n > 0, n <= 1 else { fail("bad --keep \(value), want 0 to 1") }
                keep = n
            case "--bitrate":
                guard let n = Int(value), n > 0 else { fail("bad --bitrate \(value)") }
                bitrate = n
            case "--keyframe":
                guard let v = Double(value), v > 0 else { fail("bad --keyframe \(value)") }
                keyframe = v
            case "--max-seconds":
                guard let n = Int(value), n >= 0 else { fail("bad --max-seconds \(value)") }
                maxSeconds = n
            case "--size":
                let parts = value.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("bad --size \(value), want WxH") }
                size = (parts[0], parts[1])
            default: fail("unknown flag \(flag)")
            }
            rest = Array(rest.dropFirst(2))
        }

        guard let clip = Clip.load(input) else { fail("no readable video track in \(input.path)") }
        // the ratio resolves against the source rather than an assumed rate, so a 240 master and
        // a 30 one both mean what the number says
        run(clip: clip, output: output, size: size, fps: Double(clip.fps) * keep,
            bitrate: bitrate > 0 ? bitrate : perPixelMatched(clip, size),
            keyframeSeconds: keyframe, maxSeconds: maxSeconds)
    }

    /// Default bitrate: the source's own bits per pixel, applied to the smaller frame. Holding
    /// the source's absolute rate through a downscale spends more bits per pixel than the
    /// master was graded at, which costs disk and shows nothing.
    private static func perPixelMatched(_ clip: Clip, _ size: (w: Int, h: Int)) -> Int {
        let from = Double(clip.size.width * clip.size.height)
        guard from > 0, clip.bitrate > 0 else { return 10_000_000 }
        return Int(Double(clip.bitrate) * Double(size.w * size.h) / from)
    }

    private static func run(clip: Clip, output: URL, size: (w: Int, h: Int), fps: Double,
                            bitrate: Int, keyframeSeconds: Double, maxSeconds: Int) {
        guard let reader = try? AVAssetReader(asset: clip.asset) else { fail("cannot read source") }
        // trimming happens here rather than after, so nothing past the cap is ever encoded
        let cap = CMTime(seconds: Double(maxSeconds), preferredTimescale: 600)
        if maxSeconds > 0, clip.duration > cap { reader.timeRange = CMTimeRange(start: .zero, duration: cap) }

        // Raising cadence would need duplicated frames and only speeds the clip up, so at or
        // above the source rate every frame is kept and carries its ORIGINAL timestamp. No
        // uniform grid is imposed, because no single number describes a source whose frames
        // are unevenly spaced: minFrameDuration is the tightest gap rather than the average,
        // and grid-stamping one 29.97 master at its 39.2 minimum squeezed 60s into 46s.
        // 240000 divides 239.76 and every halving of it exactly, so decimating a 240 master lands
        // on real source timestamps instead of drifting a frame every few seconds
        let keepAll = clip.fps <= 0 || Float(fps) >= clip.fps
        let step = CMTime(value: CMTimeValue((240_000 / fps).rounded()), timescale: 240_000)
        let rate = keepAll ? Double(clip.fps) : fps
        if keepAll && Float(fps) > clip.fps { print("fps clamped to source: \(rateText(fps)) -> \(rateText(rate))") }

        let decoded = AVAssetReaderTrackOutput(track: clip.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        decoded.alwaysCopiesSampleData = false
        reader.add(decoded)

        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { fail("cannot write \(output.path)") }
        let cadence = Int(rate.rounded())
        let encoded = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.w, AVVideoHeightKey: size.h,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                // both caps, so the sync grid holds in seconds even where the cadence clamps;
                // this is the grid the position slider snaps to
                AVVideoMaxKeyFrameIntervalKey: max(1, Int((rate * keyframeSeconds).rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: keyframeSeconds,
                AVVideoExpectedSourceFrameRateKey: cadence,
                // Apple's aerial masters are yuv420p10le, and 8-bit bands their skies
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
            ]])
        encoded.expectsMediaDataInRealTime = false
        writer.add(encoded)
        let sink = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: encoded, sourcePixelBufferAttributes: nil)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var due = CMTime.zero, kept: Int64 = 0, seen = 0, origin: CMTime?
        let drained = DispatchSemaphore(value: 0)
        encoded.requestMediaDataWhenReady(on: DispatchQueue(label: "aerialite.prep", qos: .utility)) {
            while encoded.isReadyForMoreMediaData {
                guard let sample = decoded.copyNextSampleBuffer() else {
                    encoded.markAsFinished(); drained.signal(); return
                }
                seen += 1
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if origin == nil { origin = pts }
                guard keepAll || pts >= due, let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
                sink.append(frame, withPresentationTime: keepAll ? pts - origin!
                                                                 : CMTimeMultiply(step, multiplier: Int32(kept)))
                kept += 1
                if !keepAll { due = due + step }
            }
        }
        drained.wait()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            fail("encode failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int ?? 0
        let ran = keepAll ? CMTimeGetSeconds(clip.duration) : Double(kept) / rate
        let seconds = maxSeconds > 0 ? min(Double(maxSeconds), ran) : ran
        print("""
        \(output.path)
          \(size.w)x\(size.h) hevc main10 @ \(rateText(rate))fps, \(kept) of \(seen) frames, \(fmt(seconds))s
          \(fmt(Double(bytes) / 1e6)) MB, \(fmt(Double(bytes) * 8 / seconds / 1e6)) Mbps
        """)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    // %g so 30000/1001 prints as 29.97 rather than rounding to a rate this never encodes at
    private static func rateText(_ v: Double) -> String { String(format: "%g", v) }
}
