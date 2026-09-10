import AVFoundation
import CoreVideo
import Foundation

@main
struct MediaHelper {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw Failure("usage: media-helper make|probe <path>")
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        switch CommandLine.arguments[1] {
        case "make":
            try await makeFixture(at: url)
        case "probe":
            try await probe(url)
        default:
            throw Failure("unknown command: \(CommandLine.arguments[1])")
        }
    }

    private static func makeFixture(at url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = 640
        let height = 360
        let frameRate: Int32 = 60
        let frameCount = 120
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw Failure("writer rejected video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure("writer did not start") }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw Failure("missing pixel buffer pool") }

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var candidate: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &candidate) == kCVReturnSuccess,
                  let buffer = candidate else { throw Failure("could not allocate frame") }
            paint(buffer, frame: frame)
            let time = CMTime(value: CMTimeValue(frame), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? Failure("could not append frame \(frame)")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? Failure("fixture writer failed")
        }
    }

    private static func paint(_ buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8((x + frame * 3) % 256)
                row[offset + 1] = UInt8((y * 2 + frame) % 256)
                row[offset + 2] = UInt8((x / 3 + y / 2 + frame * 2) % 256)
                row[offset + 3] = 255
            }
        }
    }

    private static func probe(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let videos = tracks.filter { $0.mediaType == .video }
        guard videos.count == 1, let video = videos.first else {
            throw Failure("wanted one video track, found \(videos.count)")
        }
        let descriptions = try await video.load(.formatDescriptions)
        guard let description = descriptions.first else { throw Failure("missing format description") }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let naturalSize = try await video.load(.naturalSize)
        let fps = try await video.load(.nominalFrameRate)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        guard reader.canAdd(output) else { throw Failure("reader rejected video track") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("reader did not start") }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            frames += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed else { throw reader.error ?? Failure("reader failed") }

        print("format=\(fourCC(subtype))")
        print("width=\(Int(abs(naturalSize.width)))")
        print("height=\(Int(abs(naturalSize.height)))")
        print("fps=\(Int(fps.rounded()))")
        print("frames=\(frames)")
        print("streams=\(tracks.count)")
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> FourCharCode($0)) & 0xff) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "unknown"
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
