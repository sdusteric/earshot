import Foundation

/// One line to say.
public struct SpokenLine: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var kind: LineKind
    public var session: String
    /// The session's transcript, for lines that wait on you: a newer
    /// transcript means you answered, for example with Esc, which fires no hook.
    public var transcript: String?
    public var received: Date
    /// The session's spoken name, when the plugin sent one ("billing service").
    public var name: String?
    /// A Kokoro voice for this line only, instead of the one in the config: a
    /// voice preview in Settings is said in the voice it is for, even after you
    /// picked another. Kept for lines short enough not to be split (80 characters).
    public var voice: String?

    public init(id: UUID = UUID(), text: String, kind: LineKind, session: String, transcript: String? = nil,
                received: Date = Date(), name: String? = nil, voice: String? = nil) {
        self.id = id; self.text = text; self.kind = kind; self.session = session
        self.transcript = transcript; self.received = received; self.name = name; self.voice = voice
    }

    /// The same line under a new id. A line stopped mid-play needs one to be
    /// said again: the player refuses an id it was told to stop.
    func withNewID() -> SpokenLine {
        SpokenLine(text: text, kind: kind, session: session, transcript: transcript, received: received, name: name,
                   voice: voice)
    }

    /// The session waits on you: a "needs you" line, or a session's line that
    /// ends by asking something ("Want one more round, or ship it?"), which
    /// the plugin sends as a finished turn. Kobi's own lines never count.
    public var asksYou: Bool {
        switch kind {
        case .need, .reply: true
        case .done, .alert, .beat, .ack: text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        case .roll, .intro, .confirm, .recap: false
        }
    }

    /// speak.sh's still_waiting, turned around: the transcript changed more
    /// than 2 seconds after the line arrived.
    public static func transcriptAnswered(_ line: SpokenLine) -> Bool {
        guard let path = line.transcript,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return false }
        return modified.timeIntervalSince(line.received) > 2
    }
}
