import Foundation
import Testing
@testable import EarshotKit

/// claude, scripted: agents JSON, and every call recorded.
actor FakeRunner: ClaudeRunner {
    var agents: [AgentEntry]
    var results: [String: RunResult] = [:]   // by first argument
    private(set) var calls: [(args: [String], cwd: String?)] = []
    private var hold = false
    private var failAgents = false
    func setHold(_ h: Bool) { hold = h }
    func setFail(_ f: Bool) { failAgents = f }
    init(_ agents: [AgentEntry]) { self.agents = agents }
    func setAgents(_ a: [AgentEntry]) { agents = a }
    func setResult(_ first: String, _ r: RunResult) { results[first] = r }
    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        calls.append((args, cwd))
        if args.first == "agents" {
            while hold { await Task.yield() }
            if failAgents { return RunResult(status: 1) }
            let objs: [[String: Any]] = agents.map { a in
                var d: [String: Any] = ["sessionId": a.sessionId, "cwd": a.cwd, "kind": a.kind]
                if let p = a.pid { d["pid"] = p }
                if let n = a.name { d["name"] = n }
                if let s = a.status { d["status"] = s }
                if let s = a.state { d["state"] = s }
                return d
            }
            return RunResult(status: 0, stdout: try! JSONSerialization.data(withJSONObject: objs))
        }
        return results[args.first ?? ""] ?? RunResult(status: 0)
    }
    func version() async -> String? { "2.1.296" }
    var argLists: [[String]] { calls.map(\.args) }
}

func agent(_ id: String, _ dir: String, name: String? = nil, pid: Int32? = 100, kind: String = "interactive",
           status: String? = "idle") -> AgentEntry {
    AgentEntry(sessionId: id, pid: pid, cwd: "/p/\(dir)", kind: kind, name: name, status: status)
}

@Suite struct SessionDirectoryTests {
    let store = SessionStore()
    let labeler = Labeler(model: nil, liveDir: NSTemporaryDirectory())

    func directory(_ agents: [AgentEntry], now: @escaping @Sendable () -> Date = Date.init,
                   claudeJSON: String = "/nonexistent") async -> (SessionDirectory, FakeRunner) {
        let runner = FakeRunner(agents)
        let d = SessionDirectory(runner: runner, store: store, labeler: labeler, claudeJSON: claudeJSON, clock: now)
        await d.refresh()
        return (d, runner)
    }

    @Test func namesFollowTheShortestUniqueRule() async {
        let (d, _) = await directory([agent("a", "billing-service", name: "Fix refund rounding"),
                                      agent("b", "billing-service", name: "Invoice export"),
                                      agent("c", "blog", name: "blog-83")])
        let names = await d.sessions.map(\.name).sorted()
        #expect(names == ["blog", "the Fix refund rounding session", "the Invoice export session"])
    }

    @Test func aReplyStateIsNotWaitingInTheFallbackList() async {
        await store.apply(.init(session: "a", state: .reply, detail: "asked", name: "billing service"))
        let (d, runner) = await directory([agent("a", "billing-service")])
        await runner.setFail(true)
        await d.refresh()
        #expect(await d.lastRefreshSucceeded == false)
        let s = await d.session("a")
        #expect(s?.state == .reply)
        #expect(s?.waiting == false)
    }

    @Test func thePluginsStatusAndTitleWin() async {
        await store.apply(.init(session: "a", state: .needs, detail: "needs your OK to run the migration",
                                name: "billing service", project: "billing service", title: "Refund rounding"))
        let (d, _) = await directory([agent("a", "billing-service", name: "billing-service-1f")])
        let s = await d.session("a")
        #expect(s?.state == .needs)
        #expect(s?.title == "Refund rounding")
        #expect(s?.detail == "needs your OK to run the migration")
    }

    @Test(arguments: [
        ("billing service", "a"), ("Billing Service", "a"), ("billing services", "a"), ("the billing service", "a"),
        ("fine brief", "b"), ("finebrief", "b"), ("blog", "c"), ("the blog session", "c"),
    ])
    func matchesSpokenNames(_ said: String, _ id: String) async {
        let (d, _) = await directory([agent("a", "billing-service"), agent("b", "finebrief"), agent("c", "blog")])
        guard case .one(let s) = await d.resolve(said) else { Issue.record("no single match for \(said)"); return }
        #expect(s.id == id)
    }

    @Test func twoSessionsInOneProjectAreBothMatches() async {
        let (d, _) = await directory([agent("a", "billing-service", name: "Fix refund rounding"),
                                      agent("b", "billing-service", name: "Invoice export"), agent("c", "blog")])
        guard case .several(let list) = await d.resolve("billing") else { Issue.record("expected several"); return }
        #expect(Set(list.map(\.id)) == ["a", "b"])
        guard case .one(let s) = await d.resolve("invoice export") else { Issue.record("label"); return }
        #expect(s.id == "b")
        guard case .one(let r) = await d.resolve("refund rounding in billing service") else { Issue.record("label in project"); return }
        #expect(r.id == "a")
    }

    /// "How is reflow going" asked "which one?" between reflow and Project status.
    @Test func theSpokenNameWinsOverASharedFolder() async {
        let (d, _) = await directory([agent("a", "reflow"), agent("b", "reflow", name: "Project status")])
        let names = await d.sessions.map(\.name).sorted()
        guard case .one(let s) = await d.resolve("reflow") else { Issue.record("expected one; names \(names)"); return }
        #expect(s.id == "a")
    }

    @Test func anUnknownNameIsNone() async {
        let (d, _) = await directory([agent("a", "billing-service"), agent("c", "blog")])
        #expect(await d.resolve("payments") == .none)
    }

    @Test func noTargetIsTheOnlySession() async {
        let (d, _) = await directory([agent("c", "blog")])
        guard case .one(let s) = await d.resolve(nil) else { Issue.record("expected one"); return }
        #expect(s.id == "c")
    }

    @Test func noTargetIsTheLastSpokenAboutForTwoMinutes() async {
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        let (d, _) = await directory([agent("a", "billing-service"), agent("c", "blog")], now: { now.value })
        #expect(await d.resolve(nil) == .noTarget)
        await d.noteSpoke(about: "c")
        now.value = now.value.addingTimeInterval(119)
        guard case .one(let s) = await d.resolve(nil) else { Issue.record("expected the last one"); return }
        #expect(s.id == "c")
        now.value = now.value.addingTimeInterval(2)
        #expect(await d.resolve(nil) == .noTarget)
    }

    @Test func resolveAmongTheOffered() async {
        let (d, _) = await directory([agent("a", "billing-service", name: "Fix refund rounding"),
                                      agent("b", "billing-service", name: "Invoice export"), agent("c", "blog")])
        guard case .one(let s) = await d.resolve("the second one invoices", among: ["a", "b"]) else {
            Issue.record("expected invoices"); return
        }
        #expect(s.id == "b")
    }

    @Test func vocabularyHasProjectsAndLabels() async {
        let (d, _) = await directory([agent("a", "finebrief", name: "Orchestrator agent for multi-session voice control")])
        let v = await d.vocabulary()
        #expect(v.contains("finebrief"))
        #expect(v.contains("Orchestrator agent"))
    }

    @Test func knownProjectsComeFromClaudeJSONAndLiveSessions() async throws {
        let path = NSTemporaryDirectory() + "ek-claude-\(UUID().uuidString.prefix(6)).json"
        try #"{"projects":{"/p/blog":{"hasTrustDialogAccepted":true},"/p/new-thing":{"hasTrustDialogAccepted":false}},"other":1}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let (d, _) = await directory([agent("a", "billing-service")], claudeJSON: path)
        let known = await d.knownProjects()
        #expect(known.contains(KnownProject(name: "blog", path: "/p/blog", trusted: true)))
        #expect(known.contains(KnownProject(name: "new thing", path: "/p/new-thing", trusted: false)))
        #expect(known.contains(KnownProject(name: "billing service", path: "/p/billing-service", trusted: true)))
        #expect(await d.matchProject("the blog")?.path == "/p/blog")
        #expect(await d.matchProject("newthing")?.path == "/p/new-thing")
        #expect(await d.matchProject("payments") == nil)
    }

    @Test func theClaudeJSONIsReadOnceUntilItChanges() async throws {
        let path = NSTemporaryDirectory() + "ek-claude-\(UUID().uuidString.prefix(6)).json"
        try #"{"projects":{"/p/blog":{"hasTrustDialogAccepted":true}}}"#.write(toFile: path, atomically: true, encoding: .utf8)
        let reads = Box(0)
        let d = SessionDirectory(runner: FakeRunner([agent("a", "billing-service")]), store: store, labeler: labeler,
                                 claudeJSON: path, readFile: { reads.value += 1; return FileManager.default.contents(atPath: $0) })
        await d.refresh()
        for _ in 0..<3 { _ = await d.vocabulary(); _ = await d.matchProject("blog") }
        #expect(reads.value == 1)
        try #"{"projects":{"/p/blog":{"hasTrustDialogAccepted":true},"/p/more":{}}}"#.write(toFile: path, atomically: true, encoding: .utf8)
        _ = await d.knownProjects()
        #expect(reads.value == 2)
        #expect(await d.matchProject("more")?.path == "/p/more")
    }

    @Test func overlappingRefreshesShareOneAgentsCall() async {
        let runner = FakeRunner([agent("a", "blog")])
        await runner.setHold(true)
        let d = SessionDirectory(runner: runner, store: store, labeler: labeler, claudeJSON: "/nonexistent")
        let first = Task { await d.refresh() }
        while await runner.argLists.isEmpty { await Task.yield() }
        let second = Task { await d.refresh(ifOlderThan: 2); return await d.sessions.map(\.id) }
        for _ in 0..<20 { await Task.yield() }
        await runner.setHold(false)
        await first.value
        #expect(await second.value == ["a"])
        #expect(await d.sessions.map(\.id) == ["a"])
        #expect(await runner.argLists.filter { $0.first == "agents" }.count == 1)
    }

    @Test func aFailedRefreshDoesNotStampTheTime() async {
        let runner = FakeRunner([agent("a", "blog")])
        await runner.setFail(true)
        let d = SessionDirectory(runner: runner, store: store, labeler: labeler, claudeJSON: "/nonexistent")
        await d.refresh()
        await runner.setFail(false)
        await d.refresh(ifOlderThan: 60)
        #expect(await d.sessions.map(\.id) == ["a"])
    }

    @Test func aSessionOnlyThePluginKnowsIsNotListedWhenAgentsSucceeded() async {
        await store.apply(.init(session: "ghost", state: .working, name: "ghost", project: "ghost"))
        let (d, _) = await directory([agent("a", "blog")])
        #expect(await d.sessions.map(\.id) == ["a"])
    }

    @Test func whenAgentsFailsPluginSessionsStayAndKeepTheirPid() async {
        await store.apply(.init(session: "a", state: .working, name: "blog", project: "blog"))
        await store.apply(.init(session: "p", state: .working, name: "plug", project: "plug"))
        let (d, runner) = await directory([agent("a", "blog", pid: 4242)])
        #expect(await d.session("p") == nil)
        await runner.setFail(true)
        await d.refresh()
        #expect(Set(await d.sessions.map(\.id)) == ["a", "p"])
        #expect(await d.session("a")?.pid == 4242)
        #expect(await d.session("a")?.kind == "interactive")
    }

    @Test func rollCallPutsSessionsThatNeedYouFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func s(_ id: String, _ name: String, _ state: SessionState?, detail: String? = nil, mins: Double = 0,
               busy: Bool = false) -> LiveSession {
            LiveSession(id: id, pid: 1, kind: "interactive", cwd: "/p", project: name, title: "", label: "", name: name,
                        busy: busy, waiting: false, state: state, detail: detail, since: now.addingTimeInterval(-mins * 60))
        }
        let line = RollCall.line([s("a", "invoice api", .working, mins: 12), s("b", "docs site", .done, detail: "fixed the broken links"),
                                  s("c", "billing service", .needs, detail: "needs your OK to run the database migration")], now: now,
                                 hour: 14)
        #expect(line == "Three sessions. Billing service needs your OK to run the database migration. Invoice api is working, 12 minutes in. Docs site finished: fixed the broken links.")
        #expect(RollCall.line([], now: now) == "No Claude sessions are open.")
        #expect(RollCall.sentence(s("x", "blog", nil, busy: true), now: now) == "Blog is working.")
        #expect(RollCall.sentence(s("x", "blog", nil), now: now) == "Blog is open.")
    }

    @Test func rollCallNamesSixThenCounts() {
        let now = Date()
        let list = (1...8).map { i in
            LiveSession(id: "\(i)", pid: 1, kind: "interactive", cwd: "/p", project: "p\(i)", title: "", label: "",
                        name: "p\(i)", busy: false, waiting: false, state: .open, detail: nil, since: now.addingTimeInterval(Double(i)))
        }
        let line = RollCall.line(list, now: now, hour: 14)
        #expect(line.hasPrefix("Eight sessions. P1 is open."))
        #expect(line.hasSuffix("And 2 more. Nothing needs you."))
    }
}

/// Earshot's voice: what it noticed, in a coworker's words.
@Suite struct PersonalityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func s(_ name: String, _ state: SessionState?, mins: Double = 0, detail: String? = nil) -> LiveSession {
        LiveSession(id: name, pid: 1, kind: "interactive", cwd: "/p", project: name, title: "", label: "", name: name,
                    busy: state == .working, waiting: state == .needs, state: state, detail: detail,
                    since: now.addingTimeInterval(-mins * 60))
    }

    @Test func aLongRunAndALongWaitAreMentioned() {
        #expect(RollCall.sentence(s("billing", .working, mins: 65), now: now) == "Billing's been at it for about an hour.")
        #expect(RollCall.sentence(s("docs", .working, mins: 40), now: now) == "Docs has been at it for 40 minutes.")
        #expect(RollCall.sentence(s("reflow", .needs, mins: 25), now: now) == "Reflow's been waiting on you for 25 minutes.")
        #expect(RollCall.sentence(s("reflow", .needs, mins: 3), now: now) == "Reflow is waiting on you.")
        #expect(RollCall.sentence(s("blog", .needs, mins: 130, detail: "wants to push to main"), now: now)
                == "Blog wants to push to main. That was about 2 hours ago.")
    }

    @Test func theRollCallEndsWithWhatItNoticed() {
        let quiet = [s("blog", .done), s("docs", .open)]
        #expect(RollCall.line(quiet, now: now, hour: 15) == "Two sessions. Blog finished. Docs is open. Nothing needs you.")
        let late = [s("billing", .working, mins: 5)]
        #expect(RollCall.line(late, now: now, hour: 1) == "One session. Billing is working, 5 minutes in. It's past midnight, and one's still going.")
        let waiting = [s("reflow", .needs, mins: 2)]
        #expect(RollCall.line(waiting, now: now, hour: 15) == "One session. Reflow is waiting on you.")
    }

    @Test func aGreetingIsShortAndSaysWhatMatters() {
        let all = [s("blog", .done), s("docs", .done), s("reflow", .needs, mins: 12), s("billing", .working, mins: 80),
                   s("api", .working, mins: 4)]
        #expect(RollCall.greeting(all, now: now, hour: 15, pick: { _ in 0 })
                == "Doing okay. Reflow's been waiting on you for 12 minutes. Two are working. Billing's been at it for over an hour.")
        #expect(RollCall.greeting([s("blog", .done)], now: now, hour: 15, pick: { _ in 1 })
                == "All good here. Nothing's running, and nothing needs you.")
        #expect(RollCall.greeting([s("api", .working, mins: 4), s("ui", .working, mins: 2)], now: now, hour: 23, pick: { _ in 2 })
                == "Pretty good, thanks. Two are working. It's getting late, and two are still going.")
        #expect(RollCall.greeting([], now: now, hour: 15, pick: { _ in 3 }) == "Not bad. No sessions are open.")
    }

    @Test func aGreetingNamesTwoThatNeedYouThenCounts() {
        let all = [s("a", .needs), s("b", .failed), s("c", .stuck)]
        #expect(RollCall.greeting(all, now: now, hour: 15, pick: { _ in 1 })
                == "Good, mostly. A is waiting on you. B hit an error. And 1 more need you. Nothing else is running.")
    }

    @Test func durationsReadLikeSpeech() {
        #expect(RollCall.duration(30) == "a minute")
        #expect(RollCall.duration(12 * 60) == "12 minutes")
        #expect(RollCall.duration(58 * 60) == "about an hour")
        #expect(RollCall.duration(85 * 60) == "over an hour")
        #expect(RollCall.duration(170 * 60) == "about 3 hours")
    }

    /// A state that repeats keeps its start time, so a long run counts from its start.
    @Test func aRepeatedStateKeepsWhenItBegan() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let store = SessionStore(clock: { clock.now })
        await store.apply(AppMessage.Status(session: "s", state: .working))
        clock.now = Date(timeIntervalSince1970: 2000)
        await store.apply(AppMessage.Status(session: "s", state: .working))
        #expect(await store.sessions.first?.since == Date(timeIntervalSince1970: 1000))
        clock.now = Date(timeIntervalSince1970: 3000)
        await store.apply(AppMessage.Status(session: "s", state: .done))
        #expect(await store.sessions.first?.since == Date(timeIntervalSince1970: 3000))
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
