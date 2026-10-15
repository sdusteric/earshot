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
    /// How long the model may take before the command counts as not understood. It
    /// usually answers in about a second; a slow answer still beats "I didn't get that".
    let timeout: Duration

    public init(model: (any CommandModel)?, timeout: Duration = .seconds(3)) { self.model = model; self.timeout = timeout }

    /// `plain`: the words heard without session names boosted, when the boost
    /// changed them. They win when they already make a command, so a name that
    /// sounds like a plain word ("wedding" for "doing") doesn't take over, and
    /// the model only ever sees them, never a boost the grammar couldn't use.
    /// What the grammar misses goes to the tolerant reading (Tolerant), on the
    /// plain words, before the model: it is quick, and what it finds is read-only
    /// or asked about first. `gated`: the mic's noise gate likely cut the start.
    /// `second`: the same clip as a second recognizer heard it, tried by the
    /// grammar and the tolerant reading when the first words make nothing.
    public func parse(_ text: String, plain: String? = nil, second: String? = nil, sessions: [String],
                      gated: Bool = false) async -> Command {
        if let plain, let c = Grammar.parse(plain, known: sessions), c != .unknown { return c }
        if let c = Grammar.parse(text, known: sessions), c != .unknown || second == nil { return c }
        if let c = Tolerant.parse(plain ?? text, known: sessions, gated: gated) { return c }
        if let second, !second.isEmpty {
            if let c = Grammar.parse(second, known: sessions), c != .unknown { return c }
            if let c = Tolerant.parse(second, known: sessions, gated: gated) { return c }
            if Grammar.parse(text, known: sessions) == .unknown { return .unknown }
        }
        guard let model else { return .unknown }
        let heard = plain ?? text
        let answer = await bounded(timeout, Command?.none) {
            guard await model.isAvailable else { return nil }
            return await model.parse(heard, sessions: sessions)
        }
        guard let c = answer else { return .unknown }
        return Self.accept(c, heard: heard, sessions: sessions)
    }

    /// Keeps a model answer only when the user's words back it up: every content word of
    /// the target and prompt must have been said (M1), and an approval needs a clear
    /// approval word in what was said, with the target's words taken out (M2): yes, allow
    /// or approve, or any yes word with a session named. Outside the window "stop" and
    /// "cancel" are the Stop command, so they never deny.
    ///
    /// The model names a session in full ("billing service") when you said part of it
    /// ("billing"): a target that is an open session counts as said when a word of its
    /// name was. A prompt the model reworded is replaced by your own words, and a start
    /// keeps its project without a prompt you never said. A stop is right away only when
    /// you said so.
    static func accept(_ c: Command, heard text: String, sessions: [String] = []) -> Command {
        let said = words(text)
        func target(_ t: String?) -> String?? {
            guard let t = clean(t) else { return .some(nil) }
            return backedTarget(t, by: said, sessions: sessions) ? .some(t) : .none
        }
        switch c {
        case .send(let t, let prompt):
            guard let named = target(t) else {
                // A session you never said. When you named none at all, it is dropped and your
                // words go to the session Earshot last spoke about; when you named another, nothing goes.
                guard !namesASession(said, sessions: sessions), backed([prompt], by: said) else { return .unknown }
                return .send(target: nil, prompt: prompt)
            }
            guard let t = named else { return backed([prompt], by: said) ? c : .unknown }
            if backed([prompt], by: said) { return c }
            // Reworded, but mostly your words: they go instead. Made up: nothing goes.
            return mostlySaid(prompt, by: said) ? .send(target: t, prompt: text) : .unknown
        case .start(let project, let prompt):
            guard let p = target(project), let project = p else { return .unknown }
            return .start(project: project, prompt: prompt.flatMap { backed([$0], by: said) ? $0 : nil })
        case .status(let t):
            // A session you never named, in a question: ask about everyone. It only reads.
            let t = target(t) ?? nil
            // "Everyone up to?": everyone is the roll call, not a session.
            if let t, Grammar.allSessions.contains(Grammar.Words(t).key)
                || Grammar.everyoneWords.contains(Grammar.Words(t).key) { return .status(target: nil) }
            return .status(target: t)
        case .stop(let t, let now):
            // "Hold on a second" is not a stop: one of the stop words must have been said.
            guard let t = target(t), said.contains(where: saysStop) else { return .unknown }
            // With no session named, only Earshot stops talking (see Grammar.quietWords).
            guard let t else { return .quiet }
            if Grammar.everyoneWords.contains(Grammar.Words(t).key) { return .stopAll }
            // "Tell billing to stop logging so much" asks it to stop doing one thing: a prompt.
            if !saysNow(text), stopsOneThing(said, named: words(t) + sessions.flatMap(words)) { return .send(target: t, prompt: text) }
            return .stop(target: t, now: now && saysNow(text))
        case .answer(_, let t):
            guard let t = target(t) else { return .unknown }
            // The target's words, and the session's whole name, are not part of the answer.
            var named = Set(Grammar.Words(t ?? "").keys)
            if let t, let s = sessions.first(where: { NameMatch.score(t, $0) >= 0.78 }) { named.formUnion(Grammar.Words(s).keys) }
            var rest = Grammar.Words(text).keys.filter { !named.contains($0) }
            // "Tell billing no": the answer is what is told.
            if rest.first == "tell" { rest.removeFirst() }
            guard let approves = Grammar.plainAnswer(rest.joined(separator: " "), named: t != nil) else { return .unknown }
            return .answer(allow: approves, target: t)
        case .greet, .stopAll, .quiet, .repeatLast, .unknown, .confirmSend:
            return c
        }
    }

    /// A model target with nothing in it: empty, or a placeholder it wrote for none.
    static func clean(_ t: String?) -> String? {
        guard let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !["unknown", "none", "nil", "null", "n/a"].contains(t.lowercased()) else { return nil }
        return t
    }

    /// The target was said, or it is an open session one of whose name words was said.
    static func backedTarget(_ t: String, by said: [String], sessions: [String]) -> Bool {
        // A name's words said whole: "fine" is not "finebrief".
        let whole = words(t).allSatisfy { w in
            w.count < 3 || unbackedWords.contains(w) || said.contains { $0 == w || $0 == w + "s" || $0 + "s" == w }
        }
        if whole { return true }
        // "Billing" for "billing service": the name's first word, said whole ("refunds" counts, "fine" does not).
        guard let s = sessions.first(where: { NameMatch.score(t, $0) >= 0.78 }),
              let lead = words(s).first(where: { $0.count >= 3 && !unbackedWords.contains($0) }) else { return false }
        return said.contains { $0 == lead || $0 == lead + "s" }
    }

    /// Words after a stop that still mean the whole session: "stop what it's doing", "stop now".
    static let stopsWholly: Set<String> = ["now", "right", "away", "immediately", "at", "once", "please", "it", "that",
                                           "working", "what", "it's", "its", "doing", "everything", "all", "there",
                                           "the", "session", "for", "today", "thanks", "s", "is", "are", "you",
                                           "you're", "your", "they", "they're", "on", "in", "current", "task", "work",
                                           "job", "one", "this", "up", "down", "off", "me", "us"]

    /// After the stop word comes something to stop doing ("stop logging so much"),
    /// not just the session (`named`) or words for all it does ("what it's doing").
    static func stopsOneThing(_ said: [String], named: [String] = []) -> Bool {
        guard let i = said.firstIndex(where: saysStop) else { return false }
        // The word right after the stop decides: a thing to stop doing ("logging", "the
        // deploy"), or the session itself and words for all it does ("billing", "what it's doing").
        var rest = said[(i + 1)...].drop { $0 == "please" }
        func isName(_ w: String) -> Bool {
            named.contains { n in n.count >= 3 && (w == n || w == n + "s" || w.hasPrefix(n) && w.count <= n.count + 2) }
        }
        if let f = rest.first, ["the", "a", "an", "this", "that"].contains(f), rest.count > 1 { rest = rest.dropFirst() }
        guard let w = rest.first else { return false }
        return !isName(w) && !stopsWholly.contains(w)
    }

    /// A word of some open session's name was said.
    static func namesASession(_ said: [String], sessions: [String]) -> Bool {
        sessions.contains { s in
            words(s).contains { w in w.count >= 3 && !unbackedWords.contains(w) && said.contains { $0.hasPrefix(w) } }
        }
    }

    /// At least half the prompt's content words were said.
    static func mostlySaid(_ prompt: String, by said: [String]) -> Bool {
        let content = words(prompt).filter { $0.count >= 3 && !unbackedWords.contains($0) }
        guard !content.isEmpty else { return false }
        let heard = content.filter { w in said.contains { h in h.hasPrefix(w) || (h.count >= 3 && w.hasPrefix(h)) } }
        return heard.count * 2 >= content.count
    }

    /// "Now", "right away", "immediately" or "at once" was said.
    static func saysNow(_ text: String) -> Bool {
        let k = " " + words(text).joined(separator: " ") + " "
        return [" now ", " immediately ", " right away ", " at once "].contains { k.contains($0) }
    }

    static let stopWords = ["stop", "halt", "pause", "wait", "cancel", "interrupt", "kill", "end", "shut", "quit"]

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
            // Greedy: the same words always get the same answer.
            let r = try await session.respond(to: text, generating: ParsedCommand.self,
                                              options: GenerationOptions(sampling: .greedy))
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
            Open sessions: \(sessions.isEmpty ? "none" : sessions.joined(separator: ", ")).
            Pick one action:
            - send: the user wants a session to do something, or to be told something. This includes asking whether \
            a session can do something, saying what a session should do, and saying to continue.
            - status: the user asks how a session or everyone is doing, what a session did or is doing, whether it \
            finished, or what is waiting on them.
            - stop: the user wants a whole session to stop working. Asking a session to stop doing one thing, such \
            as printing too much, is send.
            - start: the user wants a new Claude Code session opened in a project folder.
            - approve or deny: the user answers a permission prompt. Yes, sure, okay, go ahead, let it, allow: \
            approve. No, nope, not, don't, deny: deny.
            - unknown: anything not about these coding sessions, such as reminders, music, weather, timers, calls, \
            messages or general questions, or when you are not sure.
            Target: the session or project the user named, written as the open session it means. When the user \
            did not say a session's name, leave the target empty: never pick one for them.
            Prompt: for send and start, the request in the user's own words. Never invent one.
            Set immediately only when the user said now, right now, immediately or at once.
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
