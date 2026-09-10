import Foundation

/// Reconciles the catalogue with what is actually on disk, on every launch. A path that stopped
/// resolving drops its row back to absent, which is the whole point of storing a path rather
/// than inferring one from the entry's name.
enum Migration {
    static func run(into catalog: inout Catalog) {
        removeAbandonedWork()
        adoptLegacyFolder(&catalog)
        flatten(&catalog)
        adopt(Paths.wallpapers, into: &catalog)
        forgetTransient(&catalog)
        forgetMissing(&catalog)
    }

    /// A forced quit can stop the encoder between writing its hidden staging file and atomically
    /// replacing the original. Such files were never committed and are safe to remove on launch.
    private static func removeAbandonedWork() {
        for folder in [Paths.wallpapers, Paths.downloads] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                           includingPropertiesForKeys: nil)
            else { continue }
            for file in files where file.lastPathComponent.hasPrefix(".")
                && file.lastPathComponent.contains(".aerialite.") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Downloads used to sit in a persistent/ subfolder that meant "never evict". Living in
    /// wallpapers/ carries that meaning now, so the folder is emptied into its parent and the rows
    /// addressing it are moved with their files. A name already taken in wallpapers/ is the same
    /// clip streamed, and the download is the better copy, so it wins.
    private static func flatten(_ catalog: inout Catalog) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.legacyPersistent,
                                                      includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "mp4" {
            let target = Paths.wallpapers.appendingPathComponent(file.lastPathComponent)
            guard Library.land(file, at: target) else { continue }
            for entry in catalog.entries where entry.source.path == file.path {
                var row = entry
                row.source.path = target.path
                catalog.replace(row)
            }
        }
        try? fm.removeItem(at: Paths.legacyPersistent)
    }

    /// The pre-AeriaLite location. Files move rather than copy, so this runs exactly once.
    private static func adoptLegacyFolder(_ catalog: inout Catalog) {
        let old = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Wallpapers")
        guard let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension.lowercased() == "mp4" {
            let title = Library.title(for: file.deletingPathExtension().lastPathComponent)
            let target = Paths.wallpapers.appendingPathComponent(Library.slug(for: title))
                                         .appendingPathExtension("mp4")
            // A library already committed under the new root wins. Leave the older source in
            // place for manual recovery instead of overwriting a known-good current download.
            guard FileManager.default.fileExists(atPath: target.path)
                    || Library.land(file, at: target) else { continue }
            claim(title: title, path: target, into: &catalog)
        }
    }

    /// Files sitting in AeriaLite's own folders that no row points at yet.
    private static func adopt(_ folder: URL, into catalog: inout Catalog) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        let known = Set(catalog.entries.map(\.source.path))
        for file in files where file.pathExtension.lowercased() == "mp4"
            && !known.contains(file.path)
            && !file.lastPathComponent.contains(".aerialite.") {
            claim(title: Library.title(for: file.deletingPathExtension().lastPathComponent),
                  path: file, into: &catalog)
        }
    }

    /// Attaches a file to the catalogue row of the same name when there is one, so a downloaded
    /// clip lands on its own catalogue entry instead of creating a near-duplicate beside it.
    private static func claim(title: String, path: URL, into catalog: inout Catalog) {
        let stem = path.deletingPathExtension().lastPathComponent
        let existing = catalog.entries.first { $0.storage == stem || $0.name == title }
        var row = existing ?? Entry(name: catalog.unique(title))
        if !row.source.path.isEmpty {
            let recorded = URL(fileURLWithPath: (row.source.path as NSString).expandingTildeInPath)
            let durableElsewhere = FileManager.default.fileExists(atPath: recorded.path)
                && !Library.isInside(recorded, Paths.downloads)
                && recorded.standardizedFileURL != path.standardizedFileURL
            guard !durableElsewhere else { return }
        }
        row.source.path = path.path
        if existing == nil { row.position = catalog.entries.count }
        if existing != nil { catalog.replace(row) }
        else { catalog.append(row) }
    }

    /// Older builds persisted streamed cache paths. They become stale by design whenever the LRU
    /// runs or the app quits, which made wallpapers.json appear to lose downloads. Cache presence
    /// is now derived from `storage`; only durable/user-selected paths remain in the catalogue.
    private static func forgetTransient(_ catalog: inout Catalog) {
        for entry in catalog.entries where !entry.source.path.isEmpty {
            let url = URL(fileURLWithPath: (entry.source.path as NSString).expandingTildeInPath)
            guard Library.isInside(url, Paths.downloads) else { continue }
            var row = entry
            row.source.path = ""
            catalog.replace(row)
        }
    }

    /// A row whose file has gone forgets the path, so it reads as streamable rather than sitting
    /// pointed at nothing.
    private static func forgetMissing(_ catalog: inout Catalog) {
        for entry in catalog.entries where !entry.source.path.isEmpty {
            let url = URL(fileURLWithPath: (entry.source.path as NSString).expandingTildeInPath)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            var row = entry
            row.source.path = ""
            catalog.replace(row)
        }
    }
}

/// `aerialite catalog` writes Apple's whole aerial set into wallpapers.json as absent rows: names and
/// links only, nothing downloaded. Kept off the launch path so starting up never waits on a network.
enum CatalogImport {
    /// The macOS catalogue rather than the tvOS one. Its clips are 4K SDR at 239.76, against
    /// 29.97 for tvOS, which is the whole reason fpsMultiplier can mean anything. It lives on a
    /// content-addressed path, so the version is not guessable from the tvOS URL shape.
    static let manifest = "https://sylvan.apple.com/itunes-assets/Aerials126/v4/82/2e/34/"
                        + "822e344c-f5d2-878c-3d56-508d5b09ed61/resources-26-0-1.tar"

    static func main() {
        Paths.ensure()
        var catalog = Catalog.load()
        guard let tar = try? Data(contentsOf: URL(string: manifest)!)
        else { fail("could not reach Apple's manifest") }

        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aerialite-manifest")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("r.tar")
        try? tar.write(to: archive)
        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xf", archive.path, "-C", work.path, "entries.json"]
        try? untar.run()
        untar.waitUntilExit()

        guard let data = try? Data(contentsOf: work.appendingPathComponent("entries.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { fail("manifest had no assets") }

        var added = 0, linked = 0
        for asset in assets.sorted(by: { ($0["shotID"] as? String ?? "") < ($1["shotID"] as? String ?? "") }) {
            guard let link = asset["url-4K-SDR-240FPS"] as? String,
                  let shotID = asset["shotID"] as? String else { continue }
            let label = (asset["accessibilityLabel"] as? String) ?? "Aerial"
            let name = CatalogNames.title(label: label, shotID: shotID)

            if let index = catalog.entries.firstIndex(where: { $0.source.link == link }) {
                catalog.entries[index].source.link = link
                catalog.entries[index].name = name
                if catalog.entries[index].storage.isEmpty { catalog.entries[index].storage = shotID }
                linked += 1
            } else if let index = catalog.entries.firstIndex(where: { $0.name == name }) {
                catalog.entries[index].source.link = link      // an already-local clip gains its origin
                linked += 1
            } else {
                catalog.append(Entry(name: name, source: Source(link: link),
                                     id: (asset["id"] as? String) ?? shotID, storage: shotID))
                added += 1
            }
        }
        catalog.save()
        try? FileManager.default.removeItem(at: work)
        print("catalogue: \(added) added, \(linked) linked to existing rows, "
            + "\(catalog.entries.count) total, \(catalog.entries.filter(\.favorite).count) starred")
    }
}
