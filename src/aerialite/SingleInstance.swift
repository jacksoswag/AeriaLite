import Foundation

/// The command file is process-global state, not per-agent state, so a second `aerialite play` does
/// not merely duplicate work: quitting it publishes `running: false` and stops the wallpaper the
/// first agent is driving, which then never republishes because its own state has not changed. The
/// installer puts `aerialite` on PATH and `play` is the default subcommand, so starting a second
/// one by hand is easy to do without meaning to.
enum SingleInstance {
    /// Held for the life of the process. The kernel drops it on exit, crash included, so a stale
    /// lock cannot outlive the agent that took it.
    private nonisolated(unsafe) static var held: Int32 = -1

    /// Installation replaces the running agent, and launchd may bootstrap the new job before the
    /// old process has finished its termination handler, so a brief overlap is legitimate handover
    /// rather than a second agent and is waited out instead of refused.
    static func acquire(waiting timeout: TimeInterval = 5) -> Bool {
        let path = Paths.root.appendingPathComponent("agent.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        // A lock that cannot be taken at all must not be what keeps the desktop empty.
        guard descriptor >= 0 else { return true }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                held = descriptor
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline

        close(descriptor)
        return false
    }
}
