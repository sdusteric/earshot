import Foundation
import Testing
@testable import KobiKit

/// The roll call and the greeting read a wait you dismissed in Activity as
/// open, as Activity does, so neither says a dismissed session needs you.
@Suite struct RollCallTests {
    let now = Date(timeIntervalSince1970: 1_791_800_000)

    func session(_ id: String, _ name: String, waiting: Bool = false, busy: Bool = false, state: SessionState? = nil,
                 since: Date? = nil) -> LiveSession {
        LiveSession(id: id, pid: 1, kind: "interactive", cwd: "/p/\(id)", project: name, title: "", label: "", name: name,
                    busy: busy, waiting: waiting, state: state, detail: nil, since: since)
    }

    func dismissed(_ id: String, at: Date) -> Dismissals {
        var d = Dismissals()
        d.dismiss(id, now: at)
        return d
    }

    @Test func aDismissedWaitIsCountedAsIdle() {
        let list = [session("a", "blog", waiting: true, state: .needs, since: now.addingTimeInterval(-60)),
                    session("b", "docs", busy: true, state: .working, since: now.addingTimeInterval(-60))]
        #expect(RollCall.line(list, now: now, hour: 12) == "Two sessions. Blog is waiting on you. Docs is working, 1 minute in.")
        let d = dismissed("a", at: now.addingTimeInterval(-30))
        #expect(RollCall.line(list, now: now, hour: 12, dismissals: d)
                == "Two sessions. Docs is working, 1 minute in. One other is idle. Nothing needs you.")
    }

    @Test func aWaitThatBeganAfterTheDismissalIsSaid() {
        let list = [session("a", "blog", waiting: true, state: .needs, since: now.addingTimeInterval(-10))]
        let d = dismissed("a", at: now.addingTimeInterval(-30))
        #expect(RollCall.line(list, now: now, hour: 12, dismissals: d) == "One session. Blog is waiting on you.")
    }

    /// A session only Claude Code lists (no plugin state) waits on you by its own flag.
    @Test func aDismissedClaudeCodeWaitIsIdleToo() {
        let list = [session("a", "blog", waiting: true)]
        let d = dismissed("a", at: now)
        #expect(RollCall.line(list, now: now, hour: 12, dismissals: d) == "One session. It's idle. Nothing needs you.")
    }

    @Test func theGreetingLeavesADismissedWaitOut() {
        let list = [session("a", "blog", waiting: true, state: .needs, since: now.addingTimeInterval(-60))]
        let d = dismissed("a", at: now)
        #expect(RollCall.greeting(list, now: now, hour: 12, pick: { _ in 0 }).contains("Blog is waiting on you."))
        #expect(RollCall.greeting(list, now: now, hour: 12, dismissals: d, pick: { _ in 0 })
                == "Doing fine. Nothing's running, and nothing needs you.")
    }

    @Test func oneSessionSaidOnItsOwnReadsTheDismissalToo() {
        let s = session("a", "blog", waiting: true, state: .needs, since: now.addingTimeInterval(-60))
        #expect(RollCall.sentence(s, now: now) == "Blog is waiting on you.")
        #expect(RollCall.sentence(s, now: now, dismissals: dismissed("a", at: now)) == "Blog is idle.")
    }
}
