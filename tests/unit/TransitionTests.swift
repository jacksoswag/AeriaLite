import Foundation
import XCTest
@testable import aerialite

final class TransitionTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testConfigWithoutTransitionKeepsDefaults() throws {
        let settings = try decode(#"{ "streamMode": 2 }"#)
        XCTAssertEqual(settings.transition, Transition())
        XCTAssertTrue(settings.transition.isEnabled)
        XCTAssertTrue(settings.transition.manual)
    }

    func testHandEditedTransitionIsRead() throws {
        let settings = try decode("""
        { "transition": { "seconds": 2.5, "style": "crossfade", "curve": "easeOut",
                          "spread": 0.2, "stagger": -0.4, "chroma": 0.9, "manual": false } }
        """)
        let blend = settings.transition
        XCTAssertEqual(blend.seconds, 2.5)
        XCTAssertEqual(blend.style, .crossfade)
        XCTAssertEqual(blend.curve, .bezier(0, 0, 0.58, 1))
        XCTAssertEqual(blend.spread, 0.2)
        XCTAssertEqual(blend.stagger, -0.4)
        XCTAssertEqual(blend.chroma, 0.9)
        XCTAssertFalse(blend.manual)
    }

    /// The file that reaches the process compositing the desktop is hand-edited and has no schema,
    /// so every number in it has to survive being wrong.
    func testNonsenseValuesAreClampedRatherThanObeyed() throws {
        let blend = try decode("""
        { "transition": { "seconds": 900, "spread": 4, "stagger": -17, "chroma": -2 } }
        """).transition
        XCTAssertEqual(blend.seconds, 10)
        XCTAssertEqual(blend.stagger, -1)
        XCTAssertEqual(blend.chroma, 0)
        // Strictly below 1. A pixel whose crossing has no width at all is a pixel that jumps, and
        // that width is what the shader divides by.
        XCTAssertLessThan(blend.spread, 1)
    }

    /// A config.json written against the first version of this feature names knobs that no longer
    /// exist. Ignoring them costs those keys their values, not the rest of the file.
    func testKeysFromTheSupersededAlgorithmAreIgnored() throws {
        let blend = try decode("""
        { "transition": { "seconds": 2, "warp": 0.9, "bloom": 0.9, "scale": 3, "style": "flow" } }
        """).transition
        XCTAssertEqual(blend.seconds, 2)
        XCTAssertEqual(blend.style, .difference)
        XCTAssertEqual(blend.spread, Transition().spread)
    }

    func testUnknownStyleAndCurveFallBackWithoutLosingTheRestOfTheKey() throws {
        let blend = try decode("""
        { "transition": { "seconds": 0.8, "style": "kaleidoscope", "curve": "bouncy" } }
        """).transition
        XCTAssertEqual(blend.seconds, 0.8)
        XCTAssertEqual(blend.style, Transition().style)
        XCTAssertEqual(blend.curve, Transition().curve)
    }

    func testStyleNoneAndZeroSecondsBothMeanTheCut() throws {
        XCTAssertFalse(try decode(#"{ "transition": { "style": "none" } }"#).transition.isEnabled)
        XCTAssertFalse(try decode(#"{ "transition": { "seconds": 0 } }"#).transition.isEnabled)
    }

    func testCubicBezierArrayIsAccepted() throws {
        let blend = try decode(#"{ "transition": { "curve": [0.9, 0, 0.1, 1] } }"#).transition
        XCTAssertEqual(blend.curve, .bezier(0.9, 0, 0.1, 1))
        // Slow at both ends, fast through the middle, and still pinned at its endpoints.
        XCTAssertEqual(blend.progress(at: 0), 0, accuracy: 1e-4)
        XCTAssertEqual(blend.progress(at: 1), 1, accuracy: 1e-4)
        XCTAssertEqual(blend.progress(at: 0.5), 0.5, accuracy: 1e-3)
        XCTAssertLessThan(blend.progress(at: 0.2), 0.2)
    }

    func testEveryCurveIsPinnedAtItsEndpointsAndNeverGoesBackwards() {
        let curves: [Curve] = [.linear, .smoothstep, .smootherstep,
                               .bezier(0.42, 0, 0.58, 1), .bezier(0.25, 0.1, 0.25, 1),
                               .bezier(0, 0, 0, 0), .bezier(1, 1, 1, 1)]
        for curve in curves {
            XCTAssertEqual(curve(0), 0, accuracy: 1e-4, "\(curve) at 0")
            XCTAssertEqual(curve(1), 1, accuracy: 1e-4, "\(curve) at 1")
            var previous = -Double.infinity
            for step in 0...200 {
                let value = curve(Double(step) / 200)
                XCTAssertTrue(value.isFinite, "\(curve) produced \(value)")
                XCTAssertGreaterThanOrEqual(value, previous - 1e-6, "\(curve) went backwards")
                previous = value
            }
        }
    }

    func testCurveClampsOutsideItsWindow() {
        XCTAssertEqual(Curve.smootherstep(-3), 0)
        XCTAssertEqual(Curve.smootherstep(4), 1)
    }

    /// An upgrade leaves the extension reading whatever the outgoing agent last wrote, which has
    /// no transition in it at all.
    func testCommandWithoutTransitionStillDecodesAndBlends() throws {
        let json = """
        { "revision": 3, "actionRevision": 1, "tracks": [], "running": true, "paused": false,
          "speed": 1, "repeatOne": false, "shuffle": false }
        """
        let command = try JSONDecoder().decode(NativeIPC.Command.self, from: Data(json.utf8))
        XCTAssertNil(command.transition)
        XCTAssertEqual(command.blend, Transition())
    }

    /// The seed file is the documentation anyone editing this reads first, so the curve has to be
    /// written back out as the name it was given rather than as four numbers.
    func testPresetCurvesRoundTripAsNames() throws {
        var settings = Settings()
        settings.transition.curve = .bezier(0.42, 0, 0.58, 1)
        let written = try JSONEncoder().encode(settings)
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("\"easeInOut\""))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: written).transition.curve,
                       .bezier(0.42, 0, 0.58, 1))
    }
}
