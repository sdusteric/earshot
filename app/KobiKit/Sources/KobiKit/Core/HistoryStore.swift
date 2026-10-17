import Foundation
import os

/// One thing Kobi said, or one thing you said to it and what happened.
public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A line Kobi said about a session.
        case said
        /// A command or answer you gave, with Kobi's reply.
        case heard
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    /// What Kobi said, or what you said.
    public let text: String
    /// For `heard`: what Kobi answered ("Sent to billing.").
    public var reply: String?
    /// The session it was about, when there is one.
    public var session: String?
    public var sessionName: String?
    /// For `said`: the kind of line (needs you, finished, ...).
    public var lineKind: LineKind?

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String, reply: String? = nil,
                session: String? = nil, sessionName: String? = nil, lineKind: LineKind? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.text = text; self.reply = reply
        self.session = session; self.sessionName = sessionName; self.lineKind = lineKind
    }
}

/// What Kobi said and heard, newest last. Kept for a day in a file only you
/// can read (`day`), in memory until quit (`session`), or not at all (`off`).
/// Audio is never kept, only text. Never part of diagnostics or the event log.
public actor HistoryStore {
    public enum Keep: String, Sendable, CaseIterable { case day, session, off }

    public static let maxAge: TimeInterval = 24 * 3600
    static let maxEntries = 2000

    private let url: URL
    private let keep: @Sendable () -> Keep
    private let now: @Sendable () -> Date
    private var items: [HistoryEntry] = []
    private var loaded = false
    private var lastKeep: Keep?
    private var conts: [UUID: AsyncStream<[HistoryEntry]>.Continuation] = [:]
    private let log = Logger(subsystem: "com.kobi.app", category: "history")

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Kobi/history.jsonl")
    }

    public init(url: URL = HistoryStore.defaultURL, keep: @escaping @Sendable () -> Keep,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url; self.keep = keep; self.now = now
    }

    public var entries: [HistoryEntry] {
        loadIfNeeded()
        applyKeep()
        return items
    }

    /// The whole list after every change.
    public func changes() -> AsyncStream<[HistoryEntry]> {
        let (stream, cont) = AsyncStream<[HistoryEntry]>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(entries)
        cont.onTermination = { [weak self] _ in Task { await self?.removeCont(id) } }
        return stream
    }
    private func removeCont(_ id: UUID) { conts[id] = nil }

    public func add(_ e: HistoryEntry) {
        loadIfNeeded()
        applyKeep()
        guard keep() != .off else { return }
        items.append(e)
        let trimmed = trim()
        if keep() == .day {
            if trimmed { rewrite() } else { append(e) }
        }
        publish()
    }

    /// Adds Kobi's reply to the latest entry for what you said.
    public func setReply(_ reply: String, for id: UUID) {
        guard let i = items.lastIndex(where: { $0.id == id }) else { return }
        items[i].reply = reply
        if keep() == .day { rewrite() }
        publish()
    }

    public func setSession(_ session: String, name: String?, for id: UUID) {
        guard let i = items.lastIndex(where: { $0.id == id }) else { return }
        items[i].session = session
        items[i].sessionName = name
        if keep() == .day { rewrite() }
        publish()
    }

    public func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: url)
        publish()
    }

    /// The setting may have changed: off forgets everything, session removes the file.
    public func settingChanged() {
        loadIfNeeded()
        applyKeep()
        publish()
    }

    // MARK: -

    private func applyKeep() {
        let k = keep()
        guard k != lastKeep else { return }
        lastKeep = k
        switch k {
        case .off:
            items.removeAll()
            try? FileManager.default.removeItem(at: url)
        case .session:
            try? FileManager.default.removeItem(at: url)
        case .day:
            rewrite()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard keep() == .day, let data = try? Data(contentsOf: url) else { return }
        let d = JSONDecoder()
        items = data.split(separator: UInt8(ascii: "\n")).compactMap { try? d.decode(HistoryEntry.self, from: Data($0)) }
        if trim() { rewrite() }
    }

    /// Drops entries older than a day and past the cap. True when it dropped any.
    private func trim() -> Bool {
        let before = items.count
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        items.removeAll { $0.date < cutoff }
        if items.count > Self.maxEntries { items.removeFirst(items.count - Self.maxEntries) }
        return items.count != before
    }

    private func encoded(_ e: HistoryEntry) -> Data? {
        guard var d = try? JSONEncoder().encode(e) else { return nil }
        d.append(UInt8(ascii: "\n"))
        return d
    }

    private func ensureFile() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    private func append(_ e: HistoryEntry) {
        guard let d = encoded(e), ensureFile(), let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: d)
    }

    private func rewrite() {
        var all = Data()
        for e in items { if let d = encoded(e) { all.append(d) } }
        let tmp = url.appendingPathExtension("tmp")
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: tmp.path, contents: all, attributes: [.posixPermissions: 0o600]) else {
            log.error("couldn't save the history")
            return
        }
        _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: tmp, to: url) }
    }

    private func publish() { conts.values.forEach { $0.yield(items) } }
}
