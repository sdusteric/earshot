import Darwin
import Foundation
import Synchronization

public struct OpenApproval: Sendable, Equatable, Identifiable {
    public let session: String
    public let id: String
    /// The session as Kobi says it: "billing service".
    public let name: String
    /// What it asks for: "to run the migration".
    public let what: String
    public let answerPath: String
    let secret: String
    public let pid: Int32?
    public let opened: Date

    /// For the Allow and Deny row: "Billing service wants to run the migration".
    public var line: String {
        let who = name.prefix(1).uppercased() + name.dropFirst()
        return what.isEmpty ? "\(who) wants your OK" : "\(who) wants \(what)"
    }
}

/// Permission prompts the plugin's decide hook waits on. The app answers one
/// by writing "allow <secret>" or "deny <secret>" to its answer file.
public actor ApprovalBook {
    public enum AnswerResult: Sendable, Equatable {
        case written
        /// The prompt ended before the answer (a click, Esc, a timeout).
        case closed
        case failed
    }

    /// speak.sh's STATE: $(getconf DARWIN_USER_TEMP_DIR)kobi
    public static var defaultStateDir: String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let base = n > 1 ? String(decoding: buf[..<(n - 1)].map { UInt8(bitPattern: $0) }, as: UTF8.self) : NSTemporaryDirectory()
        return (base.hasSuffix("/") ? base : base + "/") + "kobi"
    }

    public static let processRuns: @Sendable (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }

    private var open: [String: OpenApproval] = [:]
    /// Recently closed ids: an open message that arrives after its close is refused.
    private var closed: [String] = []
    private let stateDir: String
    private let isAlive: @Sendable (Int32) -> Bool
    private let clock: @Sendable () -> Date
    private var conts: [UUID: AsyncStream<[OpenApproval]>.Continuation] = [:]

    public init(stateDir: String = ApprovalBook.defaultStateDir,
                isAlive: @escaping @Sendable (Int32) -> Bool = ApprovalBook.processRuns,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.stateDir = (stateDir as NSString).standardizingPath
        self.isAlive = isAlive
        self.clock = clock
    }

    /// Applies an open or closed message. Returns false when an open message
    /// was refused: bad names or secret, an answer path that is not this
    /// prompt's file in the state folder, or a prompt that already closed.
    @discardableResult
    public func apply(_ a: AppMessage.Approval) -> Bool {
        if a.isClosed {
            open[a.id] = nil
            closed.append(a.id)
            if closed.count > 64 { closed.removeFirst(closed.count - 64) }
            publish()
            return true
        }
        guard !closed.contains(a.id), Self.safe(a.session), Self.safe(a.id),
              let secret = a.secret, secret.count == 32, secret.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let answer = a.answer, answer == "\(stateDir)/answer-\(a.session)-\(a.id)"
        else { return false }
        open[a.id] = OpenApproval(session: a.session, id: a.id, name: a.name ?? "a session", what: a.what ?? "",
                                  answerPath: answer, secret: secret, pid: a.pid, opened: clock())
        publish()
        return true
    }

    /// Open prompts, oldest first. A prompt whose hook is gone is dropped.
    public var current: [OpenApproval] {
        pruneDead()
        return open.values.sorted { $0.opened < $1.opened }
    }

    public func latest(session: String) -> OpenApproval? {
        current.last { $0.session == session }
    }

    public func isOpen(_ id: String) -> Bool { current.contains { $0.id == id } }

    /// Writes the answer, once. The file is written next to its final path
    /// and renamed over it, so the hook never reads half a file, and a link
    /// at the path is replaced, not followed.
    public func answer(_ id: String, allow: Bool) -> AnswerResult {
        pruneDead()
        guard let a = open.removeValue(forKey: id) else { return .closed }
        publish()
        let tmp = "\(stateDir)/.answer-\(a.id)-\(UUID().uuidString)"
        let fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed }
        let text = Array("\(allow ? "allow" : "deny") \(a.secret)\n".utf8)
        let written = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == text.count, rename(tmp, a.answerPath) == 0 else {
            unlink(tmp)
            return .failed
        }
        return .written
    }

    public func changes() -> AsyncStream<[OpenApproval]> {
        let (stream, cont) = AsyncStream<[OpenApproval]>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(current)
        cont.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }

    private func remove(_ id: UUID) { conts[id] = nil }

    private func publish() {
        let list = open.values.sorted { $0.opened < $1.opened }
        conts.values.forEach { $0.yield(list) }
    }

    private func pruneDead() {
        let dead = open.values.filter { a in a.pid.map { !isAlive($0) } ?? false }.map(\.id)
        guard !dead.isEmpty else { return }
        dead.forEach { open[$0] = nil }
        publish()
    }

    static func safe(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Whether the app can listen right now: mic permission granted, the models
/// on this Mac, and listening not switched off. The app sets it; the voice
/// loop reads it before it opens a follow-up window for a permission prompt.
public final class ListenAvailability: Sendable {
    private let value = Mutex(false)
    public init() {}
    public var canListen: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
