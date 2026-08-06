import Foundation

/// Everything AeriaLite owns on disk. One root, so a full uninstall is one directory.
enum Paths {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/AeriaLite")

    static var config: URL { root.appendingPathComponent("config.json") }
    static var catalog: URL { root.appendingPathComponent("wallpapers.json") }

    /// Decoded downloads, never evicted. Living here is the whole of what makes a clip read as
    /// downloaded, so nothing in the catalogue has to record it.
    static var wallpapers: URL { root.appendingPathComponent("Wallpapers") }

    /// Every fetched master, streamed or offline alike. A download leaves when conform decodes it
    /// into wallpapers/; a streamed clip stays until the size cap evicts it. Under Library/Caches
    /// so macOS keeps it out of Time Machine and a cache sweep can find it by convention.
    static let downloads = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/AeriaLite")

    /// Where downloads sat before they were flattened into wallpapers/. `Migration.flatten` empties it.
    static var legacyPersistent: URL { wallpapers.appendingPathComponent("persistent") }

    static func ensure() {
        let fm = FileManager.default
        for dir in [root, wallpapers, downloads] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) as? Int64 ?? 0
    }
}
