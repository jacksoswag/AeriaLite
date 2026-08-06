import AppKit
import Combine

/// The single owner of the catalogue, the settings, and the walls that act on them.
@MainActor final class AppState: ObservableObject {
    @Published private(set) var catalog = Catalog()
    @Published private(set) var filters: Set<Filter> = [.all] { didSet { pushPlaylist() } }
    @Published var running = true { didSet { pushRunning() } }
    @Published var paused = false { didSet { walls.forEach { $0.player.setPaused(paused) } } }
    @Published var speed = 1.0 { didSet { walls.forEach { $0.player.setSpeed(Float(speed)) } } }
    @Published var repeatOne = false { didSet { walls.forEach { $0.player.setRepeat(repeatOne) } } }
    @Published var shuffle = false { didSet { walls.forEach { $0.player.setShuffle(shuffle) } } }
    @Published private(set) var status = Player.Status()
    @Published private(set) var progress: [String: Double] = [:]   // name -> fraction, while fetching
    @Published private(set) var encoding: Set<String> = []         // names whose conform is running

    private(set) var settings = Settings()
    private var walls: [Wall] = []
    private var ticker: Timer?
    private var chaser: Timer?
    private var watches: [String: NSKeyValueObservation] = [:]
    private var wanted: String?          // a clip clicked before it existed locally
    private var displays: [String] = []
    private var lastPlaying = ""         // drives cache maintenance off track changes
    private var queued: [(Entry, URL, URL, Settings.Playback)] = []   // conforms waiting their turn
    private var encodingNow = false

    /// What the panel lists and what the player queues, which are the same thing: filtering a
    /// row out takes it off screen and out of the rotation together.
    var rows: [Entry] { catalog.rows(filters) }
    var canStream: Bool { settings.streamMode > 0 }

    init() {
        Paths.ensure()
        AppleWallpaper.cull()
        Library.clearAppleWallpaperCaches()
        Settings.seedIfMissing()
        settings = Settings.load()
        speed = settings.defSpeed
        catalog = Catalog.load()
        Migration.run(into: &catalog)
        filters = settings.openingView ?? catalog.view   // before build(), so the walls open on it
        catalog.save()
        build()
        observe()
    }

    // MARK: catalogue mutation, each one writing straight back

    /// Opening the panel must not disturb playback. Migration touches the filesystem and loads
    /// assets, both of which stall the main thread, so it runs at launch and after a download,
    /// never on a popover open.
    func reload() {
        settings = Settings.load()
        pushPlaylist()
    }

    /// The panel's filter menu, and the only thing that records the view. Persisting from the
    /// property observer instead would also fire for the launch assignment, because a property
    /// with a default is already initialised by the time init runs, so a `defaultView` in
    /// config.json would overwrite the view it is supposed to be temporarily standing in for.
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

    /// Downloading keeps a decoded copy in wallpapers/; un-downloading deletes it and the clip
    /// goes back to being streamed on demand.
    func toggleDownload(_ entry: Entry) {
        var row = entry
        if let have = Library.stored(row) {
            try? FileManager.default.removeItem(at: have)
            row.source.path = ""
            catalog.replace(row)
            catalog.save()
            return pushPlaylist()
        }
        // a master already in downloads/ is the same bits the fetch would pull, so decode that
        // instead. The row plays it while the encode runs and repoints when the decode lands.
        if let cached = Library.variants(row, in: Paths.downloads).first {
            row.source.path = cached.path
            catalog.replace(row)
            catalog.save()
            pushPlaylist()
            return conform(row, at: cached, into: Paths.wallpapers, using: settings.downloads)
        }
        guard !row.source.link.isEmpty else { return }      // nothing to fetch from
        fetch(row, offline: true)
    }

    /// Display name only. Storage never moves, so this cannot half-succeed the way a rename
    /// that also touched the filesystem could.
    func rename(_ entry: Entry, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.name,
              !catalog.entries.contains(where: { $0.name == name }),
              let index = catalog.entries.firstIndex(where: { $0.name == entry.name }) else { return }
        catalog.entries[index].name = name
        catalog.save()
        refresh()
    }

    /// Both indices address the filtered view, so they are mapped back onto the full order before
    /// anything moves. Dragging lands the row beside whichever visible entry holds the target
    /// slot, which keeps hidden rows where they are instead of shuffling them by raw index.
    func reorder(from: Int, to: Int) {
        let visible = rows
        guard visible.indices.contains(from), visible.indices.contains(to), from != to else { return }
        let moving = visible[from], anchor = visible[to]
        var order = catalog.ordered
        guard let at = order.firstIndex(where: { $0.name == moving.name }) else { return }
        order.remove(at: at)
        guard let landing = order.firstIndex(where: { $0.name == anchor.name }) else { return }
        order.insert(moving, at: to > from ? landing + 1 : landing)
        catalog.renumber(order)
        catalog.save()
        pushPlaylist()
    }

    // MARK: playback

    /// Clicking a clip with nothing on disk fetches it and plays it when it lands, which takes a
    /// second or two; the row's progress ring is the only feedback until then.
    func play(_ entry: Entry) {
        if let index = playlist().firstIndex(where: { $0.name == entry.name }) {
            walls.forEach { $0.player.play(at: index) }
            return refresh()
        }
        guard settings.streamMode > 0 else { return }      // mode 0 never fetches on a click
        wanted = entry.name
        ensureLocal(entry)
    }

    func previous() { walls.forEach { $0.player.previous() }; refresh() }
    func next() { walls.forEach { $0.player.next() }; refresh() }
    func seek(to seconds: Double) { walls.forEach { $0.player.seek(to: seconds) }; refresh() }
    func openConfig() { NSWorkspace.shared.open(Paths.config) }
    func openCatalogFile() { NSWorkspace.shared.open(Paths.catalog) }

    func startPolling() {
        refresh()
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stopPolling() { ticker?.invalidate(); ticker = nil }

    // MARK: wiring

    private func refresh() { status = walls.first?.player.status ?? Player.Status() }

    /// Driven by the player the moment it opens a clip, not by a poll. The reader runs ahead of
    /// the picture, so the id arrives here before status reports it; prefetching from the reader's
    /// position is what we want, and eviction spares whatever is still on screen.
    private func maintain(_ opened: String) {
        guard opened != lastPlaying else { return }
        lastPlaying = opened
        prefetch()
        let onScreen = walls.first?.player.status.id ?? ""
        // off the main actor: this walks directories and deletes, and doing that on the thread
        // driving the compositor shows up as frame stutter
        let cache = settings.maxCache
        let keep = ((onScreen.isEmpty ? opened : onScreen) as NSString).deletingPathExtension
        DispatchQueue.global(qos: .utility).async { Library.trimCache(cache, keeping: keep) }
    }

    /// Pulls the clips just ahead of the one playing, so a track change never waits on a fetch.
    /// Bounded by the same count that bounds the cache: there is no point holding more than the
    /// eviction pass will keep.
    private func prefetch() {
        // one at a time. Each conform is a subprocess of its own, and letting a track change
        // stack another encode on top of the last is how four of them end up resident at once.
        guard settings.streamMode > 0, queued.isEmpty, !encodingNow else { return }
        let queue = rows
        guard let at = queue.firstIndex(where: { Library.playable($0)?.lastPathComponent == lastPlaying })
        else { return }
        for step in 1..<max(2, settings.maxCache.videos) where queue.count > 1 {
            let next = queue[(at + step) % queue.count]
            guard Library.playable(next) == nil, progress[next.name] == nil else { continue }
            ensureLocal(next)
        }
    }

    /// Only entries with a usable local file, since the player cannot show what is not there.
    private func playlist() -> [Entry] { rows.filter { Library.playable($0) != nil } }

    /// A copy already in persistent/ is claimed rather than re-fetched unless redownload asks
    /// for the streamed profile's better version, which costs a download and an encode to
    /// replace a file that already plays.
    private func ensureLocal(_ entry: Entry) {
        guard Library.playable(entry) == nil, settings.streamMode > 0 else { return }
        let stored = Library.stored(entry)
        if settings.streamMode == 1, let have = stored { return claim(entry, at: have) }
        guard !entry.source.link.isEmpty else { return claim(entry, at: stored) }
        fetch(entry, offline: false, fallback: stored)
    }

    /// Points a row at a file already on disk and starts it if it is what was clicked.
    private func claim(_ entry: Entry, at url: URL?) {
        guard let url else { return }
        var row = entry
        row.source.path = url.path
        catalog.replace(row)
        catalog.save()
        pushPlaylist()
        if wanted == row.name { wanted = nil; play(row) }
    }

    /// Encodes a file already on disk down to the given profile, landing it in `folder`. Strictly
    /// one at a time: each conform is a hardware encode competing with playback for the same media
    /// engine, and three of them at once is visible stutter.
    private func conform(_ entry: Entry, at file: URL, into folder: URL, using profile: Settings.Playback) {
        queued.append((entry, file, folder, profile))
        encoding.insert(entry.name)
        drain()
    }

    private func drain() {
        guard !encodingNow, !queued.isEmpty else { return }
        let (entry, file, folder, profile) = queued.removeFirst()
        encodingNow = true
        Library.conform(file, into: folder, using: profile) { landed in
            self.encodingNow = false
            self.encoding.remove(entry.name)
            // a decode into wallpapers/ is a new path, and the row has to follow it or the clip
            // reads as streamed and gets evicted out from under the catalogue
            if let landed, landed.path != file.path {
                var row = entry
                row.source.path = landed.path
                self.catalog.replace(row)
                self.catalog.save()
            }
            let cache = self.settings.maxCache
            let keep = file.deletingPathExtension().lastPathComponent
            DispatchQueue.global(qos: .utility).async { Library.trimCache(cache, keeping: keep) }
            self.pushPlaylist()
            self.drain()
        }
    }

    /// Two stages. The master lands in a second or two and goes straight into the playlist, so a
    /// clip is on screen almost immediately rather than after a multi-minute encode. conform then
    /// rewrites the same path, and every clip is re-read from disk when it comes round again, so
    /// the encode swaps itself in at a loop or track change instead of cutting into what is on
    /// screen. Streamed clips keep the source's own bits per pixel; only a download takes a cap,
    /// and only a download's decode leaves downloads/ for wallpapers/.
    private func fetch(_ entry: Entry, offline: Bool, fallback: URL? = nil) {
        progress[entry.name] = 0
        let profile = offline ? settings.downloads : settings.streams
        let folder = offline ? Paths.wallpapers : Paths.downloads
        watches[entry.name] = Library.fetch(entry, fallback: fallback,
                                            progress: { [weak self] done in
            self?.progress[entry.name] = done
        }, done: { [weak self] landed in
            guard let self else { return }
            self.watches[entry.name] = nil
            self.progress[entry.name] = nil
            guard let landed else { return }
            var row = entry
            row.source.path = landed
            self.catalog.replace(row)
            self.catalog.save()
            self.pushPlaylist()
            if self.wanted == entry.name { self.wanted = nil; self.play(row) }
            self.conform(row, at: URL(fileURLWithPath: landed), into: folder, using: profile)   // queued, never concurrent
        })
    }

    /// Screen parameters change on every fullscreen transition, because the menu bar moves
    /// visibleFrame. Rebuilding there orders every window out and a new one back in, and on a
    /// canJoinAllSpaces window that drags the active space, which reads as being thrown onto
    /// another desktop. `frame` is the full display bounds and ignores the menu bar, so it only
    /// differs when the displays genuinely did.
    private func build() {
        let layout = NSScreen.screens.map { NSStringFromRect($0.frame) }
        guard layout != displays || walls.isEmpty else { return }
        displays = layout
        walls = NSScreen.screens.map { Wall(screen: $0, onFullscreen: settings.onFullscreen) }
        pushed = []            // fresh players hold nothing, so the unchanged-list guard must not skip
        pushPlaylist()
        walls.forEach {
            $0.player.setSpeed(Float(speed)); $0.player.setRepeat(repeatOne); $0.player.setShuffle(shuffle)
            $0.player.onClipChange = { [weak self] id in Task { @MainActor in self?.maintain(id) } }
        }
    }

    private var pushed: [URL] = []

    /// setPlaylist restarts the player from the top, so it is only worth calling when the list
    /// actually changed. Without this guard every popover open jumped back to the first clip.
    private func pushPlaylist() {
        let files = playlist().compactMap { Library.playable($0) }
        if files != pushed {
            pushed = files
            walls.forEach { $0.player.setPlaylist(files) }
        }
        pushRunning()
    }

    /// Reads the catalogue, never the player or the current filter. Enabling orders the window
    /// front, which drags the active space on a canJoinAllSpaces window, so this must not flip
    /// on anything the gate can also change: doing so is a loop that throws you between spaces.
    /// An empty filter therefore leaves the wallpaper alone, and only an empty library stops it.
    private func pushRunning() {
        let anything = catalog.entries.contains { Library.playable($0) != nil }
        walls.forEach { $0.setEnabled(running && anything) }
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            // no rejoinSpaces here: mutating Space membership mid-transition drags the active
            // space, which is the same failure .stationary and .fullScreenNone caused
            Task { @MainActor in self?.chase() }
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.walls.forEach { $0.gate() } }
        }
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true),
                                 (NSWorkspace.screensDidWakeNotification, false)] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.walls.forEach { $0.setAsleep(sleeping) } }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.build() }
        }
        let backstop = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.walls.forEach { $0.gate() } }
        }
        backstop.tolerance = 2
        RunLoop.main.add(backstop, forMode: .common)
    }

    /// A space notification arrives before the window coordinates settle, so one look is not
    /// enough. Polling at 60ms for a couple of seconds is what keeps the wallpaper from sitting
    /// frozen after landing on the desktop; the 5-second backstop is far too slow for that.
    private func chase() {
        chaser?.invalidate()
        walls.forEach { $0.gate() }
        var ticks = 0
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] t in
            ticks += 1
            Task { @MainActor in self?.walls.forEach { $0.gate() } }
            if ticks >= 30 { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        chaser = timer
    }
}
