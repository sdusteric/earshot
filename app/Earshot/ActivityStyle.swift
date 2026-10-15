import EarshotKit
import SwiftUI

/// The Activity window's colors, from the orb's dark glass. Each state
/// color keeps one meaning (see DESIGN.md).
enum ActivityPalette {
    static let ground = Color(red: 0.043, green: 0.051, blue: 0.071)
    static let raised = Color(red: 0.067, green: 0.078, blue: 0.106)
    static let track = Color(red: 0.11, green: 0.125, blue: 0.17)
    static let tick = Color(red: 0.23, green: 0.255, blue: 0.32)
    static let you = Color(red: 0.39, green: 0.77, blue: 1.0)
    static let voice = Color(red: 1.0, green: 0.74, blue: 0.42)

    /// A line's color: blue for what you said, orange for what waits on you,
    /// red for alerts, green for done, amber for the rest of Earshot's voice.
    static func color(_ e: HistoryEntry) -> Color {
        if e.kind == .heard { return you }
        if e.asksYou { return .orange }
        switch e.lineKind {
        case .need, .reply: return .orange
        case .alert: return .red
        case .done: return .green
        default: return voice
        }
    }
}

/// The Activity window's motion. It moves only when a session's state moves:
/// a session changing groups, something arriving that waits on you or
/// leaving once answered, a new line in a session. With Reduce Motion each
/// becomes a crossfade.
enum ActivityMotion {
    /// A session moving between groups, and the layout settling around it.
    static func move(_ reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }

    /// The sidebar's rows: the system list slides rows it inserts, so with
    /// Reduce Motion it doesn't animate at all.
    static func sidebar(_ reduce: Bool) -> Animation? {
        reduce ? nil : .smooth(duration: 0.3)
    }

    /// A waiting card or pending box: it settles in from just above, and on
    /// its way out (answered) shrinks a little as it fades, a bit faster.
    static func card(_ reduce: Bool) -> AnyTransition {
        if reduce { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97)).animation(.easeOut(duration: 0.2)))
    }

    /// A new line at the end of a session's conversation rises into place.
    static func line(_ reduce: Bool) -> AnyTransition {
        if reduce { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)),
                           removal: .opacity.animation(.easeOut(duration: 0.2)))
    }

    /// A row that comes or goes in a list of rows, such as While You Were Away.
    static func row(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
}

/// Earshot's newest line, typing itself in as it is said.
struct NowStrip: View {
    let entry: HistoryEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A line this new types in here and waits to join the list below.
    static func isFresh(_ e: HistoryEntry?, now: Date = Date()) -> Bool {
        guard let e else { return false }
        return now.timeIntervalSince(e.date) < 45
    }

    var body: some View {
        if let entry, !Self.isFresh(entry) {
            Text("Quiet since \(entry.date.formatted(date: .omitted, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let entry {
            let fresh = Date().timeIntervalSince(entry.date) < 20 && !reduceMotion
            TimelineView(.animation(paused: !fresh)) { t in
                let text = entry.kind == .heard ? (entry.reply ?? entry.text) : entry.text
                let shown = fresh ? Int(t.date.timeIntervalSince(entry.date) * 38) : text.count
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(ActivityPalette.voice).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(String(text.prefix(max(0, shown))))
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Last line: \(entry.kind == .heard ? (entry.reply ?? entry.text) : entry.text)")
        }
    }
}
