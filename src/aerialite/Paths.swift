import Foundation

/// Everything AeriaLite owns on disk. The native wallpaper extension is sandboxed, so the app
/// and extension deliberately share one durable root in /Users/Shared.
enum Paths {
    static let root = NativeIPC.root

    static var config: URL { root.appendingPathComponent("config.json") }
    static var catalog: URL { root.appendingPathComponent("wallpapers.json") }

    /// Decoded downloads, never evicted. Living here is the whole of what makes a clip read as
    /// downloaded, so nothing in the catalogue has to record it.
    static var wallpapers: URL { root.appendingPathComponent("Wallpapers") }

    /// Every fetched master, streamed or offline alike. A download leaves when conform decodes it
    /// into Wallpapers/; streamed clips remain in this explicitly bounded cache.
    static var downloads: URL { root.appendingPathComponent("Cache") }

    static func ensure() {
        let fm = FileManager.default
        for dir in [root, wallpapers, downloads] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func size(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
