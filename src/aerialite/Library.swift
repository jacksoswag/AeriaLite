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

    /// A recorded path is a persistent/downloaded or hand-pointed file. Streamed cache paths are
    /// deliberately derived from the stable storage key and never written to wallpapers.json, so
    /// normal eviction cannot leave the catalogue pointing at a file that was meant to disappear.
    static func playable(_ entry: Entry) -> URL? {
        if let url = recorded(entry), FileManager.default.fileExists(atPath: url.path) { return url }
        return stored(entry) ?? cached(entry)
    }

    /// A decoded copy left in Wallpapers by an earlier download. Prefer the exact recorded path;
    /// the variant scan is for catalogues written before stable storage keys existed.
    static func stored(_ entry: Entry) -> URL? {
        downloadedFiles(entry).first
    }

    static func cached(_ entry: Entry) -> URL? { variants(entry, in: Paths.downloads).first }

    /// Files predating the slug carry the display name verbatim, spaces and all, so a download
    /// wrote a hyphenated sibling instead of replacing them. Both spellings count as the same clip.
    static func variants(_ entry: Entry, in folder: URL) -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        // Once a title is renamed, only the immutable storage key may identify its files. Looking
        // under the new display name could otherwise claim or delete a different entry's download.
        var stems = [entry.storage]
        if entry.storage == slug(for: entry.name) || entry.storage == entry.name {
            stems += [slug(for: entry.name), entry.name]
        }
        return stems.compactMap { stem in
            guard !stem.isEmpty, seen.insert(stem).inserted else { return nil }
            let file = folder.appendingPathComponent(stem).appendingPathExtension("mp4")
            return fm.fileExists(atPath: file.path) ? file : nil
        }
    }

    /// Every persistent spelling of an entry, including a recorded pre-storage-key filename.
    /// Removing a download must remove all of these or a legacy sibling makes it reappear.
    static func downloadedFiles(_ entry: Entry) -> [URL] {
        var files = variants(entry, in: Paths.wallpapers)
        if let url = recorded(entry), isInside(url, Paths.wallpapers),
           FileManager.default.fileExists(atPath: url.path),
           !files.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            files.insert(url, at: 0)
        }
        return files
    }

    static func isDownloaded(_ entry: Entry) -> Bool {
        stored(entry) != nil
    }

    /// Storage name is fixed when a file lands and never tracks the display name afterwards.
    static func slug(for name: String) -> String {
        let kept = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(kept).split(separator: "-").joined(separator: "-")
    }

    /// Only ever removes files AeriaLite put in its own folders; a hand-pointed path is left alone.
    static func delete(_ entry: Entry) {
        guard let url = playable(entry),
              isInside(url, Paths.wallpapers) || isInside(url, Paths.downloads)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Promotes a streamed master with a metadata-only move. The file is persistent before its
    /// potentially long conform begins, so quitting or cache trimming midway cannot undo a click
    /// on Download.
    static func promote(_ entry: Entry, from cached: URL) -> URL? {
        Paths.ensure()
        let target = Paths.wallpapers.appendingPathComponent(entry.storage).appendingPathExtension("mp4")
        guard land(cached, at: target) else { return nil }
        return target
    }

    /// Transcodes a freshly fetched master down to the configured profile, out of process so a
    /// failure in the encoder cannot take the agent with it, then deletes the master. This is
    /// what makes a streamed clip cost the same as a downloaded one rather than 350 MB of 4K.
    ///
    /// `into` is where the decode lands: wallpapers/ promotes the clip to downloaded, downloads/
    /// rewrites it in place and leaves it evictable. Reports the path the decode actually took,
    /// which is the master's own when the encode failed.
    @discardableResult
    static func conform(_ file: URL, into folder: URL, using profile: Settings.Playback,
                        done: @escaping (URL?) -> Void) -> Process? {
        let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        // Same-volume staging makes the final replacement atomic. Migration ignores this spelling
        // if the process is killed and the temporary output survives until the next launch.
        let out = folder.appendingPathComponent(
            ".\(file.deletingPathExtension().lastPathComponent).aerialite.\(UUID().uuidString).mp4")
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
        let final = folder.appendingPathComponent(file.lastPathComponent)
        task.terminationHandler = { proc in
            let fm = FileManager.default
            let ok = proc.terminationStatus == 0 && fm.fileExists(atPath: out.path)
            var landed = file
            if ok, land(out, at: final) {
                landed = final
                if file.standardizedFileURL != final.standardizedFileURL { try? fm.removeItem(at: file) }
            } else {
                try? fm.removeItem(at: out)
            }
            DispatchQueue.main.async { done(landed) }        // original is intact if encode/replace failed
        }
        guard (try? task.run()) != nil else { done(file); return nil }
        return task
    }

    /// The undecoded masters only. Decoded downloads sit in wallpapers/ and this never reaches them.
    static func clearCache() {
        let fm = FileManager.default
        guard let found = try? fm.contentsOfDirectory(at: Paths.downloads, includingPropertiesForKeys: nil)
        else { return }
        for file in found where isCommittedVideo(file) {
            try? fm.removeItem(at: file)
        }
    }

    /// Evicts the least recently used masters until the cache fits. wallpapers/ is never touched,
    /// and `keep` is whatever is on screen right now.
    /// Two caps, count and bytes. capAtHigh keeps whichever allows more; otherwise the tighter
    /// of the two binds, which is the safer default.
    static func trimCache(_ cache: Settings.Cache, keeping keep: String?,
                          in folder: URL = Paths.downloads) {
        let fm = FileManager.default
        guard let found = try? fm.contentsOfDirectory(at: folder,
                                                      includingPropertiesForKeys: [
                                                        .contentAccessDateKey,
                                                        .contentModificationDateKey,
                                                      ])
        else { return }
        // Hidden `.aerialite` files are downloads being validated or encodes still being written.
        // They are outside the cache budget until atomically committed and must never be evicted.
        let all = found.filter(isCommittedVideo)
        var files = all.filter { $0.deletingPathExtension().lastPathComponent != keep }
        files.sort {
            let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey]
            let av = try? $0.resourceValues(forKeys: keys)
            let bv = try? $1.resourceValues(forKeys: keys)
            let a = av?.contentAccessDate ?? av?.contentModificationDate ?? .distantPast
            let b = bv?.contentAccessDate ?? bv?.contentModificationDate ?? .distantPast
            return a < b
        }
        var total = all.reduce(Int64(0)) { $0 + Paths.size(of: $1) }
        var remaining = all.count
        for file in files {
            let overCount = remaining > max(0, cache.videos)
            let overSpace = total > cache.bytes
            let evict = cache.capAtHigh ? (overCount && overSpace) : (overCount || overSpace)
            guard evict else { break }
            let size = Paths.size(of: file)
            do {
                try fm.removeItem(at: file)
                total -= size
                remaining -= 1
            } catch {
                continue
            }
        }
    }

    /// A stream lands in the evictable cache and an explicit download lands directly in the
    /// destination Wallpapers folder, reporting fraction complete as it goes. This is the only
    /// place a filename is chosen.
    /// `fallback` is this same clip's downloaded copy, used when the link cannot carry the
    /// stream. It is never another wallpaper: a slow network changes where a clip comes from,
    /// never which clip plays.
    @discardableResult
    static func fetch(_ entry: Entry, into folder: URL = Paths.downloads, fallback: URL? = nil,
                      session: URLSession = .shared,
                      progress: @escaping (Double) -> Void,
                      done: @escaping (String?) -> Void) -> NSKeyValueObservation? {
        guard !entry.source.link.isEmpty, let remote = URL(string: entry.source.link) else {
            done(fallback?.path); return nil
        }
        Paths.ensure()
        let target = folder.appendingPathComponent(entry.storage).appendingPathExtension("mp4")
        let settled = Settled()
        let task = session.downloadTask(with: remote) { temp, response, _ in
            guard settled.claim() else { return }          // the slow-link fallback already answered
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let staged = folder.appendingPathComponent(
                ".\(entry.storage).aerialite.fetch.\(UUID().uuidString).mp4")
            // URLSession owns `temp` only until this callback returns. Claim it synchronously,
            // then validate from AeriaLite's staging path without risking the existing target.
            guard let temp, (200..<300).contains(status), land(temp, at: staged) else {
                return DispatchQueue.main.async { done(fallback?.path) }
            }
            Task {
                var landed: String?
                if await isPlayableVideo(staged), land(staged, at: target) {
                    landed = target.path
                    // Remove legacy spellings only after the replacement is safely in place.
                    for old in variants(entry, in: folder)
                    where old.standardizedFileURL != target.standardizedFileURL {
                        try? FileManager.default.removeItem(at: old)
                    }
                } else {
                    try? FileManager.default.removeItem(at: staged)
                }
                DispatchQueue.main.async { done(landed ?? fallback?.path) }
            }
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

    private static func recorded(_ entry: Entry) -> URL? {
        guard !entry.source.path.isEmpty else { return nil }
        return URL(fileURLWithPath: (entry.source.path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// A 200 response can still be an HTML error page or a truncated object. Do not let either
    /// replace a playable cache/download merely because it is non-empty.
    static func isPlayableVideo(_ file: URL) async -> Bool {
        let asset = AVURLAsset(url: file)
        guard (try? await asset.load(.isPlayable)) == true,
              let duration = try? await asset.load(.duration),
              duration.isValid, duration.isNumeric, duration.seconds > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video) else { return false }
        return !tracks.isEmpty
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let root = folder.standardizedFileURL.path.hasSuffix("/")
            ? folder.standardizedFileURL.path : folder.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(root)
    }

    /// Replaces an existing file without first unlinking it. If replacement fails, the old file
    /// remains usable; this is the durability boundary for both downloads and conform output.
    static func land(_ source: URL, at target: URL) -> Bool {
        let fm = FileManager.default
        guard source.standardizedFileURL != target.standardizedFileURL else { return true }
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: target)
            }
            return fm.fileExists(atPath: target.path)
        } catch {
            return false
        }
    }

    private static func isCommittedVideo(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == "mp4"
            && !file.lastPathComponent.hasPrefix(".")
            && !file.lastPathComponent.contains(".aerialite.")
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
