import XCTest
@testable import aerialite

/// The Liquify port follows `NativeIPC.agentRunning`, so this probe is what keeps it closed.
final class AgentLockTests: XCTestCase {
    func testProbeFollowsTheExclusiveLock() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerialite-lock-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(NativeIPC.isLocked(url))
        let holder = open(url.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(holder, 0)
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(NativeIPC.isLocked(url))
        close(holder)
        XCTAssertFalse(NativeIPC.isLocked(url))
    }

    func testMissingLockFileMeansNoAgent() {
        XCTAssertFalse(NativeIPC.isLocked(URL(fileURLWithPath: "/nonexistent/aerialite/agent.lock")))
    }
}
