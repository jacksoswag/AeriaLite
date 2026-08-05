import Foundation

/// One row of wallpapers.json. `name` is display only and freely editable; storage lives in
/// `source.path`, which is also the whole test for whether the clip is available.

/// Where a clip comes from and where its local copy is. Either half may be empty: a catalogue
/// row has only a link, a hand-added file has only a path.
struct Source: Codable, Hashable {
    var link = ""
    var path = ""

    init(link: String = "", path: String = "") { self.link = link; self.path = path }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

/// Every row is always in the catalogue; there is no adding or removing. What varies is whether
/// it is starred and whether a copy sits in persistent/, and those are what the filter selects on.
struct Entry: Codable, Identifiable, Hashable {
    var name: String
    var source = Source()
    var favorite = false
    var position: Int = 0

    var id: String { name }

    init(name: String, source: Source = Source(), favorite: Bool = false, position: Int = 0) {
        self.name = name; self.source = source; self.favorite = favorite; self.position = position
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? Source()
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
    }
}

/// What the header's filter button selects. Multiselect and unioned, so Favorites plus
/// Downloaded shows both sets rather than their overlap.
enum Filter: String, CaseIterable, Identifiable, Codable {
    case all = "All", favorites = "Favorites", downloaded = "Downloaded"
    var id: String { rawValue }

    /// Case-insensitive, because defaultView is typed by hand into config.json
    static func named(_ text: String) -> Filter? {
        allCases.first { $0.rawValue.caseInsensitiveCompare(text) == .orderedSame }
    }
}

/// wallpapers.json. Owned by the panel: every mutation writes straight back, so nobody has to
/// open the file to change what plays.
struct Catalog: Codable {
    var entries: [Entry] = []
    /// The filter the panel was left on, so a relaunch comes back to the same queue. Lives here
    /// rather than in config.json, which is hand-edited and never written back.
    var view: Set<Filter> = [.all]

    init() {}

    /// Decoded field by field: the synthesised initialiser treats a defaulted property as a
    /// required key, so a wallpapers.json written before `view` existed would fail to parse and
    /// take the whole library with it. Unknown filter names are dropped rather than thrown.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        let names = try c.decodeIfPresent([String].self, forKey: .view) ?? []
        view = Set(names.compactMap(Filter.named))
        if view.isEmpty { view = [.all] }
    }

    static func load() -> Catalog {
        guard let data = try? Data(contentsOf: Paths.catalog),
              let parsed = try? JSONDecoder().decode(Catalog.self, from: data) else { return Catalog() }
        return parsed
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Paths.catalog)
    }

    /// The one order everything reads from. Filtering hides rows without disturbing it, so a
    /// clip keeps its place when it drops out of view and comes back.
    var ordered: [Entry] { entries.sorted { $0.position < $1.position } }

    /// Union of the selected filters, in catalogue order. Empty or All means everything.
    func rows(_ filters: Set<Filter>) -> [Entry] {
        guard !filters.isEmpty, !filters.contains(.all) else { return ordered }
        return ordered.filter { entry in
            (filters.contains(.favorites) && entry.favorite)
                || (filters.contains(.downloaded) && Library.isDownloaded(entry))
        }
    }

    mutating func replace(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.name == entry.name }) else { return }
        entries[index] = entry
    }

    /// Renumbers so `position` always matches the visible order rather than drifting after moves.
    mutating func renumber(_ order: [Entry]) {
        for (index, entry) in order.enumerated() {
            guard let at = entries.firstIndex(where: { $0.name == entry.name }) else { continue }
            entries[at].position = index
        }
    }

    mutating func append(_ entry: Entry) {
        guard !entries.contains(where: { $0.name == entry.name }) else { return }
        entries.append(entry)
    }

    /// Names are the filename, so collisions have to be resolved on the way in.
    func unique(_ base: String) -> String {
        guard entries.contains(where: { $0.name == base }) else { return base }
        var n = 2
        while entries.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }
}
