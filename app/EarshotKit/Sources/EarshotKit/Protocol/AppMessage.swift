import Foundation

/// Kinds of spoken lines, named as the plugin names them (see `tell` in speak.sh).
public enum LineKind: String, Codable, Sendable, CaseIterable {
    case need, reply, alert, done, beat, ack, roll, intro

    /// Kept for the catch-up while another app uses the mic. Progress updates
    /// and "On it" are stale by then.
    public var isHeld: Bool {
        switch self {
        case .need, .reply, .alert, .done: true
        default: false
        }
    }

    /// Catch-up order: lines that need you, then alerts, then finished lines.
    public var catchUpRank: Int {
        switch self {
        case .need, .reply: 0
        case .alert: 1
        default: 2
        }
    }
}

/// What a session is doing, as speak.sh's set_status says it, plus `closed`.
public enum SessionState: String, Codable, Sendable {
    case open, working, needs, reply, stuck, failed, done, closed
}

/// One message from the plugin: one JSON object per line.
public enum AppMessage: Sendable, Equatable {
    case say(Say)
    case status(Status)

    public static let version = 1

    public struct Say: Codable, Sendable, Equatable {
        public var text: String
        public var kind: LineKind
        public var session: String
        public var name: String?
        public var transcript: String?
        /// When the plugin sent it, in epoch milliseconds (app-send.zsh adds it).
        public var sent: Double?

        public init(text: String, kind: LineKind, session: String, name: String? = nil, transcript: String? = nil,
                    sent: Double? = nil) {
            self.text = text; self.kind = kind; self.session = session
            self.name = name; self.transcript = transcript; self.sent = sent
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            kind = try c.decode(LineKind.self, forKey: .kind)
            session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name)
            transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
            sent = try c.decodeIfPresent(Double.self, forKey: .sent)
        }
    }

    public struct Status: Codable, Sendable, Equatable {
        public var session: String
        public var state: SessionState
        public var detail: String?
        public var name: String?
        public var project: String?
        public var title: String?

        public init(session: String, state: SessionState, detail: String? = nil, name: String? = nil,
                    project: String? = nil, title: String? = nil) {
            self.session = session; self.state = state; self.detail = detail
            self.name = name; self.project = project; self.title = title
        }
    }

    public enum DecodeError: Error, Equatable {
        case badMessage
        case version(Int)
        case unknownType(String)
    }

    private struct Envelope: Decodable { let v: Int; let type: String }

    public static func decode(_ line: Data) throws(DecodeError) -> AppMessage {
        let d = JSONDecoder()
        guard let env = try? d.decode(Envelope.self, from: line) else { throw .badMessage }
        guard env.v == version else { throw .version(env.v) }
        switch env.type {
        case "say":
            guard let s = try? d.decode(Say.self, from: line) else { throw .badMessage }
            return .say(s)
        case "status":
            guard let s = try? d.decode(Status.self, from: line) else { throw .badMessage }
            return .status(s)
        default:
            throw .unknownType(env.type)
        }
    }
}

/// The app's answer to each message.
public struct AppReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var reason: String?

    public init(ok: Bool, reason: String? = nil) { self.ok = ok; self.reason = reason }

    public var encoded: Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data(#"{"ok":false}"#.utf8)
    }
}
