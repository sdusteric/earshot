import CoreGraphics
import Foundation
import Testing
@testable import EarshotKit

@Suite struct ActivityModelTests {
    let now = Date(timeIntervalSince1970: 1_791_800_000)
    let minute: TimeInterval = 60
    let hour: TimeInterval = 3600

    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    // MARK: Panel sessions

    func live(_ id: String, busy: Bool = false, waiting: Bool = false) -> LiveSession {
        LiveSession(id: id, pid: 1, kind: "interactive", cwd: "/p/\(id)", project: id, title: "", label: "", name: id,
                    busy: busy, waiting: waiting, state: nil, detail: nil, since: nil)
    }

    /// Without the plugin the panel still lists what `claude agents` sees.
    @Test func thePanelListsSessionsOnlyClaudeCodeKnows() {
        let list = SessionInfo.panelList(known: [], live: [live("idle"), live("busy", busy: true), live("asks", waiting: true)],
                                         now: now)
        #expect(list.map(\.id) == ["asks", "busy", "idle"])
        #expect(list.map(\.state) == [.needs, .working, .open])
        #expect(list.allSatisfy { $0.updated == now })
    }

    @Test func thePluginsSessionsComeFirstAndAreNotListedTwice() {
        let known = SessionInfo(id: "blog", name: "blog", state: .done, detail: nil, updated: now, project: "blog", title: nil)
        let list = SessionInfo.panelList(known: [known], live: [live("blog", busy: true), live("wedding", waiting: true)], now: now)
        #expect(list.map(\.id) == ["blog", "wedding"])
        #expect(list.first?.state == .done)
    }

    // MARK: Geometry

    @Test func nowIsAtTheTopAndThePastRunsCounterclockwise() {
        let g = DialGeometry(size: 600, now: now, sessions: [])
        #expect(close(g.angle(now), -Double.pi / 2))
        #expect(close(g.angle(now.addingTimeInterval(-6 * hour)), -Double.pi))
        #expect(close(g.angle(now.addingTimeInterval(-12 * hour)), -3 * Double.pi / 2))
        #expect(close(g.point(now, radius: 100), CGPoint(x: 300, y: 200)))
        #expect(close(g.point(now.addingTimeInterval(-6 * hour), radius: 100), CGPoint(x: 200, y: 300)))
        #expect(close(g.point(now.addingTimeInterval(-12 * hour), radius: 100), CGPoint(x: 300, y: 400)))
    }

    @Test func anglesStopAtNowAndADayBack() {
        let g = DialGeometry(size: 600, now: now, sessions: [])
        #expect(close(g.angle(now.addingTimeInterval(10 * minute)), -Double.pi / 2))
        #expect(close(g.angle(now.addingTimeInterval(-30 * hour)), -Double.pi / 2 - 2 * Double.pi))
    }

    @Test func timeAtAPointUndoesPointForATime() throws {
        let g = DialGeometry(size: 600, now: now, sessions: [])
        for back in [0, 3 * hour, 6 * hour, 15 * hour, 23 * hour] {
            let t = now.addingTimeInterval(-back)
            let found = try #require(g.time(at: g.point(t, radius: 150)))
            #expect(abs(found.timeIntervalSince(t)) < 0.001)
        }
        #expect(g.time(at: g.center) == nil)
        #expect(g.time(at: CGPoint(x: 300, y: 0)) == nil)
    }

    @Test func ringsStepInwardFromYoursInTheOrderGiven() {
        let g = DialGeometry(size: 600, now: now, sessions: ["a", "b"])
        #expect(g.rings.map(\.id) == [DialGeometry.youLane, "a", "b"])
        #expect(g.rings[0].radius == g.outer)
        #expect(g.rings[1].radius == g.outer - 30)
        #expect(g.rings[2].radius == g.outer - 60)
        #expect(g.ring(for: HistoryEntry(kind: .heard, text: "hi"))?.id == DialGeometry.youLane)
        #expect(g.ring(for: HistoryEntry(kind: .said, text: "done", session: "b"))?.id == "b")
        #expect(g.ring(for: HistoryEntry(kind: .said, text: "done", session: "z")) == nil)
        #expect(g.ring(for: HistoryEntry(kind: .said, text: "done")) == nil)
    }

    // MARK: Stretches

    @Test func aGapOverHalfAnHourSplitsAStretch() {
        let t0 = now.addingTimeInterval(-5 * hour)
        let times = [0, 10, 20, 51, 61, 71].map { t0.addingTimeInterval($0 * minute) }
        let s = DialGeometry.stretches(times, active: false, now: now)
        #expect(s == [t0...t0.addingTimeInterval(20 * minute),
                      t0.addingTimeInterval(51 * minute)...t0.addingTimeInterval(71 * minute)])
    }

    @Test func aGapUnderHalfAnHourJoinsTheStretch() {
        let t0 = now.addingTimeInterval(-5 * hour)
        let times = [49, 0, 20, 59, 69, 10].map { t0.addingTimeInterval($0 * minute) }
        let s = DialGeometry.stretches(times, active: false, now: now)
        #expect(s == [t0...t0.addingTimeInterval(69 * minute)])
    }

    @Test func aStretchUnderFifteenMinutesIsNotDrawn() {
        let t0 = now.addingTimeInterval(-5 * hour)
        let times = [0, 14, 60, 75].map { t0.addingTimeInterval($0 * minute) }
        let s = DialGeometry.stretches(times, active: false, now: now)
        #expect(s == [t0.addingTimeInterval(60 * minute)...t0.addingTimeInterval(75 * minute)])
    }

    @Test func anActiveLaneRunsOnToNowOnlyAfterRecentSpeech() {
        let recent = [now.addingTimeInterval(-20 * minute), now.addingTimeInterval(-15 * minute)]
        #expect(DialGeometry.stretches(recent, active: true, now: now) == [recent[0]...now])
        #expect(DialGeometry.stretches(recent, active: false, now: now).isEmpty)

        let quiet = [now.addingTimeInterval(-45 * minute), now.addingTimeInterval(-40 * minute)]
        #expect(DialGeometry.stretches(quiet, active: true, now: now).isEmpty)
    }

    @Test func onlyTheLatestStretchRunsOn() {
        let early = now.addingTimeInterval(-3 * hour)
        let times = [early, early.addingTimeInterval(20 * minute), now.addingTimeInterval(-20 * minute)]
        let s = DialGeometry.stretches(times, active: true, now: now)
        #expect(s == [early...early.addingTimeInterval(20 * minute), now.addingTimeInterval(-20 * minute)...now])
    }

    // MARK: Dots

    @Test func linesWithinEightPointsMergeIntoTheNewest() throws {
        // On your ring at this size a minute is just under a point.
        let g = DialGeometry(size: 600, now: now, sessions: ["s1"])
        let newest = HistoryEntry(date: now.addingTimeInterval(-60 * minute), kind: .heard, text: "newest")
        let entries = [
            HistoryEntry(date: now.addingTimeInterval(-63 * minute), kind: .heard, text: "oldest"),
            newest,
            HistoryEntry(date: now.addingTimeInterval(-61 * minute), kind: .heard, text: "middle"),
            HistoryEntry(date: now.addingTimeInterval(-75 * minute), kind: .heard, text: "apart"),
            HistoryEntry(date: now.addingTimeInterval(-62 * minute), kind: .said, text: "other ring", session: "s1"),
            HistoryEntry(date: now.addingTimeInterval(-62 * minute), kind: .said, text: "no ring", session: "gone"),
        ]
        let dots = g.dots(entries)
        #expect(dots.count == 3)
        let merged = try #require(dots.first { $0.entry.id == newest.id })
        #expect(merged.count == 3)
        #expect(merged.oldest == now.addingTimeInterval(-63 * minute))
        #expect(dots.contains { $0.entry.text == "apart" && $0.count == 1 })
        #expect(dots.contains { $0.entry.text == "other ring" && $0.count == 1 })
    }

    @Test func theNearestDotIsWithinTwelvePoints() {
        let e = HistoryEntry(kind: .heard, text: "hi")
        let dots = [DialDot(entry: e, point: CGPoint(x: 100, y: 100), oldest: e.date),
                    DialDot(entry: e, point: CGPoint(x: 110, y: 100), oldest: e.date)]
        #expect(DialGeometry.nearest(dots, to: CGPoint(x: 108, y: 100))?.point == CGPoint(x: 110, y: 100))
        #expect(DialGeometry.nearest(dots, to: CGPoint(x: 100, y: 130)) == nil)
    }

    // MARK: Hour labels

    @Test func majorLabelsWithinSeventyFiveMinutesOfNowAreSkipped() throws {
        let cal = utc
        let at1230 = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12, minute: 30)))
        let ticks = DialGeometry.hourTicks(now: at1230, calendar: cal)
        #expect(ticks.count == 24)
        #expect(ticks.filter(\.major).map { cal.component(.hour, from: $0.date) } == [12, 6, 0, 18])
        #expect(ticks.filter(\.labeled).map { cal.component(.hour, from: $0.date) } == [6, 0, 18])

        let at1320 = at1230.addingTimeInterval(50 * minute)
        #expect(DialGeometry.hourTicks(now: at1320, calendar: cal).filter(\.labeled).map { cal.component(.hour, from: $0.date) } == [12, 6, 0, 18])

        // Nearly a day back, the dial comes round to just past now.
        let at1100 = at1230.addingTimeInterval(-90 * minute)
        let early = DialGeometry.hourTicks(now: at1100, calendar: cal)
        #expect(early.filter(\.major).map { cal.component(.hour, from: $0.date) } == [6, 0, 18, 12])
        #expect(early.filter(\.labeled).map { cal.component(.hour, from: $0.date) } == [6, 0, 18])
    }

    @Test func labelClearanceIsSeventyFiveMinutesEitherSide() {
        #expect(!DialGeometry.labelClearsNow(now.addingTimeInterval(-74 * minute), now: now))
        #expect(DialGeometry.labelClearsNow(now.addingTimeInterval(-76 * minute), now: now))
        #expect(DialGeometry.labelClearsNow(now.addingTimeInterval(-24 * hour + 76 * minute), now: now))
        #expect(!DialGeometry.labelClearsNow(now.addingTimeInterval(-24 * hour + 74 * minute), now: now))
    }

    // MARK: Lines that ask you

    @Test func aLineAsksYouWhenItNeedsYouOrEndsWithAQuestion() {
        #expect(HistoryEntry(kind: .said, text: "Billing needs you.", lineKind: .need).asksYou)
        #expect(HistoryEntry(kind: .said, text: "Billing is waiting.", lineKind: .reply).asksYou)
        #expect(HistoryEntry(kind: .said, text: "Want one more round, or ship it?  \n", lineKind: .done).asksYou)
        #expect(HistoryEntry(kind: .said, text: "Ready?").asksYou)
        #expect(!HistoryEntry(kind: .said, text: "Billing is done.", lineKind: .done).asksYou)
        #expect(!HistoryEntry(kind: .said, text: "Is it? No, it finished.", lineKind: .alert).asksYou)
        #expect(!HistoryEntry(kind: .heard, text: "what's billing doing?").asksYou)
    }

    // MARK: Recap and names

    @Test func theRecapPutsWhoNeedsYouFirstAndNamesThree() {
        let roster = ActivitySessions(known: [
            .init(id: "a", name: "api", state: .working),
            .init(id: "b", name: "billing", state: .done),
            .init(id: "c", name: "checkout", state: .needs),
            .init(id: "d", name: "docs", state: .stuck),
            .init(id: "e", name: "email", state: .open),
        ], live: [], history: [])
        #expect(roster.recapLines.map(\.id) == ["c", "d", "b"])
        #expect(roster.recap == "Checkout needs you. Docs might be stuck. Billing finished.")
    }

    @Test func theRecapFallsBackToClaudeCodesViewWithWaitingFirst() {
        let roster = ActivitySessions(known: [], live: [
            .init(id: "p", name: "payments", busy: true, waiting: false),
            .init(id: "q", name: "queue", busy: false, waiting: true),
            .init(id: "r", name: "reports", busy: false, waiting: false),
            .init(id: "s", name: "search", busy: false, waiting: true),
            .init(id: "t", name: "tests", busy: true, waiting: false),
        ], history: [])
        let lines = roster.recapLines
        #expect(lines.count == 3)
        #expect(Set(lines.prefix(2).map(\.id)) == ["q", "s"])
        #expect(["p", "t"].contains(lines[2].id))
        #expect(lines.first { $0.id == "q" }?.sentence == "Queue needs you.")
        #expect(lines[2].sentence.hasSuffix(" is working."))
    }

    @Test func theRecapSaysWhenNothingIsOpenOrNothingNeedsYou() {
        #expect(ActivitySessions(known: [], live: [], history: []).recap == "No Claude Code sessions are open.")
        let quiet = ActivitySessions(known: [.init(id: "a", name: "api", state: .open)],
                                     live: [.init(id: "b", name: "billing", busy: false, waiting: false)], history: [])
        #expect(quiet.recap == "Nothing needs you right now.")
    }

    @Test func ringsFollowTheRecapThenTodaysHistoryThenTheRest() {
        let history = [
            HistoryEntry(kind: .said, text: "x started", session: "x", sessionName: "xray"),
            HistoryEntry(kind: .heard, text: "what's up"),
            HistoryEntry(kind: .said, text: "a is going", session: "a", sessionName: "api"),
            HistoryEntry(kind: .said, text: "c needs you", session: "c", sessionName: "checkout"),
        ]
        let roster = ActivitySessions(known: [
            .init(id: "a", name: "api", state: .open),
            .init(id: "e", name: "email", state: .open),
            .init(id: "c", name: "checkout", state: .needs),
            .init(id: "d", name: "docs", state: .stuck),
        ], live: [], history: history)
        #expect(roster.ordered.map(\.id) == ["c", "d", "a", "x", "e"])
        #expect(roster.ordered.map(\.name) == ["checkout", "docs", "api", "xray", "email"])
    }

    @Test func eachSessionHasOneNameAndThePluginsComesFirst() {
        let history = [
            HistoryEntry(kind: .said, text: "one", session: "s1", sessionName: "old billing"),
            HistoryEntry(kind: .said, text: "two", session: "s1", sessionName: "bill"),
            HistoryEntry(kind: .said, text: "three", session: "s1"),
            HistoryEntry(kind: .said, text: "four", session: "s2", sessionName: "search"),
        ]
        let live: [ActivitySessions.Live] = [
            .init(id: "s1", name: "billing-svc", busy: true, waiting: false),
            .init(id: "s2", name: "search-svc", busy: true, waiting: false),
            .init(id: "s3", name: "tests", busy: true, waiting: false),
        ]
        let withPlugin = ActivitySessions(known: [.init(id: "s1", name: "billing", state: .needs)], live: live, history: history)
        #expect(withPlugin.displayName("s1") == "billing")
        #expect(withPlugin.recapLines.first?.sentence == "Billing needs you.")
        #expect(withPlugin.displayName("s2") == "search")
        #expect(withPlugin.displayName("s3") == "tests")
        #expect(withPlugin.displayName("s9") == "session")

        let noPlugin = ActivitySessions(known: [], live: live, history: history)
        #expect(noPlugin.displayName("s1") == "bill")
    }

    @Test func activeMeansWorkingOrWaitingByThePluginElseClaudeCode() {
        let roster = ActivitySessions(known: [
            .init(id: "w", name: "w", state: .working),
            .init(id: "n", name: "n", state: .needs),
            .init(id: "r", name: "r", state: .reply),
            .init(id: "d", name: "d", state: .done),
        ], live: [
            .init(id: "d", name: "d", busy: true, waiting: false),
            .init(id: "l", name: "l", busy: false, waiting: true),
            .init(id: "i", name: "i", busy: false, waiting: false),
        ], history: [])
        #expect(["w", "n", "r", "l"].allSatisfy(roster.isActive))
        #expect(!roster.isActive("d"))
        #expect(!roster.isActive("i"))
        #expect(!roster.isActive("gone"))
    }

    @Test func titlesCapitalizeTheFirstLetterOnly() {
        #expect(ActivitySessions.title("billing service") == "Billing service")
        #expect(ActivitySessions.title("") == "")
    }
}
