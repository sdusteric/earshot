/// A key event from the event tap, reduced to what the hotkey needs.
public enum KeyEvent: Sendable, Equatable {
    /// A modifier went down or up. `flags` is the raw CGEventFlags after the change.
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    /// Any other key was pressed.
    case keyDown
}

/// Turns key events into a hold of one modifier key. A tap shorter than
/// `minHold`, a chord, or a press with another modifier held is not a hold.
public struct HotkeyDetector: Sendable {
    public enum Action: Sendable, Equatable { case down, up, cancel }

    static let alternate: UInt64 = 0x80000, command: UInt64 = 0x100000, shift: UInt64 = 0x20000,
               control: UInt64 = 0x40000, function: UInt64 = 0x800000
    static let rightOptionBit: UInt64 = 0x40, rightCommandBit: UInt64 = 0x10

    private let keyCode: UInt16?
    private let sideBit: UInt64
    private let ownMask: UInt64
    private let minHold: Double
    private var downAt: Double?
    private var cancelled = false

    public init(hotkey: KobiConfig.Hotkey, minHold: Double = 0.2) {
        self.minHold = minHold
        switch hotkey {
        case .rightOption: keyCode = 61; sideBit = Self.rightOptionBit; ownMask = Self.alternate
        case .rightCommand: keyCode = 54; sideBit = Self.rightCommandBit; ownMask = Self.command
        case .off: keyCode = nil; sideBit = 0; ownMask = 0
        }
    }

    public mutating func handle(_ e: KeyEvent, at seconds: Double) -> HotkeyDetector.Action? {
        guard let keyCode else { return nil }
        let others = (Self.alternate | Self.command | Self.shift | Self.control | Self.function) & ~ownMask
        switch e {
        case .keyDown:
            return cancelHold()
        case .flagsChanged(let code, let flags):
            if code != keyCode { return cancelHold() }
            let pressed = flags & sideBit != 0
            if pressed {
                guard downAt == nil, flags & others == 0 else { return nil }
                downAt = seconds
                cancelled = false
                return .down
            }
            guard let start = downAt else { return nil }
            downAt = nil
            if cancelled { cancelled = false; return nil }
            return seconds - start < minHold ? .cancel : .up
        }
    }

    /// Another key while the hotkey is held: the hold is over, and its release does nothing.
    private mutating func cancelHold() -> HotkeyDetector.Action? {
        guard downAt != nil, !cancelled else { return nil }
        cancelled = true
        return .cancel
    }
}
