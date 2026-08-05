import Foundation

/// macOS keeps drawing its own wallpaper under AeriaLite's window, where a configured aerial holds a
/// second decoder open out of sight. A plain kill buys under two seconds against launchd, so the
/// job leaves the login session instead and comes back on quit.
enum AppleWallpaper {
    private static let uid = "\(getuid())"
    private static let domain = "gui/\(uid)"
    private static let service = "\(domain)/com.apple.wallpaper.agent"
    private static let plist = "/System/Library/LaunchAgents/com.apple.wallpaper.plist"

    /// Runs before the cache pass, since a live agent rewrites what was just deleted.
    static func cull() {
        run("/bin/launchctl", ["bootout", service])
        // its extensions are separate processes that outlive it, and -f reaches the plugin ones
        // through their path inside WallpaperAgent.app
        run("/usr/bin/pkill", ["-u", uid, "-f", "WallpaperAgent|WallpaperAerialsExtension"])
    }

    /// Quitting hands the desktop back to macOS, which needs the job in the domain again. It is
    /// on demand, so bootstrap alone leaves the desktop blank until something asks for a picture.
    static func restore() {
        run("/bin/launchctl", ["bootstrap", domain, plist])
        run("/bin/launchctl", ["kickstart", service])
    }

    /// Sequential: a sweep landing before the bootout kills a job launchd immediately respawns.
    private static func run(_ tool: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice   // "No such process" every time one is already gone
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
    }
}
