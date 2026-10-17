import Foundation
import Testing
@testable import KobiKit

@Suite struct ActivityNavigationTests {
    func session(_ id: String, _ state: SessionState) -> SessionInfo {
        SessionInfo(id: id, name: id, state: state, detail: nil, updated: Date(timeIntervalSince1970: 0))
    }

    // MARK: Sidebar order

    @Test func theSidebarListsSessionsGroupByGroup() {
        let list = [session("a", .open), session("b", .working), session("c", .needs), session("d", .done),
                    session("e", .failed), session("f", .reply), session("g", .stuck), session("h", .closed)]
        #expect(ActivityNavigation.sidebarOrder(list).map(\.id) == ["c", "f", "e", "g", "b", "d", "a", "h"])
    }

    @Test func sessionsKeepTheirOrderWithinAGroup() {
        let list = [session("w1", .working), session("o1", .open), session("w2", .working), session("o2", .open)]
        #expect(ActivityNavigation.sidebarOrder(list).map(\.id) == ["w1", "w2", "o1", "o2"])
    }

    @Test func onlyTheFirstNineSessionsGetANumber() {
        let list = (1...12).map { session("s\($0)", .open) } + [session("asks", .needs)]
        let numbered = ActivityNavigation.numbered(list)
        #expect(numbered.count == 9)
        #expect(numbered.first?.id == "asks")
        #expect(numbered.last?.id == "s8")
    }

    @Test func noSessionsMeansNoNumbers() {
        #expect(ActivityNavigation.numbered([]).isEmpty)
    }

    @Test func theLayoutKeyChangesWhenASessionMovesGroups() {
        let before = ActivityNavigation.layoutKey([session("a", .working), session("b", .open)])
        let after = ActivityNavigation.layoutKey([session("a", .needs), session("b", .open)])
        let same = ActivityNavigation.layoutKey([session("a", .working), session("b", .open)])
        #expect(before != after)
        #expect(before == same)
        // needs and reply share a group: no move to show.
        #expect(ActivityNavigation.layoutKey([session("a", .needs)]) == ActivityNavigation.layoutKey([session("a", .reply)]))
    }

    @Test func groupsFollowTheirStates() {
        #expect(ActivityGroup(.needs) == .needsYou)
        #expect(ActivityGroup(.reply) == .needsYou)
        #expect(ActivityGroup(.stuck) == .trouble)
        #expect(ActivityGroup(.failed) == .trouble)
        #expect(ActivityGroup(.working) == .working)
        #expect(ActivityGroup(.done) == .finished)
        #expect(ActivityGroup(.closed) == .open)
    }

    // MARK: Quick switcher

    let candidates: [SwitcherMatch.Candidate] = [
        .init(id: "1", name: "blog"),
        .init(id: "2", name: "billing service", other: ["Fix the invoice export"]),
        .init(id: "3", name: "wedding site", other: ["~/Documents/wedding"]),
        .init(id: "4", name: "mobile-billing"),
        .init(id: "5", name: "Café menu"),
    ]

    @Test func anEmptyQueryListsEverySessionInOrder() {
        #expect(SwitcherMatch.rank("", candidates) == ["1", "2", "3", "4", "5"])
        #expect(SwitcherMatch.rank("   ", candidates) == ["1", "2", "3", "4", "5"])
    }

    @Test func theStartOfANameBeatsTheStartOfALaterWord() {
        #expect(SwitcherMatch.rank("bill", candidates) == ["2", "4"])
    }

    @Test func theWholeNameComesFirst() {
        #expect(SwitcherMatch.rank("Blog", candidates).first == "1")
    }

    @Test func eachWordCanStartAWordOfTheName() {
        #expect(SwitcherMatch.rank("bil ser", candidates) == ["2"])
        #expect(SwitcherMatch.rank("site wed", candidates) == ["3"])
    }

    @Test func otherWordsFindASessionAfterItsName() {
        #expect(SwitcherMatch.rank("invoice", candidates) == ["2"])
        #expect(SwitcherMatch.rank("documents", candidates) == ["3"])
    }

    @Test func lettersInOrderFindAName() {
        #expect(SwitcherMatch.rank("bsv", candidates) == ["2"])
    }

    @Test func caseAccentsAndDashesDontMatter() {
        #expect(SwitcherMatch.rank("CAFE", candidates) == ["5"])
        #expect(SwitcherMatch.rank("mobile billing", candidates) == ["4"])
    }

    @Test func nothingMatchesNonsense() {
        #expect(SwitcherMatch.rank("zzz", candidates).isEmpty)
    }
}
