import Foundation

/// Reconciles the catalogue with what is actually on disk, on every launch. A path that stopped
/// resolving drops its row back to absent, which is the whole point of storing a path rather
/// than inferring one from the entry's name.
enum Migration {
    static func run(into catalog: inout Catalog) {
        repoint(&catalog)
        adoptLegacyFolder(&catalog)
        flatten(&catalog)
        adopt(Paths.wallpapers, into: &catalog)
        forgetMissing(&catalog)
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
            try? fm.removeItem(at: target)
            guard (try? fm.moveItem(at: file, to: target)) != nil else { continue }
            for entry in catalog.entries where entry.source.path == file.path {
                var row = entry
                row.source.path = target.path
                catalog.replace(row)
            }
        }
        try? fm.removeItem(at: Paths.legacyPersistent)
    }

    /// Rows still addressing the Kino-era root, whose files `Paths.ensure` has already moved.
    /// `adopt` would re-find them by name, but only for a title that survives the slug round trip.
    private static func repoint(_ catalog: inout Catalog) {
        let old = Paths.legacyRoot.path + "/"
        for entry in catalog.entries where entry.source.path.hasPrefix(old) {
            var row = entry
            row.source.path = Paths.root.path + "/" + entry.source.path.dropFirst(old.count)
            catalog.replace(row)
        }
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
            guard (try? FileManager.default.moveItem(at: file, to: target)) != nil else { continue }
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
        var row = catalog.entries.first { $0.name == title }
            ?? Entry(name: catalog.unique(title))
        guard row.source.path.isEmpty || Library.playable(row) == nil else { return }
        row.source.path = path.path
        if row.position == 0 { row.position = catalog.entries.count }
        if catalog.entries.contains(where: { $0.name == row.name }) { catalog.replace(row) }
        else { catalog.append(row) }
    }

    /// A row whose file has gone forgets the path, so it reads as streamable rather than sitting
    /// pointed at nothing.
    private static func forgetMissing(_ catalog: inout Catalog) {
        for entry in catalog.entries where !entry.source.path.isEmpty && Library.playable(entry) == nil {
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

        // Apple ships several clips per place, so a bare label collides; number them in shot order
        // rather than letting unique() scatter suffixes arbitrarily.
        var seen: [String: Int] = [:]
        var added = 0, linked = 0
        for asset in assets.sorted(by: { ($0["shotID"] as? String ?? "") < ($1["shotID"] as? String ?? "") }) {
            guard let link = asset["url-4K-SDR-240FPS"] as? String else { continue }
            let label = (asset["accessibilityLabel"] as? String) ?? "Aerial"
            seen[label, default: 0] += 1
            let name = seen[label]! == 1 ? label : "\(label) \(seen[label]!)"

            if let index = catalog.entries.firstIndex(where: { $0.source.link == link }) {
                catalog.entries[index].source.link = link
                linked += 1
            } else if let index = catalog.entries.firstIndex(where: { $0.name == name }) {
                catalog.entries[index].source.link = link      // an already-local clip gains its origin
                linked += 1
            } else {
                catalog.append(Entry(name: name, source: Source(link: link)))
                added += 1
            }
        }
        catalog.save()
        try? FileManager.default.removeItem(at: work)
        print("catalogue: \(added) added, \(linked) linked to existing rows, "
            + "\(catalog.entries.count) total, \(catalog.entries.filter(\.favorite).count) starred")
    }
}
