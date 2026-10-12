import Foundation
import Testing
@testable import EarshotKit

final class KeepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: HistoryStore.Keep
    init(_ v: HistoryStore.Keep) { _value = v }
    var value: HistoryStore.Keep {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite struct HistoryStoreTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString).jsonl")

    @Test func aDayIsKeptOnDiskOnlyForYouAndSurvivesARestart() async throws {
        let keep = KeepBox(.day)
        let a = HistoryStore(url: url, keep: { keep.value })
        await a.add(HistoryEntry(kind: .said, text: "Billing is done.", session: "s1", sessionName: "billing", lineKind: .done))
        let heard = HistoryEntry(kind: .heard, text: "tell billing to run the tests")
        await a.add(heard)
        await a.setReply("Sent to billing.", for: heard.id)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let b = HistoryStore(url: url, keep: { keep.value })
        let loaded = await b.entries
        #expect(loaded.map(\.text) == ["Billing is done.", "tell billing to run the tests"])
        #expect(loaded.last?.reply == "Sent to billing.")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func entriesOlderThanADayAreDropped() async {
        let now = Date()
        let old = HistoryEntry(date: now.addingTimeInterval(-HistoryStore.maxAge - 60), kind: .said, text: "old")
        let s = HistoryStore(url: url, keep: { .day }, now: { now })
        await s.add(old)
        await s.add(HistoryEntry(date: now, kind: .said, text: "new"))
        #expect(await s.entries.map(\.text) == ["new"])
        try? FileManager.default.removeItem(at: url)
    }

    @Test func untilQuitWritesNothingAndOffKeepsNothing() async {
        let keep = KeepBox(.session)
        let s = HistoryStore(url: url, keep: { keep.value })
        await s.add(HistoryEntry(kind: .said, text: "one"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await s.entries.count == 1)
        keep.value = .off
        await s.settingChanged()
        #expect(await s.entries.isEmpty)
        await s.add(HistoryEntry(kind: .said, text: "two"))
        #expect(await s.entries.isEmpty)
    }

    @Test func turningOffDeletesTheFile() async {
        let keep = KeepBox(.day)
        let s = HistoryStore(url: url, keep: { keep.value })
        await s.add(HistoryEntry(kind: .said, text: "one"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        keep.value = .off
        await s.settingChanged()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func clearRemovesEverything() async {
        let s = HistoryStore(url: url, keep: { .day })
        await s.add(HistoryEntry(kind: .said, text: "one"))
        await s.clear()
        #expect(await s.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
