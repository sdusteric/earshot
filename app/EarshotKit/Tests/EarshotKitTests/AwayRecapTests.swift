import Foundation
import Testing
@testable import EarshotKit

@Suite struct AwayRecapTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func line(_ text: String, _ kind: LineKind, _ session: String, _ name: String?, at s: TimeInterval) -> SpokenLine {
        SpokenLine(text: text, kind: kind, session: session, received: at(s), name: name)
    }

    @Test func saysWhatChangedInOneLine() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Fixed the rounding bug.", .done, "b", "billing service", at: 60))
        r.note(line("Hey, blog needs your OK before it keeps going.", .need, "a", "blog", at: 120))
        let recap = r.back(at: at(15 * 60), states: [:], names: [:])
        #expect(recap?.text == "While you were away: Blog needs you. Billing service finished.")
        #expect(recap?.sessions == ["a", "b"])
        #expect(recap?.since == at(0))
    }

    @Test func nothingUnderTenMinutesAway() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Done.", .done, "a", "blog", at: 60))
        #expect(r.back(at: at(9 * 60 + 59), states: [:], names: [:]) == nil)
        // That absence is over: the next one starts fresh.
        r.left(at: at(1000))
        #expect(r.back(at: at(1000 + 10 * 60), states: [:], names: [:]) == nil)
    }

    @Test func exactlyTenMinutesCounts() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Done.", .done, "a", "blog", at: 60))
        #expect(r.back(at: at(10 * 60), states: [:], names: [:])?.text == "While you were away: Blog finished.")
    }

    @Test func nothingWhenNothingChanged() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Still on the tests, about 3 minutes in.", .beat, "a", "blog", at: 60))
        r.note(line("On it.", .ack, "a", "blog", at: 70))
        r.note(line("Two sessions.", .roll, "", nil, at: 80))
        #expect(r.back(at: at(3600), states: [:], names: [:]) == nil)
    }

    @Test func linesBeforeYouLeftDoNotCount() {
        var r = AwayRecap()
        r.note(line("Done.", .done, "a", "blog", at: 0))
        r.left(at: at(10))
        r.note(line("Earlier.", .done, "b", "docs", at: 5))
        #expect(r.back(at: at(3600), states: [:], names: [:]) == nil)
    }

    @Test func aLineThatAsksSomethingNeedsYou() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Want one more round, or ship it?", .done, "a", "blog", at: 60))
        #expect(r.back(at: at(3600), states: ["a": .done], names: [:])?.text == "While you were away: Blog needs you.")
    }

    @Test func stuckAndErrors() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Blog hit an error. Take a look when you can.", .alert, "a", "blog", at: 60))
        r.note(line("Docs keeps running the same command.", .alert, "b", "docs", at: 70))
        #expect(r.back(at: at(3600), states: ["a": .failed, "b": .stuck], names: [:])?.text
                == "While you were away: Blog hit an error. Docs might be stuck.")
    }

    @Test func theStateNowDecidesStuckOrFailed() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Something odd.", .alert, "a", "blog", at: 60))
        #expect(r.back(at: at(3600), states: ["a": .failed], names: [:])?.text == "While you were away: Blog hit an error.")
    }

    /// A session that went back to work was answered (from another device, say)
    /// or recovered: it is not news.
    @Test func aSessionBackAtWorkIsLeftOut() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Hey, blog needs your OK.", .need, "a", "blog", at: 60))
        r.note(line("Docs keeps running the same command.", .alert, "b", "docs", at: 70))
        r.note(line("Done.", .done, "c", "api", at: 80))
        #expect(r.back(at: at(3600), states: ["a": .working, "b": .working, "c": .done], names: [:])?.text
                == "While you were away: Api finished.")
    }

    @Test func theLatestChangeOfASessionWins() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Hey, blog needs your OK.", .need, "a", "blog", at: 60))
        r.note(line("Done.", .done, "a", "blog", at: 600))
        #expect(r.back(at: at(3600), states: [:], names: [:])?.text == "While you were away: Blog finished.")
    }

    @Test func sessionsWithTheSameChangeShareASentence() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Done.", .done, "a", "blog", at: 60))
        r.note(line("Done.", .done, "b", "docs", at: 70))
        r.note(line("Done.", .done, "c", "billing service", at: 80))
        r.note(line("Hey, api needs your OK.", .need, "d", "api", at: 90))
        r.note(line("Hey, web needs your input.", .need, "e", "web", at: 95))
        #expect(r.back(at: at(3600), states: [:], names: [:])?.text
                == "While you were away: Api and web need you. Blog and docs finished. And 1 more.")
    }

    @Test func theNameComesFromTheLineThenTheSessionList() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Done.", .done, "a", nil, at: 60))
        r.note(line("Done.", .done, "b", nil, at: 70))
        #expect(r.back(at: at(3600), states: [:], names: ["a": "blog"])?.text
                == "While you were away: Blog and a session finished.")
    }

    @Test func leavingTwiceKeepsTheFirstTime() {
        var r = AwayRecap()
        r.left(at: at(0))     // locked
        r.left(at: at(300))   // then asleep
        r.note(line("Done.", .done, "a", "blog", at: 100))
        #expect(r.back(at: at(11 * 60), states: [:], names: [:])?.since == at(0))
    }

    func info(_ id: String, _ name: String, _ state: SessionState, since s: TimeInterval) -> SessionInfo {
        var i = SessionInfo(id: id, name: name, state: state, detail: nil, updated: at(s), project: nil, title: nil)
        i.since = at(s)
        return i
    }

    /// A wait you dismissed in Activity is not news when you come back.
    @Test func aDismissedWaitIsNotSaid() {
        var r = AwayRecap()
        r.left(at: at(0))
        // The plugin said again that blog needs you, about the wait you dismissed.
        r.note(line("Blog still needs your OK.", .need, "a", "blog", at: 120))
        r.note(line("Fixed the rounding bug.", .done, "b", "billing service", at: 60))
        var d = Dismissals()
        d.dismiss("a", now: at(-30))
        let recap = r.back(at: at(15 * 60), sessions: [info("a", "blog", .needs, since: -60),
                                                       info("b", "billing service", .done, since: 60)], dismissals: d)
        #expect(recap?.text == "While you were away: Billing service finished.")
        #expect(recap?.sessions == ["b"])
    }

    @Test func aWaitThatBeganAfterTheDismissalIsSaid() {
        var r = AwayRecap()
        r.left(at: at(0))
        r.note(line("Hey, blog needs your OK.", .need, "a", "blog", at: 120))
        var d = Dismissals()
        d.dismiss("a", now: at(-30))
        let recap = r.back(at: at(15 * 60), sessions: [info("a", "blog", .needs, since: 120)], dismissals: d)
        #expect(recap?.text == "While you were away: Blog needs you.")
    }
}

@Suite struct BannerBookTests {
    func line(_ text: String, _ kind: LineKind, _ session: String = "a", name: String? = "blog") -> SpokenLine {
        SpokenLine(text: text, kind: kind, session: session, name: name)
    }

    @Test func onlyASessionThatNeedsYouMakesABanner() {
        var b = BannerBook()
        #expect(b.banner(for: line("Hey, blog needs your OK.", .need), name: nil)
                == Banner(session: "a", title: "Blog", body: "Hey, blog needs your OK."))
        #expect(b.banner(for: line("Hey, docs is still waiting on your answer.", .reply, "b"), name: nil) != nil)
        #expect(b.banner(for: line("Want one more round, or ship it?", .done, "c"), name: nil) != nil)
        #expect(b.banner(for: line("Fixed the rounding bug.", .done, "d"), name: nil) == nil)
        #expect(b.banner(for: line("Blog hit an error.", .alert, "e"), name: nil) == nil)
        #expect(b.banner(for: line("Still on it.", .beat, "f"), name: nil) == nil)
        #expect(b.banner(for: line("While you were away: Blog needs you?", .recap, ""), name: nil) == nil)
    }

    @Test func oneBannerPerSessionUntilItGoesBackToWork() {
        var b = BannerBook()
        #expect(b.banner(for: line("Hey, blog needs your OK.", .need), name: nil) != nil)
        // The reminders while it waits make no new banner.
        #expect(b.banner(for: line("It's been 2 minutes. Blog is still waiting on you.", .need), name: nil) == nil)
        let had = b.clear(session: "a"), hadAgain = b.clear(session: "a")
        #expect(had && !hadAgain)
        #expect(b.banner(for: line("Hey, blog needs your input.", .need), name: nil) != nil)
    }

    @Test func aLineHeldTwiceMakesOneBanner() {
        var b = BannerBook()
        let l = line("Want one more round, or ship it?", .done)
        #expect(b.banner(for: l, name: nil) != nil)
        _ = b.clear(session: "a")
        #expect(b.banner(for: l, name: nil) == nil)
    }

    @Test func theTitleIsTheSessionName() {
        var b = BannerBook()
        #expect(b.banner(for: line("Hey, it needs you.", .need, name: nil), name: "billing service")?.title == "Billing service")
        #expect(b.banner(for: line("Hey, it needs you.", .need, "b", name: nil), name: nil)?.title == "A session")
    }
}

@Suite struct BannerDelayTests {
    actor Posted {
        var banners: [Banner] = []
        func add(_ b: Banner) { banners.append(b) }
    }

    func make(_ posted: Posted) async -> Banners {
        let b = Banners(delay: .milliseconds(120))
        await b.connect(show: { await posted.add($0) }, remove: { _ in })
        return b
    }

    let line = SpokenLine(text: "Blog wants to push to main. Allow it?", kind: .need, session: "s1", name: "blog")

    @Test func aBannerWaitsThenPosts() async {
        let posted = Posted()
        let b = await make(posted)
        await b.unspoken(line, name: nil)
        #expect(await posted.banners.isEmpty)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await posted.banners.map(\.title) == ["Blog"])
    }

    @Test func aLineSaidWhileTheBannerWaitsPostsNothing() async {
        let posted = Posted()
        let b = await make(posted)
        await b.unspoken(line, name: nil)
        await b.lineSaid(line.id)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await posted.banners.isEmpty)
    }

    @Test func aSessionBackAtWorkWhileTheBannerWaitsPostsNothing() async {
        let posted = Posted()
        let b = await make(posted)
        await b.unspoken(line, name: nil)
        await b.sessionChanged("s1", to: .working)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await posted.banners.isEmpty)
    }

}
