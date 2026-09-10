import AppKit
import Foundation

/// config.json. Hand-edited, never written by the panel, so a malformed file falls back to
/// defaults rather than being rewritten over the top of someone's work.
struct Settings: Codable {
    /// How a clip should be encoded and played. One shape, used for streamed clips and again as
    /// the override for clips kept offline.
    struct Playback: Codable {
        var resolution = "native"       // native, 1080p or 4k
        var bitrate = 0                 // 0 matches the source's bits per pixel
        var keyframeSeconds = 1.0       // seek granularity traded against file size
        var maxSeconds = 0              // trimmed on the way in; 0 keeps the whole clip
        var framesKept = 1.0            // fraction of the source frames to keep: 0.5 halves cadence
        var size: (w: Int, h: Int) { Channel.size(resolution, on: NSScreen.main ?? NSScreen.screens[0]) }

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? resolution
            bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? bitrate
            keyframeSeconds = try c.decodeIfPresent(Double.self, forKey: .keyframeSeconds) ?? keyframeSeconds
            maxSeconds = try c.decodeIfPresent(Int.self, forKey: .maxSeconds) ?? maxSeconds
            framesKept = try c.decodeIfPresent(Double.self, forKey: .framesKept) ?? framesKept
        }
    }

    /// Streamed clips only. Whichever of the two limits binds first wins, unless capAtHigh asks
    /// for the looser one.
    struct Cache: Codable {
        var videos = 3
        var space = "512"               // MB, quoted in the file
        var capAtHigh = false

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            videos = try c.decodeIfPresent(Int.self, forKey: .videos) ?? videos
            if let text = try? c.decode(String.self, forKey: .space) { space = text }
            else if let number = try? c.decode(Int.self, forKey: .space) { space = String(number) }
            capAtHigh = try c.decodeIfPresent(Bool.self, forKey: .capAtHigh) ?? false
        }

        var bytes: Int64 { Int64(max(0, Double(space) ?? 512) * 1_000_000) }
    }

    /// Streamed clips keep the source's own bits per pixel at the display.s native size; a
    /// download trades quality for a file worth keeping. Both conform, one at a time.
    var streams = Playback()
    var downloads = Playback()
    var defSpeed = 1.0
    var maxCache = Cache()
    /// 0 plays only what is on disk and greys the rest, 1 prefers Wallpapers/ and fetches what
    /// is missing, 2 streams everything and falls back to this clip.s own downloaded copy when
    /// the link cannot carry it. The fallback is always the same wallpaper, never a different one.
    var streamMode = 1
    /// Filter names the panel opens on every launch. Empty leaves it on whatever view was last
    /// used, which the catalogue remembers.
    var defaultView: [String] = []
    static let slowBitsPerSecond = 5_000_000.0

    /// nil when unset or when nothing in it names a real filter, which is what lets the caller
    /// fall through to the remembered view instead of opening on an empty list.
    var openingView: Set<Filter>? {
        let picked = Set(defaultView.compactMap(Filter.named))
        return picked.isEmpty ? nil : picked
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        streams = try c.decodeIfPresent(Playback.self, forKey: .streams) ?? streams
        downloads = try c.decodeIfPresent(Playback.self, forKey: .downloads) ?? downloads
        defSpeed = try c.decodeIfPresent(Double.self, forKey: .defSpeed) ?? defSpeed
        maxCache = try c.decodeIfPresent(Cache.self, forKey: .maxCache) ?? maxCache
        streamMode = try c.decodeIfPresent(Int.self, forKey: .streamMode) ?? streamMode
        // one name or several, since a single view is the common case and quoting it as a bare
        // string is what anyone hand-editing this reaches for first
        if let one = try? c.decodeIfPresent(String.self, forKey: .defaultView) { defaultView = [one] }
        else if let many = try? c.decodeIfPresent([String].self, forKey: .defaultView) { defaultView = many }
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.config),
              let parsed = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return parsed
    }

    /// Written once, when nothing is there, so the file exists to be edited.
    static func seedIfMissing() {
        guard !FileManager.default.fileExists(atPath: Paths.config.path) else { return }
        var seed = Settings()
        seed.streams.framesKept = 0.5
        seed.downloads.resolution = "1080p"
        seed.downloads.maxSeconds = 180
        seed.downloads.bitrate = 2_500_000
        seed.downloads.framesKept = 0.25
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(seed).write(to: Paths.config, options: .atomic)
    }
}

/// Apple's macOS aerial manifests carry one URL per clip, 4K SDR at 239.76, with no 1080p or
/// lower-cadence sibling. So there is nothing to pick at download time; every knob is an encode
/// decision applied to that one master.
enum Channel {
    /// Presets rather than free dimensions, since anything between the framebuffer and a
    /// standard frame only buys a resample. Encode time is linear in these pixels.
    static func size(_ preset: String, on screen: NSScreen) -> (w: Int, h: Int) {
        let native = nativeSize(of: screen)
        switch preset.lowercased() {
        case "4k": return (3840, 2160)
        case "1080p", "1080": return (even(Int((1080 * Double(native.w) / Double(native.h)).rounded())), 1080)
        default: return native
        }
    }

    /// The framebuffer the compositor actually scans out, which on a scaled display is neither
    /// the point size nor the panel size.
    static func nativeSize(of screen: NSScreen) -> (w: Int, h: Int) {
        let f = screen.frame, s = screen.backingScaleFactor
        return (even(Int((f.width * s).rounded())), even(Int((f.height * s).rounded())))
    }

    private static func even(_ n: Int) -> Int { n % 2 == 0 ? n : n + 1 }   // 4:2:0 needs even sides
}
