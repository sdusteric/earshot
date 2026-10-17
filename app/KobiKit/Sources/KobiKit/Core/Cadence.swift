import Foundation

/// How often Kobi repeats work that only helps while you are there to see
/// it. Pure, so the app and the tests agree.
public enum Cadence {
    /// Where a window is: key, on screen behind another, or out of sight
    /// (covered, minimized, on another Space, or closed).
    public struct Window: Sendable, Equatable {
        public var visible: Bool
        public var key: Bool
        public init(visible: Bool = true, key: Bool = true) { self.visible = visible; self.key = key }
    }

    /// The session page reads the session's transcript again every 4 s while
    /// its window is key, every 15 s while it shows behind another app, and
    /// not at all out of sight. Nil: no reading.
    public static func transcriptPoll(_ w: Window) -> Duration? {
        guard w.visible else { return nil }
        return w.key ? .seconds(4) : .seconds(15)
    }

    /// The orb draws only where it can be seen: while Kobi listens, works or
    /// speaks, or while it rests turning (the Activity window's orb).
    public static func orbPaused(active: Bool, spinsWhenIdle: Bool, visible: Bool) -> Bool {
        !visible || (!active && !spinsWhenIdle)
    }

    /// The shortest wait between two `claude agents` checks made for the
    /// session list, or nil for none at all: locked or asleep, nobody sees the
    /// list and the wake word can't listen, so the check waits for your return.
    /// Low Power Mode spaces them out. Sessions that need you are heard from the
    /// plugin at once either way; this list only fills in what it doesn't say.
    public static func directoryRefresh(locked: Bool, asleep: Bool, lowPower: Bool) -> TimeInterval? {
        if locked || asleep { return nil }
        return lowPower ? 180 : 60
    }

    /// Whether a check is due now, given when the last one was made.
    public static func directoryRefreshDue(last: Date?, now: Date = Date(),
                                           locked: Bool, asleep: Bool, lowPower: Bool) -> Bool {
        guard let floor = directoryRefresh(locked: locked, asleep: asleep, lowPower: lowPower) else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= floor
    }
}
