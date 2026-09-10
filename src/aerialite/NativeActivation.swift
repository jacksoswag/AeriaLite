import Foundation

/// Registers and selects AeriaLite's com.apple.wallpaper extension. Activation succeeds only
/// after a newly launched extension process publishes a heartbeat. There is no renderer fallback.
enum NativeActivation {
    static let extensionID = "com.jacksonadams.aerialite.wallpaper-extension"
    private static let store = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    static func activate() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw Failure("native AeriaLite wallpapers require macOS 26 or newer")
        }
        let builtIn = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Extensions/AeriaLiteWallpaperExtension.appex")
        guard FileManager.default.fileExists(atPath: builtIn.path) else {
            throw Failure("wallpaper extension is missing from the app bundle")
        }

        // Never let a process from a previous bundle revision satisfy the health check.
        _ = try? run("/usr/bin/pkill", ["-x", "AeriaLiteWallpaperExtension"])
        try? FileManager.default.removeItem(at: NativeIPC.status)
        try run("/usr/bin/pluginkit", ["-a", builtIn.path])
        let expectedPath = builtIn.standardizedFileURL.path
        var registration = ""
        for _ in 0..<20 {
            registration = try run("/usr/bin/pluginkit", [
                "-m", "-A", "-D", "-v", "-i", extensionID
            ])
            if registration.contains(expectedPath) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        // pkd can retain the vanished path of an atomically renamed staging bundle. Restarting
        // the per-user daemon is safe—it is launchd-managed—and gives the installed path one
        // clean registration attempt before installation is rejected.
        if !registration.contains(expectedPath) {
            _ = try? run("/usr/bin/killall", ["pkd"])
            Thread.sleep(forTimeInterval: 0.5)
            try run("/usr/bin/pluginkit", ["-a", builtIn.path])
            for _ in 0..<20 {
                registration = try run("/usr/bin/pluginkit", [
                    "-m", "-A", "-D", "-v", "-i", extensionID
                ])
                if registration.contains(expectedPath) { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard registration.contains(expectedPath) else {
            let observed = registration.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure("pluginkit did not register \(expectedPath); observed: \(observed)")
        }

        let data = try Data(contentsOf: store)
        guard var plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        else { throw Failure("could not decode the macOS wallpaper store") }
        backup(data)

        let desktop = try extensionSlot()
        plist["AllSpacesAndDisplays"] = applying(desktop, to: plist["AllSpacesAndDisplays"])
        plist["SystemDefault"] = applying(desktop, to: plist["SystemDefault"])

        if let spaces = plist["Spaces"] as? [String: Any] {
            var updated = spaces
            for (spaceID, rawSpace) in spaces {
                guard var space = rawSpace as? [String: Any] else { continue }
                space["Default"] = applying(desktop, to: space["Default"])
                if let displays = space["Displays"] as? [String: Any] {
                    var updatedDisplays = displays
                    for (displayID, rawDisplay) in displays {
                        updatedDisplays[displayID] = applying(desktop, to: rawDisplay)
                    }
                    space["Displays"] = updatedDisplays
                }
                updated[spaceID] = space
            }
            plist["Spaces"] = updated
        }

        let encoded = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary,
                                                          options: 0)
        try encoded.write(to: store, options: Data.WritingOptions.atomic)

        // WallpaperAgent caches the old store in memory and otherwise writes it back over the new
        // selection. Restart it first, then restart Dock so the fresh agent receives the
        // authoritative display/Space map and acquires this extension.
        //
        // One restart is not enough. Replacing the app bundle makes pkd re-register the extension
        // seconds later, on its own schedule, and re-registration removes the running instance.
        // WallpaperAgent's immediate relaunch of a bundle mid-re-registration fails, and a failed
        // acquire is not retried: the agent falls back to Apple's aerial and stays there, so an
        // install that verified as live drifts silently onto Apple's wallpaper a few seconds after
        // the installer exits. Restarting the agent once pkd has settled always recovers it, so
        // activation restarts until the backend holds rather than until it first appears.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let restarted = Date()
            restartWallpaperServices()
            if live(after: restarted, until: deadline), holds(since: restarted) { return }
        }

        // A failed health check must not strand every Space on a dead provider. Restore the exact
        // pre-install store and unregister this bundle. This is transactional rollback, not a
        // renderer fallback: AeriaLite remains stopped until its native extension works.
        try? data.write(to: store, options: .atomic)
        _ = try? run("/usr/bin/pluginkit", ["-r", builtIn.path])
        restartWallpaperServices()
        throw Failure("the native wallpaper extension did not stay running within 60 seconds")
    }

    /// Only heartbeats from after the restart count. The outgoing agent relaunches the extension
    /// on demand while it is being torn down, and that short-lived process publishes a heartbeat
    /// newer than the store rewrite, so a sample taken from before the restart passes on a session
    /// that is already dying.
    private static func live(after restarted: Date, until deadline: Date) -> Bool {
        while Date() < deadline {
            if let status = NativeIPC.readStatus(), status.heartbeat >= restarted, status.isLive {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// A backend WallpaperAgent is actually presenting keeps publishing. One that was launched to
    /// answer a single query, is being handed off between agents, or is about to be removed by a
    /// pkd re-registration stops within a few beats, which is what this waits out.
    private static func holds(since restarted: Date) -> Bool {
        for _ in 0..<32 {
            Thread.sleep(forTimeInterval: 0.25)
            guard let status = NativeIPC.readStatus(), status.heartbeat >= restarted,
                  status.isLive
            else { return false }
        }
        return true
    }

    private static func restartWallpaperServices() {
        _ = try? run("/usr/bin/killall", ["WallpaperAgent"])
        Thread.sleep(forTimeInterval: 1)
        _ = try? run("/usr/bin/killall", ["Dock"])
    }

    /// Each store section carries two slots. `Desktop` is the wallpaper; `Idle` is what macOS 26
    /// presents once the Mac has been left alone, and it defaults to Apple's own aerial. Filling
    /// only `Desktop` leaves an untouched Mac showing Apple's footage over a backend that is still
    /// decoding underneath, which is both wrong to look at and wasteful, so both slots take the
    /// same selection. That is a visible change to the idle screen and is reverted with the rest
    /// of the store if the health check fails.
    private static func applying(_ desktop: [String: Any], to raw: Any?) -> [String: Any] {
        var section = raw as? [String: Any] ?? [:]
        section.removeValue(forKey: "Linked")
        section["Type"] = "individual"
        section["Desktop"] = desktop
        section["Idle"] = desktop
        return section
    }

    private static func extensionSlot() throws -> [String: Any] {
        slot(provider: extensionID, encodedOptions: "$null")
    }

    private static func slot(provider: String, encodedOptions: Any) -> [String: Any] {
        [
            "Content": [
                "Choices": [["Provider": provider, "Configuration": Data(), "Files": []]],
                "EncodedOptionValues": encodedOptions,
                "Shuffle": "$null"
            ],
            "LastSet": Date(),
            "LastUse": Date()
        ]
    }

    private static func backup(_ data: Data) {
        let folder = Paths.root.appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Wallpaper-Index-\(Int(Date().timeIntervalSince1970)).plist"
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for old in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(5) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard task.terminationStatus == 0 else {
            throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(output)")
        }
        return output
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
