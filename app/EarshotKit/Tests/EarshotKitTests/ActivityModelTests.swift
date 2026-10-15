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

    /// A session only Claude Code says waits on you (a blocked background job) leads the recap.
    @Test func aSessionWaitingOnlyByClaudeCodesAccountIsInTheRecap() {
        let roster = ActivitySessions(known: [.init(id: "f", name: "finebrief", state: .working)],
                                      live: [.init(id: "w", name: "wedding", busy: false, waiting: true),
                                             .init(id: "f", name: "finebrief", busy: true, waiting: false)], history: [])
        #expect(roster.recap == "Wedding needs you.")
        #expect(roster.spokenRecap == "Wedding needs you. One session is working.")
        let both = ActivitySessions(known: [.init(id: "b", name: "blog", state: .needs), .init(id: "f", name: "finebrief", state: .done)],
                                    live: [.init(id: "w", name: "wedding", busy: false, waiting: true)], history: [])
        #expect(both.recap == "Blog needs you. Wedding needs you. Finebrief finished.")
    }

    @Test func whatNeedsYouComesFirstAndNoSessionIsListedTwice() {
        let known = SessionInfo(id: "blog", name: "blog", state: .done, detail: nil, updated: now, project: "blog", title: nil)
        let list = SessionInfo.panelList(known: [known], live: [live("blog", busy: true), live("wedding", waiting: true)], now: now)
        #expect(list.map(\.id) == ["wedding", "blog"])
        #expect(list.last?.state == .done)
    }

    // MARK: Geometry

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
        #expect(lines.map(\.id) == ["q", "s"])
        #expect(lines.first?.sentence == "Queue needs you.")
        #expect(roster.workingCount == 2)
        #expect(roster.spokenRecap == "Queue needs you. Search needs you. 2 sessions are working.")
    }

    @Test func theRecapSaysWhenNothingIsOpenOrNothingNeedsYou() {
        #expect(ActivitySessions(known: [], live: [], history: []).recap == "No Claude Code sessions are open.")
        let quiet = ActivitySessions(known: [.init(id: "a", name: "api", state: .open)],
                                     live: [.init(id: "b", name: "billing", busy: false, waiting: false)], history: [])
        #expect(quiet.recap == "Nothing needs you right now.")
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

    @Test func titlesCapitalizeTheFirstLetterOnly() {
        #expect(ActivitySessions.title("billing service") == "Billing service")
        #expect(ActivitySessions.title("") == "")
    }
}
