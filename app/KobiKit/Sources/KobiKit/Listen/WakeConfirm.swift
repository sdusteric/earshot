import Foundation

// Kobi wake: part 2 (the sound-alike example, and the rule in Listener.confirmsWake)
/// The second look at a wake, before Kobi shows it heard one: the words in
/// the first moments of the segment the spotter fired on. The listener passes
/// the wake only when those words start with the wake phrase (Listener.confirmsWake),
/// written as such or sounding like it ("hey your shot"), so other speech stays silent:
/// no chime, no orb. Only a greeting and the phrase written as such ever send the words after them.
public protocol WakeConfirmer: Sendable {
    /// What was said in `head` (16 kHz mono), or nil when this confirmer can't
    /// tell (not loaded, failed). Nil does not pass the wake by itself: the listener
    /// then passes it only on a strict spotter score (CtcWakeSpotter.unconfirmedThreshold),
    /// as it does for a confirm that runs past Listener.Timing.confirmLimit.
    func headText(_ head: [Float]) async -> String?
}

/// No second look: a wake passes on the spotter's score alone, at the strict
/// threshold. The default, and what tests that are not about the confirm use.
public struct PassThroughConfirmer: WakeConfirmer {
    public init() {}
    public func headText(_ head: [Float]) async -> String? { nil }
}

/// Asks each confirmer in turn and takes the first answer: the next one is asked
/// only when the one before has none (nil). An empty answer is an answer (nothing
/// was heard), so it ends the chain. Nil when none can tell.
public struct FirstAnswerConfirmer: WakeConfirmer {
    private let confirmers: [any WakeConfirmer]

    public init(_ confirmers: [any WakeConfirmer]) { self.confirmers = confirmers }

    public func headText(_ head: [Float]) async -> String? {
        for c in confirmers {
            if let text = await c.headText(head) { return text }
        }
        return nil
    }
}
