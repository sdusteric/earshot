import Testing
@testable import EarshotKit

@Suite struct HotkeyDetectorTests {
    // Right Option down: the option mask plus the right option device bit.
    let rOptDown = KeyEvent.flagsChanged(keyCode: 61, flags: 0x80000 | 0x40)
    let rOptUp = KeyEvent.flagsChanged(keyCode: 61, flags: 0)

    @Test func holdGivesDownThenUp() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(rOptDown, at: 0); #expect(r == .down) }
        do { let r = d.handle(rOptUp, at: 1.0); #expect(r == .up) }
    }

    @Test func tapIsIgnored() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(rOptDown, at: 0); #expect(r == .down) }
        do { let r = d.handle(rOptUp, at: 0.1); #expect(r == .cancel) }
    }

    /// Option+2 types "@" on some layouts: never a command.
    @Test func chordCancels() {
        var d = HotkeyDetector(hotkey: .rightOption)
        _ = d.handle(rOptDown, at: 0)
        do { let r = d.handle(.keyDown, at: 0.3); #expect(r == .cancel) }
        do { let r = d.handle(rOptUp, at: 0.5); #expect(r == nil) }
    }

    @Test func anotherModifierDuringTheHoldCancels() {
        var d = HotkeyDetector(hotkey: .rightOption)
        _ = d.handle(rOptDown, at: 0)
        do { let r = d.handle(.flagsChanged(keyCode: 56, flags: 0x80000 | 0x40 | 0x20000), at: 0.3); #expect(r == .cancel) }
    }

    @Test func pressWhileAnotherModifierIsHeldIsNotAHold() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(.flagsChanged(keyCode: 61, flags: 0x80000 | 0x40 | 0x100000), at: 0); #expect(r == nil) }
        do { let r = d.handle(rOptUp, at: 1); #expect(r == nil) }
    }

    @Test func leftOptionIsNotTheHotkey() {
        var d = HotkeyDetector(hotkey: .rightOption)
        do { let r = d.handle(.flagsChanged(keyCode: 58, flags: 0x80000 | 0x20), at: 0); #expect(r == nil) }
    }

    @Test func rightCommand() {
        var d = HotkeyDetector(hotkey: .rightCommand)
        do { let r = d.handle(.flagsChanged(keyCode: 54, flags: 0x100000 | 0x10), at: 0); #expect(r == .down) }
        do { let r = d.handle(.flagsChanged(keyCode: 54, flags: 0), at: 0.5); #expect(r == .up) }
        do { let r = d.handle(rOptDown, at: 1); #expect(r == nil) }
    }

    @Test func offNeverFires() {
        var d = HotkeyDetector(hotkey: .off)
        do { let r = d.handle(rOptDown, at: 0); #expect(r == nil) }
        do { let r = d.handle(rOptUp, at: 1); #expect(r == nil) }
    }
}
