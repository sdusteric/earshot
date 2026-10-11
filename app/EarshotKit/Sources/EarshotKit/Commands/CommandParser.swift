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

    public init(model: (any CommandModel)?) { self.model = model }

    public func parse(_ text: String, sessions: [String]) async -> Command {
        if let c = Grammar.parse(text, known: sessions) { return c }
        guard let model, await model.isAvailable, let c = await model.parse(text, sessions: sessions) else { return .unknown }
        return c
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
