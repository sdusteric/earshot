import CoreGraphics
import EarshotKit
import Foundation

/// Watches modifier and key events for the hotkey. Listen only: it never
/// changes or blocks an event. Needs Input Monitoring permission.
@MainActor final class HotkeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector: HotkeyDetector
    private var currentHotkey: EarshotConfig.Hotkey
    private var held = false
    private let onAction: @MainActor (HotkeyDetector.Action) -> Void

    init(hotkey: EarshotConfig.Hotkey, onAction: @escaping @MainActor (HotkeyDetector.Action) -> Void) {
        detector = HotkeyDetector(hotkey: hotkey)
        currentHotkey = hotkey
        self.onAction = onAction
    }

    static var allowed: Bool { CGPreflightListenEventAccess() }

    /// Shows macOS's Input Monitoring prompt (once) and adds Earshot to the list.
    static func requestAccess() { _ = CGRequestListenEventAccess() }

    func setHotkey(_ h: EarshotConfig.Hotkey) {
        guard h != currentHotkey else { return }
        currentHotkey = h
        detector = HotkeyDetector(hotkey: h)
    }

    /// False when Input Monitoring is not allowed yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue))
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
            if let refcon {
                let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { tap.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            // A release may have been lost while the tap was off.
            detector = HotkeyDetector(hotkey: currentHotkey)
            if held {
                held = false
                onAction(.cancel)
            }
            return
        }
        let e: KeyEvent = type == .keyDown
            ? .keyDown
            : .flagsChanged(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue)
        if let a = detector.handle(e, at: ProcessInfo.processInfo.systemUptime) {
            switch a {
            case .down: held = true
            case .up, .cancel: held = false
            }
            onAction(a)
        }
    }
}
