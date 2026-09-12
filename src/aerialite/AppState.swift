import AppKit
import Combine

/// Owns the catalogue, downloads, cache policy, and the command stream consumed by the native
/// wallpaper extension. Rendering never occurs in this process.
@MainActor final class AppState: ObservableObject {
    @Published private(set) var catalog = Catalog()
    @Published private(set) var filters: Set<Filter> = [.all] { didSet { pushPlaylist() } }
    @Published var running = true { didSet { publish() } }
    @Published var paused = false { didSet { publish() } }
    @Published var speed = 1.0 { didSet { publish() } }
    @Published var repeatOne = false { didSet { publish() } }
    @Published var shuffle = false { didSet { publish() } }
    @Published private(set) var status = NativeIPC.Status()
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var encoding: Set<String> = []

    private(set) var settings = Settings()
    private var ticker: Timer?
    /// Set by the menu app as the panel opens and closes.
    ///
    /// Only the position slider needs a fast tick. With the panel down the tick has two jobs left,
    /// and neither is latency-sensitive: notice the extension moved to another clip, so the next
    /// ones can be prefetched and the cache trimmed, and reassert a command file something else
    /// overwrote. A clip runs 90 to 300 seconds and download progress arrives by KVO rather than
    /// from here, so five seconds is far inside what either needs.
    ///
    /// Watching the file instead of polling it would be worse, not better. The extension republishes
    /// its status on its own 200ms cadence, so a vnode source would wake this process four to five
    /// times a second rather than once every five, and would need re-arming after every write
    /// because the status file is replaced by atomic rename and the watched descriptor follows the
    /// old inode. The tick is a rate limiter over a continuously-written file, not a poll for a
    /// change that might never come, which is why it is a timer and why slowing it down is free.
    var panelIsVisible = false {
        didSet { if panelIsVisible != oldValue { startTicker() } }
    }
    private var watches: [String: NSKeyValueObservation] = [:]
    private var wanted: String?
    private var lastPlaying = ""
    private var queued: [(Entry, URL, URL, Settings.Playback)] = []
    private var encodingNow = false
    private var conformProcess: Process?
    private var pushed: [NativeIPC.Track] = []
    private var commandRevision: UInt64 = 0
    private var actionRevision: UInt64 = 0
    private var lastAction: NativeIPC.Action?

    var rows: [Entry] { catalog.rows(filters) }
    var canStream: Bool { settings.streamMode > 0 }
    var nativeBackendLive: Bool { status.isLive }
    func isPlaying(_ entry: Entry) -> Bool { entry.id == status.id }

    init() {
        Paths.migrateToSharedStorage()
        Paths.ensure()
        Settings.seedIfMissing()
        settings = Settings.load()
        speed = min(5, max(0.125, settings.defSpeed))
        catalog = Catalog.load()
        Migration.run(into: &catalog)
        filters = settings.openingView ?? catalog.view
        catalog.save()
        pushPlaylist()

        startTicker()
    }

    private func startTicker() {
        ticker?.invalidate()
        let interval = panelIsVisible ? 0.25 : 5.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // A wide tolerance lets the kernel coalesce this with whatever else is waking, which is
        // most of the point of slowing it down in the first place.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func reload() {
        settings = Settings.load()
        pushPlaylist()
    }

    func select(_ next: Set<Filter>) {
        filters = next.isEmpty ? [.all] : next
        guard catalog.view != filters else { return }
        catalog.view = filters
        catalog.save()
    }

    func toggleFavorite(_ entry: Entry) {
        var row = entry
        row.favorite.toggle()
        catalog.replace(row)
        catalog.save()
        pushPlaylist()
    }

    /// Downloaded copies live only in the durable Wallpapers directory. Cache files are derived
    /// and evictable, so toggling this can never accidentally interpret a cache hit as a download.
    func toggleDownload(_ entry: Entry) {
        var row = entry
        let downloads = Library.downloadedFiles(row)
        if !downloads.isEmpty {
            for file in downloads { try? FileManager.default.removeItem(at: file) }
            if !row.source.path.isEmpty {
                let recorded = URL(fileURLWithPath: (row.source.path as NSString).expandingTildeInPath)
                    .standardizedFileURL
                if Library.isInside(recorded, Paths.wallpapers),
                   !FileManager.default.fileExists(atPath: recorded.path) {
                    row.source.path = ""
                }
            }
            catalog.replace(row)
            catalog.save()
            return pushPlaylist()
        }
        if let cached = Library.cached(row), let persistent = Library.promote(row, from: cached) {
            row.source.path = persistent.path
            catalog.replace(row)
            catalog.save()
            pushPlaylist()
            return conform(row, at: persistent, into: Paths.wallpapers, using: settings.downloads)
        }
        guard !row.source.link.isEmpty else { return }
        fetch(row, offline: true)
    }

    func rename(_ entry: Entry, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.name,
              !catalog.entries.contains(where: { $0.name == name }),
              let index = catalog.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        catalog.entries[index].name = name
        catalog.save()
        pushPlaylist()
    }

    func reorder(from: Int, to: Int) {
        let visible = rows
        guard visible.indices.contains(from), visible.indices.contains(to), from != to else { return }
        let moving = visible[from], anchor = visible[to]
        var order = catalog.ordered
        guard let at = order.firstIndex(where: { $0.id == moving.id }) else { return }
        order.remove(at: at)
        guard let landing = order.firstIndex(where: { $0.id == anchor.id }) else { return }
        order.insert(moving, at: to > from ? landing + 1 : landing)
        catalog.renumber(order)
        catalog.save()
        pushPlaylist()
    }

    // MARK: playback commands

    func play(_ entry: Entry) {
        if let index = playlist().firstIndex(where: { $0.0.id == entry.id }) {
            send(.play(index))
            if settings.streamMode == 2 { ensureLocal(entry) }
            return
        }
        guard settings.streamMode > 0 else { return }
        wanted = entry.id
        ensureLocal(entry)
    }

    func previous() { send(.previous) }
    func next() { send(.next) }
    func seek(to seconds: Double) { send(.seek(seconds)) }
    func openConfig() { NSWorkspace.shared.open(Paths.config) }
    func openCatalogFile() { NSWorkspace.shared.open(Paths.catalog) }
    func startPolling() { refresh() }
    func stopPolling() {}

    func shutdown() {
        ticker?.invalidate()
        watches.values.forEach { $0.invalidate() }
        watches.removeAll()
        conformProcess?.terminate()
        conformProcess = nil
        queued.removeAll()
        running = false
    }

    private func send(_ action: NativeIPC.Action) {
        actionRevision &+= 1
        lastAction = action
        publish()
    }

    private func publish() {
        commandRevision &+= 1
        NativeIPC.write(NativeIPC.Command(
            revision: commandRevision,
            actionRevision: actionRevision,
            action: lastAction,
            tracks: pushed,
            running: running,
            paused: paused,
            speed: speed,
            repeatOne: repeatOne,
            shuffle: shuffle,
            transition: settings.transition
        ))
    }

    private func refresh() {
        // The extension follows the command file, so whatever is in it wins regardless of what this
        // agent believes. Anything that overwrote it — a second agent quitting, a stale copy, a
        // hand-edit — otherwise leaves the wallpaper stopped indefinitely, because publishing is
        // driven by state changes and this agent's state did not change. The published revision is
        // this agent's own counter, so a mismatch is a divergence and reasserting is idempotent.
        if NativeIPC.readCommand()?.revision != commandRevision { publish() }

        guard let next = NativeIPC.readStatus(), next.isLive else {
            if status.isLive { status = NativeIPC.Status() }
            return
        }
        if next != status { status = next }
        if next.actionRevision == actionRevision, lastAction != nil {
            lastAction = nil
            publish()
        }
        if !next.id.isEmpty, next.id != lastPlaying { maintain(next.id) }
    }

    private func maintain(_ opened: String) {
        guard opened != lastPlaying else { return }
        lastPlaying = opened
        prefetch()
        let cache = settings.maxCache
        let keep = pushed.first(where: { $0.id == opened }).map {
            URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Library.trimCache(cache, keeping: keep)
            DispatchQueue.main.async { self?.cacheDidChange() }
        }
    }

    private func prefetch() {
        guard settings.streamMode > 0, queued.isEmpty, !encodingNow else { return }
        let queue = rows
        guard let at = queue.firstIndex(where: { $0.id == lastPlaying }) else { return }
        for step in 1..<max(2, settings.maxCache.videos) where queue.count > 1 {
            let next = queue[(at + step) % queue.count]
            let needsFetch = settings.streamMode == 2 ? Library.cached(next) == nil
                                                      : Library.playable(next) == nil
            guard needsFetch, !next.source.link.isEmpty, progress[next.id] == nil else { continue }
            ensureLocal(next)
        }
    }

    private func playlist() -> [(Entry, URL)] {
        rows.compactMap { entry in playbackURL(entry).map { (entry, $0) } }
    }

    private func playbackURL(_ entry: Entry) -> URL? {
        if settings.streamMode == 2, let cached = Library.cached(entry) { return cached }
        return Library.playable(entry)
    }

    private func ensureLocal(_ entry: Entry) {
        guard settings.streamMode > 0, !entry.source.link.isEmpty else { return }
        if settings.streamMode == 2 {
            guard Library.cached(entry) == nil else { return }
            return fetch(entry, offline: false, fallback: Library.stored(entry) ?? Library.playable(entry))
        }
        guard Library.playable(entry) == nil else { return }
        fetch(entry, offline: false)
    }

    private func conform(_ entry: Entry, at file: URL, into folder: URL, using profile: Settings.Playback) {
        queued.append((entry, file, folder, profile))
        encoding.insert(entry.id)
        drain()
    }

    private func drain() {
        guard !encodingNow, !queued.isEmpty else { return }
        let (entry, file, folder, profile) = queued.removeFirst()
        encodingNow = true
        conformProcess = Library.conform(file, into: folder, using: profile) { [weak self] landed in
            guard let self else { return }
            self.conformProcess = nil
            self.encodingNow = false
            self.encoding.remove(entry.id)
            if let landed, Library.isInside(landed, Paths.wallpapers),
               let index = self.catalog.entries.firstIndex(where: { $0.id == entry.id }) {
                self.catalog.entries[index].source.path = landed.path
                self.catalog.save()
            }
            let cache = self.settings.maxCache
            let keep = file.deletingPathExtension().lastPathComponent
            DispatchQueue.global(qos: .utility).async { [weak self] in
                Library.trimCache(cache, keeping: keep)
                DispatchQueue.main.async { self?.cacheDidChange() }
            }
            self.pushPlaylist()
            self.drain()
        }
    }

    private func fetch(_ entry: Entry, offline: Bool, fallback: URL? = nil) {
        guard progress[entry.id] == nil, !encoding.contains(entry.id) else { return }
        progress[entry.id] = 0
        let profile = offline ? settings.downloads : settings.streams
        let folder = offline ? Paths.wallpapers : Paths.downloads
        watches[entry.id] = Library.fetch(entry, into: folder, fallback: fallback,
                                          progress: { [weak self] done in
            self?.progress[entry.id] = done
        }, done: { [weak self] landed in
            guard let self else { return }
            self.watches[entry.id] = nil
            self.progress[entry.id] = nil
            guard let landed else { return }
            if offline, let index = self.catalog.entries.firstIndex(where: { $0.id == entry.id }) {
                self.catalog.entries[index].source.path = landed
                self.catalog.save()
            }
            self.pushPlaylist()
            let current = self.catalog.entries.first(where: { $0.id == entry.id }) ?? entry
            if self.wanted == entry.id { self.wanted = nil; self.play(current) }
            let url = URL(fileURLWithPath: landed)
            if fallback?.standardizedFileURL != url.standardizedFileURL {
                self.conform(current, at: url, into: folder, using: profile)
            }
        })
    }

    private func cacheDidChange() {
        objectWillChange.send()
        pushPlaylist()
    }

    private func pushPlaylist() {
        let tracks = playlist().map { entry, url in
            NativeIPC.Track(id: entry.id, title: entry.name, path: url.path)
        }
        if tracks != pushed { pushed = tracks }
        publish()
    }
}
