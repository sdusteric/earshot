import Foundation
import Testing
@testable import KobiKit

struct DismissalsTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func known(_ id: String, _ state: SessionState, since: Date) -> SessionInfo {
        var s = SessionInfo(id: id, name: id, state: state, detail: nil, updated: since, project: id, title: nil)
        s.since = since
        return s
    }

    func live(_ id: String, waiting: Bool, since: Date? = nil) -> LiveSession {
        LiveSession(id: id, pid: nil, kind: "background", cwd: "/p/\(id)", project: id, title: "", label: "", name: id,
                    busy: false, waiting: waiting, state: nil, detail: nil, since: since)
    }

    @Test func aDismissedWaitReadsAsOpen() {
        var d = Dismissals()
        d.dismiss("w", now: t0.addingTimeInterval(60))
        #expect(d.apply(known("w", .needs, since: t0)).state == .open)
        #expect(d.apply(known("w", .reply, since: t0)).state == .open)
        #expect(d.apply(live("w", waiting: true)).waiting == false)
        // Other sessions, and states that don't wait on you, are left alone.
        #expect(d.apply(known("x", .needs, since: t0)).state == .needs)
        #expect(d.apply(known("w", .working, since: t0)).state == .working)
    }

    @Test func aWaitThatBeganAfterTheDismissalShows() {
        var d = Dismissals()
        d.dismiss("w", now: t0)
        #expect(d.apply(known("w", .needs, since: t0.addingTimeInterval(5))).state == .needs)
        #expect(d.apply(live("w", waiting: true, since: t0.addingTimeInterval(5))).waiting)
    }

    @Test func pruningKeepsOnlyDismissalsThatStillHoldAWaitBack() {
        var d = Dismissals()
        d.dismiss("still", now: t0)
        d.dismiss("asked again", now: t0)
        d.dismiss("working now", now: t0)
        d.dismiss("gone", now: t0)
        d.dismiss("blocked job", now: t0)
        let changed = d.prune(
            known: [known("still", .needs, since: t0.addingTimeInterval(-60)),
                    known("asked again", .reply, since: t0.addingTimeInterval(60)),
                    known("working now", .working, since: t0.addingTimeInterval(60))],
            live: [live("blocked job", waiting: true)], now: t0.addingTimeInterval(8 * 86_400))
        #expect(changed)
        #expect(Set(d.at.keys) == ["still", "blocked job"])
        let again = d.prune(known: [known("still", .needs, since: t0)], live: [live("blocked job", waiting: true)])
        #expect(again == false)
    }

    @Test func aSessionMissingFromAListKeepsItsDismissalForAWeek() {
        var d = Dismissals()
        d.dismiss("w", now: t0)
        let soon = d.prune(known: [], live: [], now: t0.addingTimeInterval(3600))
        #expect(soon == false)
        let later = d.prune(known: [], live: [], now: t0.addingTimeInterval(8 * 86_400))
        #expect(later)
    }

    @Test func restoringBringsTheWaitBack() {
        var d = Dismissals()
        d.dismiss("w", now: t0)
        d.restore("w")
        #expect(!d.isDismissed("w"))
        #expect(d.apply(known("w", .needs, since: t0.addingTimeInterval(-60))).state == .needs)
    }

    @Test func itSurvivesARelaunch() throws {
        var d = Dismissals()
        d.dismiss("w", now: t0)
        let back = try JSONDecoder().decode(Dismissals.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    @Test func listsReadDismissedWaitsAsOpen() {
        var d = Dismissals()
        d.dismiss("w", now: t0.addingTimeInterval(60))
        #expect(d.apply([known("w", .needs, since: t0), known("x", .needs, since: t0)]).map(\.state) == [.open, .needs])
        #expect(d.apply([live("w", waiting: true), live("x", waiting: true)]).map(\.waiting) == [false, true])
    }

    /// The box the app fills, for the roll call and the recap.
    @Test func theBoxHoldsWhatTheAppSetLast() {
        let box = DismissalsBox()
        #expect(box.current == Dismissals())
        var d = Dismissals()
        d.dismiss("w", now: t0)
        box.set(d)
        #expect(box.current.isDismissed("w"))
        d.restore("w")
        box.set(d)
        #expect(!box.current.isDismissed("w"))
    }
}
