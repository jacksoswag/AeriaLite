import Foundation

/// Everything Kino owns on disk. One root, so a full uninstall is one directory.
enum Paths {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Kino")

    static var config: URL { root.appendingPathComponent("config.json") }
    static var catalog: URL { root.appendingPathComponent("wallpapers.json") }

    /// Streamed copies live here and are evicted against the size cap.
    static var cache: URL { root.appendingPathComponent("Wallpapers") }

    /// Downloaded copies live here and are never evicted.
    static var persistent: URL { cache.appendingPathComponent("persistent") }

    static func ensure() {
        for dir in [root, cache, persistent] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Filenames are the entry's name, so the folder reads the way the panel does.
    static func file(named name: String, persistent isPersistent: Bool) -> URL {
        (isPersistent ? persistent : cache).appendingPathComponent(name).appendingPathExtension("mp4")
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) as? Int64 ?? 0
    }
}
