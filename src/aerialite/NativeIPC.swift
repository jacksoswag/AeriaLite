import Foundation

/// The only bridge between the menu app and Apple's wallpaper-extension process. Both sides
/// exchange complete, atomically-replaced snapshots in /Users/Shared; no window renderer or
/// alternate playback path exists in the app process.
enum NativeIPC {
    static let root = URL(fileURLWithPath: "/Users/Shared/AeriaLite", isDirectory: true)
    static let command = root.appendingPathComponent("playback-command.json")
    static let status = root.appendingPathComponent("playback-status.json")
    static let resume = root.appendingPathComponent("resume.json")

    /// What the desktop shows: the aerial footage, or Liquify's Spotify background mirrored as
    /// Liquify itself renders it.
    enum Backdrop: String, Codable, Equatable {
        case film, spotify
    }

    /// Where the film stood when the desktop went over to Spotify, so going back picks up the same
    /// clip at the same moment even if the extension process was restarted in between.
    struct Resume: Codable, Equatable {
        var id: String
        var position: Double
    }

    /// How the wallpaper's copy of Liquify's background differs from Spotify's own: each is a
    /// multiplier on the setting Liquify already has, applied by Liquify to the frames it renders
    /// for the desktop and to nothing else.
    struct SpotifyTuning: Codable, Equatable {
        var blur = 1.0
        var distortion = 1.0
        var speed = 1.0
    }

    struct Track: Codable, Equatable {
        let id: String
        let title: String
        let path: String
    }

    enum Action: Codable, Equatable {
        case play(Int)
        case previous
        case next
        case seek(Double)
    }

    struct Command: Codable, Equatable {
        var revision: UInt64
        var actionRevision: UInt64
        var action: Action?
        var tracks: [Track]
        var running: Bool
        var paused: Bool
        var speed: Double
        var repeatOne: Bool
        var shuffle: Bool
        /// Absent in a snapshot an older build left behind, which is exactly what an upgrade
        /// leaves the extension reading until the new agent publishes over it.
        var transition: Transition?
        /// Absent means film, for the same reason `transition` is optional.
        var backdrop: Backdrop?
        var spotify: SpotifyTuning?

        var blend: Transition { transition ?? Transition() }
        var scene: Backdrop { backdrop ?? .film }
    }

    struct Status: Codable, Equatable {
        var position = 0.0
        var duration = 0.0
        var title = ""
        var id = ""
        var actionRevision: UInt64 = 0
        var heartbeat = Date.distantPast

        var renderer: [String: String]?

        var isLive: Bool { Date().timeIntervalSince(heartbeat) < 3 }
    }

    static func readCommand() -> Command? { read(Command.self, from: command) }
    static func readStatus() -> Status? { read(Status.self, from: status) }

    static func write(_ command: Command) { write(command, to: self.command) }
    static func write(_ status: Status) { write(status, to: self.status) }

    static func readResume() -> Resume? { read(Resume.self, from: resume) }
    static func write(_ resume: Resume) { write(resume, to: self.resume) }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("aerialite: native IPC write failed: \(error)\n".utf8))
        }
    }
}
