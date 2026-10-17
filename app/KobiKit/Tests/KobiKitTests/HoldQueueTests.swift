import Foundation
import Testing
@testable import KobiKit

@Suite struct HoldQueueTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func line(_ text: String, _ kind: LineKind, _ session: String = "s1", at s: TimeInterval = 0) -> SpokenLine {
        SpokenLine(text: text, kind: kind, session: session, received: t0.addingTimeInterval(s))
    }
    func texts(_ lines: [SpokenLine]) -> [String] { lines.map { $0.text } }

    @Test func needsFirstThenAlertsThenFinished() {
        var q = HoldQueue()
        q.hold(line("done a", .done, "a", at: 0))
        q.hold(line("stuck b", .alert, "b", at: 1))
        q.hold(line("needs c", .need, "c", at: 2))
        #expect(texts(q.takeCatchUp(now: t0.addingTimeInterval(10)) { _ in false }) == ["needs c", "stuck b", "done a"])
        #expect(q.isEmpty)
    }

    @Test func firstNeedAndNewestOfOthersPerSession() {
        var q = HoldQueue()
        q.hold(line("needs OK to migrate", .need, at: 0))
        q.hold(line("still waiting", .need, at: 1))
        q.hold(line("done one", .done, at: 2))
        q.hold(line("done two", .done, at: 3))
        #expect(texts(q.takeCatchUp(now: t0.addingTimeInterval(5)) { _ in false }) == ["needs OK to migrate", "done two"])
    }

    @Test func introWhenTheOldestIsThirtySecondsOld() {
        var q = HoldQueue()
        q.hold(line("done", .done, at: 0))
        let out = q.takeCatchUp(now: t0.addingTimeInterval(30)) { _ in false }
        #expect(texts(out) == ["While you were on the mic:", "done"])
        #expect(out.first?.kind == .intro)
    }

    @Test func atMostFourThenAndMore() {
        var q = HoldQueue()
        for i in 0..<6 { q.hold(line("done \(i)", .done, "s\(i)", at: Double(i))) }
        #expect(texts(q.takeCatchUp(now: t0.addingTimeInterval(10)) { _ in false })
            == ["done 0", "done 1", "done 2", "done 3", "And 2 more."])
    }

    @Test func answeredNeedsAreSkipped() {
        var q = HoldQueue()
        q.hold(line("needs you", .need, at: 0))
        q.hold(line("done", .done, at: 1))
        #expect(texts(q.takeCatchUp(now: t0.addingTimeInterval(5)) { $0.kind == .need }) == ["done"])
    }

    @Test func progressAndAcksAreNotHeld() {
        var q = HoldQueue()
        q.hold(line("still on it", .beat))
        q.hold(line("On it.", .ack))
        #expect(q.isEmpty)
    }

    @Test func oldLinesAreDropped() {
        var q = HoldQueue()
        q.hold(line("ancient", .done, at: 0))
        #expect(q.takeCatchUp(now: t0.addingTimeInterval(HoldQueue.maxAge + 1)) { _ in false }.isEmpty)
    }

    @Test func dropAnsweredRemovesNeedsAndRepliesOfThatSession() {
        var q = HoldQueue()
        q.hold(line("needs", .need, "a"))
        q.hold(line("question", .reply, "a"))
        q.hold(line("done", .done, "a"))
        q.hold(line("needs b", .need, "b"))
        q.dropAnswered(session: "a")
        #expect(q.count == 2)
    }

    @Test func aRecapDropsTheHeldLinesItCovers() {
        var q = HoldQueue()
        q.hold(line("done a before you left", .done, "a", at: 0))
        q.hold(line("done a", .done, "a", at: 100))
        q.hold(line("needs a", .need, "a", at: 110))
        q.hold(line("done b", .done, "b", at: 120))
        q.dropCovered(sessions: ["a"], since: t0.addingTimeInterval(50))
        #expect(texts(q.takeCatchUp(now: t0.addingTimeInterval(125)) { _ in false })
                == ["While you were on the mic:", "done a before you left", "done b"])
    }

    /// The recap has its own opening, so it goes first and the intro and the
    /// limit of four count only the other lines.
    @Test func aHeldRecapComesFirst() {
        var q = HoldQueue()
        q.hold(line("done b", .done, "b", at: 0))
        q.hold(line("While you were away: Blog finished.", .recap, "", at: 5))
        let out = q.takeCatchUp(now: t0.addingTimeInterval(40)) { _ in false }
        #expect(texts(out) == ["While you were away: Blog finished.", "While you were on the mic:", "done b"])
        q.hold(line("While you were away: Docs finished.", .recap, "", at: 100))
        #expect(texts(q.takeCatchUp(now: t0.addingTimeInterval(140)) { _ in false }) == ["While you were away: Docs finished."])
    }

    @Test func transcriptNewerThanTheLineMeansAnswered() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ek-tr-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        let old = SpokenLine(text: "n", kind: .need, session: "s", transcript: url.path, received: Date().addingTimeInterval(-60))
        let fresh = SpokenLine(text: "n", kind: .need, session: "s", transcript: url.path, received: Date().addingTimeInterval(60))
        #expect(SpokenLine.transcriptAnswered(old))
        #expect(!SpokenLine.transcriptAnswered(fresh))
        #expect(!SpokenLine.transcriptAnswered(SpokenLine(text: "n", kind: .need, session: "s")))
    }
}
