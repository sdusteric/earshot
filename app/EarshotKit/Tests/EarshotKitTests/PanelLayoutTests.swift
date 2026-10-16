import Foundation
import Testing
@testable import EarshotKit

@Suite struct PanelLayoutTests {
    let now = Date(timeIntervalSince1970: 1_791_800_000)

    func session(_ id: String, _ state: SessionState) -> SessionInfo {
        SessionInfo(id: id, name: id, state: state, detail: nil, updated: now, project: id, title: nil)
    }

    func approval(_ id: String, session: String, what: String = "to run the migration") -> OpenApproval {
        OpenApproval(session: session, id: id, name: session, what: what, answerPath: "/x/answer-\(session)-\(id)",
                     secret: String(repeating: "a", count: 32), pid: nil, opened: now)
    }

    // MARK: Panel layout

    @Test func whatWaitsOnYouComesFirstAndIsNotListedTwice() {
        let ranked = [session("blog", .needs), session("wedding", .reply), session("billing", .working), session("notes", .done)]
        let layout = PanelLayout(ranked: ranked, approvals: [approval("1", session: "blog")], maxWaiting: 3, maxSessions: 5)
        #expect(layout.approvals.map(\.id) == ["1"])
        // Blog has a permission prompt, so it gets no question card of its own.
        #expect(layout.questions.map(\.id) == ["wedding"])
        #expect(layout.sessions.map(\.id) == ["billing", "notes"])
        #expect(layout.moreWaiting == 0 && layout.moreSessions == 0)
        #expect(layout.isWaiting)
    }

    @Test func atMostFiveSessionsShowUnderTheWaitingCards() {
        let ranked = (1...8).map { session("s\($0)", .working) }
        let layout = PanelLayout(ranked: ranked, approvals: [], maxWaiting: 3, maxSessions: 5)
        #expect(layout.sessions.map(\.id) == ["s1", "s2", "s3", "s4", "s5"])
        #expect(layout.moreSessions == 3)
        #expect(!layout.isWaiting)
    }

    @Test func waitingPastTheCutStaysInTheListBelow() {
        let ranked = [session("a", .needs), session("b", .needs), session("c", .reply), session("d", .working)]
        let layout = PanelLayout(ranked: ranked, approvals: [approval("1", session: "a"), approval("2", session: "b")],
                                 maxWaiting: 2, maxSessions: 5)
        #expect(layout.approvals.map(\.id) == ["1", "2"])
        #expect(layout.questions.isEmpty)
        #expect(layout.moreWaiting == 1)
        // C has no card, so it still shows, first, in the ranked rows.
        #expect(layout.sessions.map(\.id) == ["c", "d"])
    }

    @Test func aPromptFromASessionNotListedStillGetsACard() {
        let layout = PanelLayout(ranked: [], approvals: [approval("1", session: "ghost")], maxWaiting: 3, maxSessions: 5)
        #expect(layout.approvals.count == 1)
        #expect(layout.sessions.isEmpty)
    }

    // MARK: Scroll height

    @Test func theMiddleTakesAllItNeedsWhenThePanelFits() {
        #expect(PanelLayout.scrollHeight(content: 400, fixed: 110, screen: 900) == 400)
        // Exactly at the limit still fits, so no empty scroll area.
        #expect(PanelLayout.scrollHeight(content: 766, fixed: 110, screen: 900) == 766)
    }

    @Test func theMiddleShrinksToTheScreenWhenItWouldRunOff() {
        // A 13 inch screen, about 780 pt visible, with the 920 pt worst case.
        #expect(PanelLayout.scrollHeight(content: 810, fixed: 110, screen: 780) == 646)
    }

    @Test func theMiddleNeverShrinksBelowTheMinimum() {
        #expect(PanelLayout.scrollHeight(content: 500, fixed: 110, screen: 200) == 120)
        // Content shorter than the minimum is not padded.
        #expect(PanelLayout.scrollHeight(content: 80, fixed: 300, screen: 200) == 80)
    }
}
