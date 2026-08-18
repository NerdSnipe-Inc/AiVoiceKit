// Tests/AiVoiceKitTests/HotkeyShortcutTests.swift
import XCTest
@testable import AiVoiceKit

#if os(macOS)
final class HotkeyShortcutTests: XCTestCase {
    func testEqualShortcutsConflict() {
        let a = HotkeyShortcut(keyCode: 49, modifierFlags: .command)
        let b = HotkeyShortcut(keyCode: 49, modifierFlags: .command)
        XCTAssertTrue(a.conflictsWith(b))
    }

    func testDifferentKeyCodesDoNotConflict() {
        let a = HotkeyShortcut(keyCode: 49, modifierFlags: .command)
        let b = HotkeyShortcut(keyCode: 50, modifierFlags: .command)
        XCTAssertFalse(a.conflictsWith(b))
    }

    func testDisplayStringIsNonEmpty() {
        let s = HotkeyShortcut(keyCode: 49, modifierFlags: .command)
        XCTAssertFalse(s.displayString.isEmpty)
    }
}
#endif
