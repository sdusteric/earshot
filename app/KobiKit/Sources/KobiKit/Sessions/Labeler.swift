import Darwin
import Foundation
import FoundationModels

public protocol LabelModel: Sendable {
    /// A 1 to 3 word noun phrase for a session title, or nil.
    func label(for title: String) async -> String?
}

@Generable
struct ShortLabel {
    @Guide(description: "A 1 to 3 word noun phrase that names the work, to say out loud. No verbs at the start, no punctuation.")
    var label: String
}

public struct FoundationLabelModel: LabelModel {
    public init() {}
    public func label(for title: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let s = LanguageModelSession(instructions: """
            You name coding sessions so a voice assistant can say them often. Turn the session title into a 1 to 3 \
            word noun phrase. Example: "Orchestrator agent for multi-session voice control" becomes "voice orchestrator".
            """)
        return try? await s.respond(to: title, generating: ShortLabel.self).content.label
    }
}

/// Labels for session titles, cached by session and title. A label the
/// model made is written to the plugin's live file as line 3, so the
/// plugin's alerts use it too.
///
/// A label is one more way to find a session by voice; a session's name does
/// not depend on it (see SpokenNames.names). So `label` never waits on the
/// model: it answers with the rule label at once, and asks the model in the
/// background, once per session and title, one title at a time. The model's
/// label is used from the next refresh on.
public actor Labeler {
    private let model: (any LabelModel)?
    private let liveDir: String
    /// How long the model may take before the rule label is kept.
    private let timeout: Duration
    private var cache: [String: String] = [:]
    /// Titles waiting for the model, oldest first.
    private var queue: [(session: String, title: String)] = []
    private var asked = Set<String>()
    private var worker: Task<Void, Never>?

    public init(model: (any LabelModel)?, liveDir: String = ApprovalBook.defaultStateDir + "/live",
                timeout: Duration = .seconds(3)) {
        self.model = model
        self.liveDir = liveDir
        self.timeout = timeout
    }

    static func key(_ session: String, _ title: String) -> String { session + "\u{1f}" + title }

    public func label(session: String, title: String) -> String {
        let key = Self.key(session, title)
        if let l = cache[key] { return l }
        let rule = SpokenNames.ruleLabel(title)
        // Short means what the plugin would say in 3 words or fewer, so both name it the same way.
        let plain = SpokenNames.plain(title).split(separator: " ").joined(separator: " ")
        guard rule != plain, model != nil else {
            cache[key] = rule
            return rule
        }
        if asked.insert(key).inserted {
            queue.append((session, title))
            if worker == nil { worker = Task { await self.work() } }
        }
        return rule
    }

    /// Waits until the model has answered every title asked so far.
    public func settle() async {
        while let w = worker { await w.value }
    }

    /// Forgets the labels of sessions that closed, so the cache stays small.
    public func keep(_ sessions: Set<String>) {
        let alive: (String) -> Bool = { k in sessions.contains(String(k.prefix { $0 != "\u{1f}" })) }
        cache = cache.filter { alive($0.key) }
        asked = asked.filter(alive)
        queue.removeAll { !sessions.contains($0.session) }
    }

    private func work() async {
        while !queue.isEmpty {
            let (session, title) = queue.removeFirst()
            await ask(session: session, title: title)
        }
        worker = nil
    }

    private func ask(session: String, title: String) async {
        guard let model else { return }
        let key = Self.key(session, title)
        var label = SpokenNames.ruleLabel(title)
        if let m = await bounded(timeout, String?.none, { await model.label(for: title) }), Self.usable(m) {
            label = m.trimmingCharacters(in: .whitespacesAndNewlines)
            writeLiveLabel(session: session, title: title, label: label)
        }
        // The session may have closed while the model thought.
        if asked.contains(key) { cache[key] = label }
    }

    static func usable(_ s: String) -> Bool {
        let w = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        return (1...3).contains(w.count) && w.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" } }
    }

    static func firstTwo(_ text: String) -> [String] {
        Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).map(String.init))
    }

    /// The new live file for these lines, or nil when line 2 is not the title (the plugin has moved on).
    static func liveContent(_ text: String, title: String, label: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, lines[1] == title else { return nil }
        return "\(lines[0])\n\(title)\n\(label)\n"
    }

    /// The plugin's live file, read only when it is a regular file this user owns.
    private static func readLiveFile(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Only into a file the plugin made, while its title (line 2) is this one. The temp file
    /// has a dot prefix, so the plugin's glob over the folder never sees it.
    private func writeLiveLabel(session: String, title: String, label: String) {
        guard ApprovalBook.safe(session) else { return }
        let path = "\(liveDir)/\(session)"
        guard let text = Self.readLiveFile(path), let content = Self.liveContent(text, title: title, label: label) else { return }
        let tmp = "\(liveDir)/.\(session).app-\(UUID().uuidString.prefix(6))"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let bytes = Array(content.utf8)
        let wrote = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
        close(fd)
        // The plugin can still rewrite the file between this check and the rename; that window is one line.
        guard wrote, let again = Self.readLiveFile(path), Self.firstTwo(again) == Self.firstTwo(text),
              rename(tmp, path) == 0 else {
            unlink(tmp)
            return
        }
    }
}
