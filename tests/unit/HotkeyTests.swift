import Carbon.HIToolbox
import Foundation
import XCTest
@testable import aerialite

final class HotkeyTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testDefaultsAreTheFunctionRow() throws {
        let keys = try decode("{}").keybinds
        XCTAssertEqual(keys.next, "f9")
        XCTAssertEqual(keys.previous, "f7")
        XCTAssertEqual(keys.playPause, "f8")
        XCTAssertEqual(keys.backdrop, "f10")
        XCTAssertEqual(keys.quit, "f10")
    }

    func testPartialKeybindsKeepTheRestAndEmptyTurnsOneOff() throws {
        let keys = try decode(#"{ "keybinds": { "next": "cmd+shift+right", "backdrop": "" } }"#).keybinds
        XCTAssertEqual(keys.next, "cmd+shift+right")
        XCTAssertEqual(keys.previous, "f7")
        XCTAssertEqual(keys.backdrop, "")
    }

    func testChordsParse() {
        XCTAssertEqual(Chord("f9"), Chord(code: kVK_F9, modifiers: 0))
        XCTAssertEqual(Chord(" Cmd + Shift + Space "),
                       Chord(code: kVK_Space, modifiers: cmdKey | shiftKey))
        XCTAssertEqual(Chord("ctrl+opt+k"), Chord(code: kVK_ANSI_K, modifiers: controlKey | optionKey))
        XCTAssertEqual(Chord("alt+7"), Chord(code: kVK_ANSI_7, modifiers: optionKey))
    }

    func testUnreadableChordsAreRejected() {
        XCTAssertNil(Chord(""))
        XCTAssertNil(Chord("hyper+f9"))
        XCTAssertNil(Chord("f21"))
        XCTAssertNil(Chord("cmd+"))
    }
}

private extension Chord {
    init(code: Int, modifiers: Int) {
        self.init(rawCode: UInt32(code), modifiers: UInt32(modifiers))
    }
}
