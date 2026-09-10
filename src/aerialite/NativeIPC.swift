import Foundation

/// The only bridge between the menu app and Apple's wallpaper-extension process. Both sides
/// exchange complete, atomically-replaced snapshots in /Users/Shared; no window renderer or
/// alternate playback path exists in the app process.
enum NativeIPC {
    static let root = URL(fileURLWithPath: "/Users/Shared/AeriaLite", isDirectory: true)
    static let command = root.appendingPathComponent("playback-command.json")
    static let status = root.appendingPathComponent("playback-status.json")

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
    }

    struct Status: Codable, Equatable {
        var position = 0.0
        var duration = 0.0
        var title = ""
        var id = ""
        var actionRevision: UInt64 = 0
        var heartbeat = Date.distantPast

        var isLive: Bool { Date().timeIntervalSince(heartbeat) < 3 }
    }

    static func readCommand() -> Command? { read(Command.self, from: command) }
    static func readStatus() -> Status? { read(Status.self, from: status) }

    static func write(_ command: Command) { write(command, to: self.command) }
    static func write(_ status: Status) { write(status, to: self.status) }

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
