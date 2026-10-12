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

    public init(id: UUID = UUID(), text: String, kind: LineKind, session: String, transcript: String? = nil,
                received: Date = Date(), name: String? = nil) {
        self.id = id; self.text = text; self.kind = kind; self.session = session
        self.transcript = transcript; self.received = received; self.name = name
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
