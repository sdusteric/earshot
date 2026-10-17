import Foundation
import Testing
@testable import KobiKit

@Suite struct BannerApprovalTests {
    let now = Date(timeIntervalSince1970: 1_791_800_000)

    func approval(_ id: String, session: String, what: String = "to run the migration") -> OpenApproval {
        OpenApproval(session: session, id: id, name: session, what: what, answerPath: "/x/answer-\(session)-\(id)",
                     secret: String(repeating: "a", count: 32), pid: nil, opened: now)
    }

    @Test func aBannerGetsButtonsOnlyForItsSessionsOneOpenPrompt() {
        let open = [approval("1", session: "blog"), approval("2", session: "billing"), approval("3", session: "billing")]
        #expect(BannerApproval.match(session: "blog", open: open)?.id == "1")
        // Two prompts in one session: a button could answer the wrong one, so none.
        #expect(BannerApproval.match(session: "billing", open: open) == nil)
        #expect(BannerApproval.match(session: "notes", open: open) == nil)
    }

    @Test func aButtonAnswersOnlyThePromptItWasMadeFor() {
        let open = [approval("1", session: "blog")]
        #expect(BannerApproval.target(id: "1", session: "blog", open: open)?.id == "1")
        // Answered or gone: nothing to answer.
        #expect(BannerApproval.target(id: "1", session: "blog", open: []) == nil)
        #expect(BannerApproval.target(id: "2", session: "blog", open: open) == nil)
        // The same id under another session is not this banner's prompt.
        #expect(BannerApproval.target(id: "1", session: "billing", open: open) == nil)
    }

    @Test func theBannerSaysWhatThePromptAsksFor() {
        #expect(BannerApproval.body(approval("1", session: "blog")) == "Wants to run the migration.")
        #expect(BannerApproval.body(approval("1", session: "blog", what: "")) == "Wants your OK.")
    }

    /// A banner posted before its prompt reached Kobi gets the buttons when the prompt arrives.
    @Test func aBannerWithoutButtonsIsPostedAgainOnceItsPromptArrives() {
        let shown = [BannerApproval.Shown(session: "blog", approval: nil)]
        #expect(BannerApproval.repost(shown: shown, open: []).isEmpty)
        let r = BannerApproval.repost(shown: shown, open: [approval("1", session: "blog")])
        #expect(r.map(\.session) == ["blog"])
        #expect(r.first?.approval.id == "1")
    }

    @Test func onlyWhenTheSessionHasExactlyOneOpenPrompt() {
        let shown = [BannerApproval.Shown(session: "blog", approval: nil)]
        let two = [approval("1", session: "blog"), approval("2", session: "blog")]
        #expect(BannerApproval.repost(shown: shown, open: two).isEmpty)
        // Another session's prompt gives this banner nothing.
        #expect(BannerApproval.repost(shown: shown, open: [approval("3", session: "billing")]).isEmpty)
    }

    @Test func aBannerWhoseButtonsStillAnswerAnOpenPromptIsLeftAlone() {
        let shown = [BannerApproval.Shown(session: "blog", approval: "1")]
        #expect(BannerApproval.repost(shown: shown, open: [approval("1", session: "blog")]).isEmpty)
        // Its prompt closed and a new one is open: the buttons move to the new one.
        let r = BannerApproval.repost(shown: shown, open: [approval("2", session: "blog")])
        #expect(r.first?.approval.id == "2")
    }

    @Test func eachSessionIsPostedAgainOnceAndOnlyItsOwnBanners() {
        let shown = [BannerApproval.Shown(session: "blog", approval: nil), BannerApproval.Shown(session: "blog", approval: nil),
                     BannerApproval.Shown(session: "docs", approval: nil)]
        let r = BannerApproval.repost(shown: shown, open: [approval("1", session: "blog"), approval("2", session: "notes")])
        #expect(r.map(\.session) == ["blog"])
    }
}
