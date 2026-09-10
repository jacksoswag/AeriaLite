import Foundation

/// Everything AeriaLite owns on disk. The native wallpaper extension is sandboxed, so the app
/// and extension deliberately share one durable root in /Users/Shared.
enum Paths {
    static let root = NativeIPC.root

    static var config: URL { root.appendingPathComponent("config.json") }
    static var catalog: URL { root.appendingPathComponent("wallpapers.json") }
    static var legacyContinuity: URL { legacyRoot.appendingPathComponent("Continuity") }

    /// Decoded downloads, never evicted. Living here is the whole of what makes a clip read as
    /// downloaded, so nothing in the catalogue has to record it.
    static var wallpapers: URL { root.appendingPathComponent("Wallpapers") }

    /// Every fetched master, streamed or offline alike. A download leaves when conform decodes it
    /// into Wallpapers/; streamed clips remain in this explicitly bounded cache.
    static var downloads: URL { root.appendingPathComponent("Cache") }

    /// Where downloads sat before they were flattened into wallpapers/. `Migration.flatten` empties it.
    static var legacyPersistent: URL { wallpapers.appendingPathComponent("persistent") }

    private static let legacyRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/AeriaLite")
    private static let legacyCache = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/AeriaLite")

    /// One-time, non-overwriting migration into the extension-readable root. Moves are atomic on
    /// the startup disk. Existing destination files win, while directories merge recursively; an
    /// interrupted migration therefore resumes instead of stranding an entire older library.
    static func migrateToSharedStorage() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        migrateContents(from: legacyRoot, to: root)
        migrateContents(from: legacyCache, to: downloads)
    }

    static func migrateContents(from source: URL, to destination: URL) {
        let fm = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL,
              let contents = try? fm.contentsOfDirectory(at: source,
                                                          includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                migrateContents(from: item, to: target)
                continue
            }
            guard !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.moveItem(at: item, to: target)
            } catch {
                // Cross-volume/shared-folder edge case: copy first and only remove a source whose
                // byte count matches.
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      (try? fm.copyItem(at: item, to: target)) != nil,
                      size(of: item) == size(of: target) else { continue }
                try? fm.removeItem(at: item)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: source.path).isEmpty) == true {
            try? fm.removeItem(at: source)
        }
    }

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
