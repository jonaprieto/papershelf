import XCTest
import SwiftUI
@testable import PaperShelf

/// A key press carries the state of the key as well as the chord: Caps Lock, and the
/// numeric-pad and function flags the system sets on keypad digits and arrow keys. None of
/// those is a modifier anybody pressed, and a shortcut must not fail because of them.
final class ShortcutMatchTests: XCTestCase {

    func testAPlainKeyStillMatchesWithCapsLockOn() {
        let highlight = Shortcut("1", [])
        XCTAssertTrue(highlight.matches(key: "1", modifiers: []))
        XCTAssertTrue(highlight.matches(key: "1", modifiers: .capsLock),
                      "Caps Lock stopped the highlighter keys working")
        XCTAssertTrue(highlight.matches(key: "1", modifiers: .numericPad),
                      "the 1 on a numeric keypad is still 1")
    }

    /// Arrow keys always arrive with the numeric-pad and function flags set.
    func testAnArrowShortcutMatchesTheArrowKey() {
        let next = Shortcut(String(Character(UnicodeScalar(0xF701)!)), [])
        XCTAssertTrue(next.matches(key: .downArrow, modifiers: [.numericPad, .function]))
    }

    /// And a chord is still a chord: the modifiers that count are compared exactly.
    func testTheModifiersThatCountStillHaveToAgree() {
        let undo = Shortcut("z", .command)
        XCTAssertTrue(undo.matches(key: "z", modifiers: [.command, .capsLock]))
        XCTAssertFalse(undo.matches(key: "z", modifiers: []))
        XCTAssertFalse(undo.matches(key: "z", modifiers: [.command, .shift]))
        XCTAssertFalse(Shortcut("1", []).matches(key: "1", modifiers: .option))
    }
}
