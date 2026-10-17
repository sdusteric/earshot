import AppKit
import Foundation
import IOKit.ps

/// Lock, sleep, battery and Low Power Mode, from notifications. Nothing polls.
@MainActor public final class SystemWatch {
    public struct State: Sendable, Equatable {
        public var locked = false
        public var asleep = false
        public var onBattery = false
        public var lowPower = false
    }

    public private(set) var state = State() {
        didSet { if state != oldValue { conts.values.forEach { $0.yield(state) } } }
    }
    private var conts: [UUID: AsyncStream<State>.Continuation] = [:]
    private var tokens: [any NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    public init() {
        state.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        state.onBattery = Self.onBattery()
        let distributed = DistributedNotificationCenter.default()
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.locked = true }
        })
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.locked = false }
        })
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.asleep = true }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.asleep = false }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let watch = Unmanaged<SystemWatch>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { watch.state.onBattery = SystemWatch.onBattery() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    public func changes() -> AsyncStream<State> {
        let (stream, cont) = AsyncStream<State>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(state)
        cont.onTermination = { [weak self] _ in Task { @MainActor in self?.conts[id] = nil } }
        return stream
    }

    nonisolated static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
