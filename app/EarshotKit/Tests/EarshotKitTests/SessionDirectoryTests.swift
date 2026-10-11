import Foundation
import Testing
@testable import EarshotKit

/// claude, scripted: agents JSON, and every call recorded.
actor FakeRunner: ClaudeRunner {
    var agents: [AgentEntry]
    var results: [String: RunResult] = [:]   // by first argument
    private(set) var calls: [(args: [String], cwd: String?)] = []
    init(_ agents: [AgentEntry]) { self.agents = agents }
    func setAgents(_ a: [AgentEntry]) { agents = a }
    func setResult(_ first: String, _ r: RunResult) { results[first] = r }
    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        calls.append((args, cwd))
        if args.first == "agents" {
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

    @Test func rollCallPutsSessionsThatNeedYouFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func s(_ id: String, _ name: String, _ state: SessionState?, detail: String? = nil, mins: Double = 0,
               busy: Bool = false) -> LiveSession {
            LiveSession(id: id, pid: 1, kind: "interactive", cwd: "/p", project: name, title: "", label: "", name: name,
                        busy: busy, waiting: false, state: state, detail: detail, since: now.addingTimeInterval(-mins * 60))
        }
        let line = RollCall.line([s("a", "invoice api", .working, mins: 12), s("b", "docs site", .done, detail: "fixed the broken links"),
                                  s("c", "billing service", .needs, detail: "needs your OK to run the database migration")], now: now)
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
        let line = RollCall.line(list, now: now)
        #expect(line.hasPrefix("Eight sessions. P1 is open."))
        #expect(line.hasSuffix("And 2 more."))
    }
}
