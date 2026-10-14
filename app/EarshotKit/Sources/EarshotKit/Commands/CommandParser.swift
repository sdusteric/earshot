import Foundation
import FoundationModels
import os

/// Understands what the grammar does not.
public protocol CommandModel: Sendable {
    var isAvailable: Bool { get async }
    /// Called when the wake word or hotkey fires, so the model is ready by the end of the command.
    func prewarm(sessions: [String]) async
    /// nil when the model failed.
    func parse(_ text: String, sessions: [String]) async -> Command?
}

public struct CommandParser: Sendable {
    let model: (any CommandModel)?
    /// How long the model may take before the command counts as not understood.
    let timeout: Duration

    public init(model: (any CommandModel)?, timeout: Duration = .seconds(2)) { self.model = model; self.timeout = timeout }

    /// `plain`: the words heard without session names boosted, when the boost
    /// changed them. They win when they already make a command, so a name that
    /// sounds like a plain word ("wedding" for "doing") doesn't take over, and
    /// the model only ever sees them, never a boost the grammar couldn't use.
    public func parse(_ text: String, plain: String? = nil, sessions: [String]) async -> Command {
        if let plain, let c = Grammar.parse(plain, known: sessions), c != .unknown { return c }
        if let c = Grammar.parse(text, known: sessions) { return c }
        guard let model else { return .unknown }
        let heard = plain ?? text
        let answer = await bounded(timeout, Command?.none) {
            guard await model.isAvailable else { return nil }
            return await model.parse(heard, sessions: sessions)
        }
        guard let c = answer else { return .unknown }
        return Self.accept(c, heard: heard)
    }

    /// Keeps a model answer only when the user's words back it up: every content word of
    /// the target and prompt must have been said (M1), and an approval needs a clear
    /// approval word in what was said, with the target's words taken out (M2): yes, allow
    /// or approve, or any yes word with a session named. Outside the window "stop" and
    /// "cancel" are the Stop command, so they never deny.
    static func accept(_ c: Command, heard text: String) -> Command {
        let said = words(text)
        switch c {
        case .send(let target, let prompt):
            return backed([target, prompt], by: said) ? c : .unknown
        case .start(let project, let prompt):
            return backed([project, prompt], by: said) ? c : .unknown
        case .status(let target):
            return backed([target], by: said) ? c : .unknown
        case .stop(let target, _):
            // "Hold on a second" is not a stop: one of the stop words must have been said.
            return backed([target], by: said) && said.contains(where: saysStop) ? c : .unknown
        case .answer(_, let target):
            guard backed([target], by: said) else { return .unknown }
            let targetWords = Set(Grammar.Words(target ?? "").keys)
            let rest = Grammar.Words(text).keys.filter { !targetWords.contains($0) }.joined(separator: " ")
            guard let approves = Grammar.plainAnswer(rest, named: target != nil) else { return .unknown }
            return .answer(allow: approves, target: target)
        case .greet, .unknown:
            return c
        }
    }

    static let stopWords = ["stop", "halt", "pause", "wait", "cancel", "interrupt", "kill", "end"]

    /// A stop word, or one of its forms ("stopping", "paused", "cancelled").
    static func saysStop(_ w: String) -> Bool {
        stopWords.contains { w == $0 || (w.hasPrefix($0) && w.count <= $0.count + 3) }
    }

    /// Words that count as said: letters and digits, lowercased.
    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Words of a model field that must be heard: 3 or more characters, not a filler word.
    static let unbackedWords: Set<String> = ["the", "and", "for", "with", "that", "this", "its", "you", "your", "please"]

    /// True when every content word of each field was said. A said word matches
    /// when it is the same, or one is a prefix of the other ("tests" and "test").
    static func backed(_ fields: [String?], by said: [String]) -> Bool {
        fields.allSatisfy { field in
            guard let field else { return true }
            return words(field).allSatisfy { w in
                w.count < 3 || unbackedWords.contains(w) || said.contains { h in
                    h.hasPrefix(w) || (h.count >= 3 && w.hasPrefix(h))
                }
            }
        }
    }

    public func prewarm(sessions: [String]) async { await model?.prewarm(sessions: sessions) }
}

@Generable
struct ParsedCommand {
    @Guide(description: "What the user asked for.", .anyOf(["send", "status", "stop", "start", "approve", "deny", "unknown"]))
    var action: String
    @Guide(description: "The session or project the user named, in their words. Empty when they named none.")
    var target: String
    @Guide(description: "For send and start: the request to pass on, in the user's own words. Empty otherwise. Never invent one.")
    var prompt: String
    @Guide(description: "For stop: true only when the user said now, right now or immediately.")
    var immediately: Bool
}

/// Apple's on-device model. A fresh session per command, made and prewarmed
/// when the wake word or hotkey fires.
public actor FoundationCommandModel: CommandModel {
    private var ready: LanguageModelSession?
    private var readyFor: [String] = []
    private let log = Logger(subsystem: "com.earshot.app", category: "parser")

    public init() {}

    public var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public func prewarm(sessions: [String]) async {
        guard SystemLanguageModel.default.isAvailable else { return }
        let s = Self.session(sessions)
        s.prewarm()
        ready = s
        readyFor = sessions
    }

    public func parse(_ text: String, sessions: [String]) async -> Command? {
        let session = (readyFor == sessions ? ready : nil) ?? Self.session(sessions)
        ready = nil
        do {
            let r = try await session.respond(to: text, generating: ParsedCommand.self)
            let p = r.content
            return Self.command(action: p.action, target: p.target, prompt: p.prompt, immediately: p.immediately)
        } catch {
            log.error("the model failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func session(_ sessions: [String]) -> LanguageModelSession {
        LanguageModelSession(instructions: """
            You read one spoken command for Earshot, a voice assistant that controls Claude Code coding sessions, \
            and say what it asks for.
            Actions: send (pass a request to a session), status (ask what a session or everyone is doing), \
            stop (stop a session), start (start a new session in a project folder), approve or deny (answer a \
            permission prompt), unknown (anything else, or when you are not sure).
            Open sessions: \(sessions.isEmpty ? "none" : sessions.joined(separator: ", ")).
            Keep the user's own words for the target and the prompt. Never invent a prompt.
            """)
    }

    /// The model's answer as a command; nil for an action that needs
    /// something the user did not say.
    static func command(action: String, target: String, prompt: String, immediately: Bool) -> Command? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = t.isEmpty ? nil : t
        switch action {
        case "send": return p.isEmpty ? .unknown : .send(target: target, prompt: p)
        case "status": return .status(target: target)
        case "stop": return .stop(target: target, now: immediately)
        case "start": return t.isEmpty ? .unknown : .start(project: t, prompt: p.isEmpty ? nil : p)
        case "approve": return .answer(allow: true, target: target)
        case "deny": return .answer(allow: false, target: target)
        default: return .unknown
        }
    }
}
