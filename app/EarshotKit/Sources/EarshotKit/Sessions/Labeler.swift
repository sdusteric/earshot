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
public actor Labeler {
    private let model: (any LabelModel)?
    private let liveDir: String
    private var cache: [String: String] = [:]

    public init(model: (any LabelModel)?, liveDir: String = ApprovalBook.defaultStateDir + "/live") {
        self.model = model
        self.liveDir = liveDir
    }

    public func label(session: String, title: String) async -> String {
        let key = session + "\u{1f}" + title
        if let l = cache[key] { return l }
        let words = title.split(separator: " ")
        var label: String
        if words.count <= 3 {
            label = title
        } else if let m = await model?.label(for: title), Self.usable(m) {
            label = m.trimmingCharacters(in: .whitespacesAndNewlines)
            writeLiveLabel(session: session, title: title, label: label)
        } else {
            label = SpokenNames.ruleLabel(title)
        }
        cache[key] = label
        return label
    }

    static func usable(_ s: String) -> Bool {
        let w = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        return (1...3).contains(w.count) && w.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" } }
    }

    /// Only into a file the plugin made, while its title (line 2) is this one.
    private func writeLiveLabel(session: String, title: String, label: String) {
        guard ApprovalBook.safe(session) else { return }
        let path = "\(liveDir)/\(session)"
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, lines[1] == title else { return }
        let tmp = "\(path).app-\(UUID().uuidString.prefix(6))"
        guard (try? "\(lines[0])\n\(title)\n\(label)\n".write(toFile: tmp, atomically: false, encoding: .utf8)) != nil else { return }
        chmod(tmp, 0o600)
        if rename(tmp, path) != 0 { unlink(tmp) }
    }
}
