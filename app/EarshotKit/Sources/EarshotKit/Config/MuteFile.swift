import Foundation

/// The mute file the plugin and the app share (~/.earshot/mute). Empty means
/// muted until you unmute; a Unix time means muted until then. Either side,
/// including /earshot mute in the terminal, can write it at any time.
public enum MuteFile {
    /// Until when the file says Earshot is muted: `.distantFuture` until you
    /// unmute, nil when not muted (no file, or a time already past).
    public static func until(_ text: String?, now: Date = Date()) -> Date? {
        guard let text else { return nil }
        let digits = text.filter { $0.isNumber }
        if digits.isEmpty { return .distantFuture }
        let until = Date(timeIntervalSince1970: TimeInterval(digits) ?? 0)
        return until > now ? until : nil
    }

    /// What to write for a mute that ends at `until` (whole seconds, as the plugin writes it).
    public static func text(until: Date) -> String { "\(Int(until.timeIntervalSince1970))\n" }
}
