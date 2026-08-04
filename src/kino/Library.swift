import AVFoundation
import AppKit
import Foundation

/// Resolves an entry to the file that should actually play, fetches what is missing, and keeps
/// the streamed half of the cache under its size cap.
enum Library {
    /// Apple's shot id is the trailing hyphen group and always carries both a digit and an
    /// underscore ("SE_A016_C009"), so requiring both turns a downloaded filename into a name
    /// without stripping the year off something a person called "sunset-2024".
    static func title(for stem: String) -> String {
        var parts = stem.split(separator: "-").map(String.init)
        if parts.count > 1, let last = parts.last,
           last.contains(where: \.isNumber), last.contains("_") { parts.removeLast() }
        return parts.isEmpty ? stem : parts.joined(separator: " ")
    }

    /// The recorded path is the whole availability test. Nothing is inferred from the folder,
    /// so a hand-pointed file anywhere on disk works exactly like a downloaded one, and renaming
    /// an entry cannot break playback because the filename never moves.
    static func playable(_ entry: Entry) -> URL? {
        guard !entry.source.path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (entry.source.path as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A copy left in persistent/ by an earlier download. Storage names are fixed when a file
    /// lands and never track renames, so the slug is the whole lookup.
    static func stored(_ entry: Entry) -> URL? { variants(entry, in: Paths.persistent).first }

    /// Files predating the slug carry the display name verbatim, spaces and all, so a download
    /// wrote a hyphenated sibling instead of replacing them. Both spellings count as the same clip.
    static func variants(_ entry: Entry, in folder: URL) -> [URL] {
        let fm = FileManager.default
        return [slug(for: entry.name), entry.name].map {
            folder.appendingPathComponent($0).appendingPathExtension("mp4")
        }.filter { fm.fileExists(atPath: $0.path) }
    }

    /// The streamed copy of a clip that has just been downloaded. Dropping it means the row reads
    /// as downloaded from the moment the master lands, not once the encode finishes.
    static func dropCached(_ entry: Entry) {
        for url in variants(entry, in: Paths.cache) { try? FileManager.default.removeItem(at: url) }
    }

    static func isDownloaded(_ entry: Entry) -> Bool {
        guard let url = playable(entry) else { return false }
        return url.path.hasPrefix(Paths.persistent.path)
    }

    /// Storage name is fixed when a file lands and never tracks the display name afterwards.
    static func slug(for name: String) -> String {
        let kept = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(kept).split(separator: "-").joined(separator: "-")
    }

    /// Only ever removes files Kino put in its own folders; a hand-pointed path is left alone.
    static func delete(_ entry: Entry) {
        guard let url = playable(entry), url.path.hasPrefix(Paths.cache.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Transcodes a freshly fetched master down to the configured profile, out of process so a
    /// failure in the encoder cannot take the agent with it, then deletes the master. This is
    /// what makes a streamed clip cost the same as a downloaded one rather than 350 MB of 4K.
    static func conform(_ file: URL, using profile: Settings.Playback, done: @escaping (URL?) -> Void) {
        let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        // outside the scanned folders on purpose: an in-flight temp file dropped into cache/
        // gets adopted by Migration as a library entry of its own
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kino-conform-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let out = scratch.appendingPathComponent(file.lastPathComponent)
        let task = Process()
        task.qualityOfService = .background   // a multi-minute encode must never outrank playback
        task.executableURL = binary
        let size = profile.size
        var args = ["prep", file.path, "-o", out.path,
                    "--keep", "\(profile.framesKept)",
                    "--size", "\(size.w)x\(size.h)",
                    "--keyframe", "\(profile.keyframeSeconds)",
                    "--max-seconds", "\(profile.maxSeconds)"]
        if profile.bitrate > 0 { args += ["--bitrate", "\(profile.bitrate)"] }
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)
            if ok {
                try? FileManager.default.removeItem(at: file)          // the master has served its purpose
                try? FileManager.default.moveItem(at: out, to: file)
            }
            try? FileManager.default.removeItem(at: scratch)
            DispatchQueue.main.async { done(file) }                    // master kept if the encode failed
        }
        guard (try? task.run()) != nil else { return done(file) }
    }

    /// The streamed half only. persistent/ lives inside this folder, so this deletes files rather
    /// than the directory, and never recurses into the downloads.
    static func clearCache() {
        let fm = FileManager.default
        guard let found = try? fm.contentsOfDirectory(at: Paths.cache, includingPropertiesForKeys: nil)
        else { return }
        for file in found where file.pathExtension.lowercased() == "mp4" {
            try? fm.removeItem(at: file)
        }
    }

    /// Everywhere macOS caches wallpaper state: Apple's aerial store with its manifest,
    /// thumbnails and videos, plus the frame caches a still-image wallpaper leaves behind.
    /// None of it serves anything while Kino owns the desktop, and a frame cached for one clip
    /// must not outlive it. Runs at launch, on every clip change, and on quit.
    ///
    /// com.apple.wallpaper/Store is deliberately spared: it is the picker's index rather than a
    /// cache, and deleting it every few seconds invites System Settings to misbehave.
    static func clearAppleWallpaperCaches() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let targets = [
            home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials"),
            home.appendingPathComponent("Library/Caches/com.apple.wallpaper"),
            home.appendingPathComponent("Library/Caches/com.apple.idleassetsd"),
            URL(fileURLWithPath: "/Users/Shared/Aerial"),
        ]
        let fm = FileManager.default
        for target in targets where fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }
    }

    /// Evicts the least recently used streamed files until the cache fits. persistent/ is never
    /// touched, and `keep` is whatever is on screen right now.
    /// Two caps, count and bytes. capAtHigh keeps whichever allows more; otherwise the tighter
    /// of the two binds, which is the safer default.
    static func trimCache(_ cache: Settings.Cache, keeping keep: String?) {
        clearAppleWallpaperCaches()      // Kino owns the desktop; nothing of Apple's should survive a cache pass
        let fm = FileManager.default
        guard let found = try? fm.contentsOfDirectory(at: Paths.cache,
                                                      includingPropertiesForKeys: [.contentAccessDateKey])
        else { return }
        var files = found.filter { $0.pathExtension.lowercased() == "mp4" }
                         .filter { $0.deletingPathExtension().lastPathComponent != keep }
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            return a < b
        }
        var total = files.reduce(Int64(0)) { $0 + Paths.size(of: $1) }
        let slots = max(0, cache.videos - 1)          // the clip being kept occupies one
        for (index, file) in files.enumerated() {
            let overCount = files.count - index > slots
            let overSpace = total > cache.bytes
            let evict = cache.capAtHigh ? (overCount && overSpace) : (overCount || overSpace)
            guard evict else { break }
            total -= Paths.size(of: file)
            try? fm.removeItem(at: file)
        }
    }

    /// Downloads to persistent/ when `offline`, otherwise into the streamed cache, reporting
    /// fraction complete as it goes. This is the only place a filename is chosen.
    /// `fallback` is this same clip's downloaded copy, used when the link cannot carry the
    /// stream. It is never another wallpaper: a slow network changes where a clip comes from,
    /// never which clip plays.
    @discardableResult
    static func fetch(_ entry: Entry, offline: Bool, fallback: URL? = nil,
                      progress: @escaping (Double) -> Void,
                      done: @escaping (String?) -> Void) -> NSKeyValueObservation? {
        guard !entry.source.link.isEmpty, let remote = URL(string: entry.source.link) else {
            done(fallback?.path); return nil
        }
        Paths.ensure()
        let folder = offline ? Paths.persistent : Paths.cache
        let target = folder.appendingPathComponent(slug(for: entry.name)).appendingPathExtension("mp4")
        let settled = Settled()
        let task = URLSession.shared.downloadTask(with: remote) { temp, _, _ in
            var landed: String?
            if let temp {
                // every spelling of this clip, so a download replaces rather than duplicates
                for old in variants(entry, in: folder) { try? FileManager.default.removeItem(at: old) }
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: temp, to: target)) != nil { landed = target.path }
            }
            guard settled.claim() else { return }          // the slow-link bail already answered
            DispatchQueue.main.async { done(landed ?? fallback?.path) }
        }
        let began = Date()
        let watch = task.progress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async { progress(p.fractionCompleted) }
            // judged only after a couple of seconds, since the first bytes of any transfer
            // measure the handshake rather than the link
            guard let fallback, p.completedUnitCount > 0 else { return }
            let elapsed = Date().timeIntervalSince(began)
            guard elapsed > 2, Double(p.completedUnitCount) * 8 / elapsed < Settings.slowBitsPerSecond,
                  settled.claim() else { return }
            task.cancel()
            DispatchQueue.main.async { done(fallback.path) }
        }
        task.resume()
        return watch
    }
}

/// One-shot latch so a cancelled download and its completion handler cannot both answer.
private final class Settled {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
