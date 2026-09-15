import XCTest
@testable import aerialite

final class RenderHealthTests: XCTestCase {
    func testHiddenDesktopNeverBecomesRendererFailure() {
        var health = RenderHealth()
        health.restart(at: 0)
        health.callback(at: 0)
        health.submitted(at: 0)
        // Longer than both the old 26-retry limit and a typical fullscreen session.
        for second in 1...120 { XCTAssertFalse(health.isStalled(at: Double(second))) }
    }

    func testReturningFromFullscreenGetsFreshDecodeGrace() {
        var health = RenderHealth()
        health.callback(at: 0)
        health.submitted(at: 0)
        health.callback(at: 120)
        XCTAssertFalse(health.isStalled(at: 120))
        health.callback(at: 120.5)
        health.submitted(at: 120.5)
        XCTAssertFalse(health.isStalled(at: 120.5))
    }

    func testContinuousCallbacksWithoutFramesStillDetectFailure() {
        var health = RenderHealth()
        for tick in 0...60 { health.callback(at: Double(tick) / 10) }
        XCTAssertTrue(health.isStalled(at: 6))
    }

    func testFramesKeepRendererHealthy() {
        var health = RenderHealth()
        for tick in 0...600 {
            let now = Double(tick) / 10
            health.callback(at: now)
            if tick.isMultiple(of: 5) { health.submitted(at: now) }
            XCTAssertFalse(health.isStalled(at: now))
        }
    }

    func testRestartDoesNotMistakeOldFramesForCurrentFailure() {
        var health = RenderHealth()
        health.callback(at: 0)
        health.submitted(at: 0)
        health.restart(at: 60)
        XCTAssertFalse(health.isStalled(at: 60))
        health.callback(at: 61)
        XCTAssertFalse(health.isStalled(at: 61))
    }
}
