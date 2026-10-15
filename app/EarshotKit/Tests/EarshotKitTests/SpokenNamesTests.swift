import Foundation
import Testing
@testable import EarshotKit

@Suite struct SpokenNamesTests {
    @Test(arguments: [
        ("/Users/me/code/billing_service", "billing service"),
        ("/Users/me/code/billingService", "billing Service"),
        ("/Users/me/code/finebrief.app", "finebrief app"),
        ("/Users/me/code/billing-service/src/api", "billing service"),   // the git root
        ("/Users/me", "home"),
        ("/Users/me/Documents/scripts", "home"),   // inside a home folder that is a git root
    ])
    func projectNames(_ cwd: String, _ expected: String) {
        let roots: Set<String> = ["/Users/me/code/billing-service", "/Users/me/code/billing_service",
                                  "/Users/me/code/billingService", "/Users/me/code/finebrief.app", "/Users/me"]
        #expect(SpokenNames.project(cwd: cwd, home: "/Users/me", isGitRoot: roots.contains) == expected)
    }

    /// The label rule, on real titles (same cases as the plugin's tests).
    @Test(arguments: [
        ("Create guest confirmation email with event details", "guest confirmation email"),
        ("Fix refund rounding", "Fix refund rounding"),
        ("Orchestrator agent for multi-session voice control", "Orchestrator agent"),
        ("Add a dark mode toggle to the settings page", "dark mode toggle"),
        ("Debug the flaky invoice test session", "flaky invoice test"),
        ("Investigate why_the_build fails on CI", "Investigate why build"),   // articles go anywhere
        ("Update the", "Update the"),
    ])
    func ruleLabels(_ title: String, _ expected: String) {
        #expect(SpokenNames.ruleLabel(title) == expected)
    }

    @Test func theProjectWhenItIsTheOnlySessionThere() {
        let n = SpokenNames.names([.init(id: "a", project: "billing service", title: "Fix refund rounding", label: "refund rounding"),
                                   .init(id: "b", project: "blog", title: "", label: ""),
                                   .init(id: "c", project: "home", title: "Tidy dotfiles", label: "Tidy dotfiles")])
        #expect(n["a"] == "Billing service")
        #expect(n["b"] == "Blog")
        #expect(n["c"] == "Home")
    }

    @Test func theProjectAndATopicWhenTwoShareAProject() {
        let n = SpokenNames.names([.init(id: "a", project: "billing service", title: "Fix refund rounding", label: "refund rounding"),
                                   .init(id: "b", project: "billing service", title: "Invoice export", label: "invoices")])
        #expect(n["a"] == "Billing service refund")
        #expect(n["b"] == "Billing service invoice")
    }

    /// One more word only while two topics are the same; the same title everywhere goes by age.
    @Test func aTopicGrowsOnlyWhileItClashes() {
        let n = SpokenNames.names([.init(id: "a", project: "reflow", title: "Retry queue backoff", label: ""),
                                   .init(id: "b", project: "reflow", title: "Retry docs", label: ""),
                                   .init(id: "c", project: "reflow", title: "Docs site", label: ""),
                                   .init(id: "d", project: "blog", title: "Retry queue backoff", label: "")])
        #expect(n["a"] == "Reflow retry queue")
        #expect(n["b"] == "Reflow retry docs")
        #expect(n["c"] == "Reflow docs")
        #expect(n["d"] == "Blog")   // the only blog session
        let t0 = Date(timeIntervalSince1970: 1000)
        let same = SpokenNames.names([.init(id: "a", project: "reflow", title: "Tests", label: "", started: t0.addingTimeInterval(5)),
                                      .init(id: "b", project: "reflow", title: "Tests", label: "", started: t0)])
        #expect(same["a"] == "Newer reflow tests")
        #expect(same["b"] == "Older reflow tests")
    }

    @Test func aSessionWithoutATitleIsItsProject() {
        let n = SpokenNames.names([.init(id: "a", project: "blog", title: "", label: ""),
                                   .init(id: "b", project: "blog", title: "Fix RSS", label: "Fix RSS")])
        #expect(n["a"] == "Blog")
        #expect(n["b"] == "Blog RSS")
    }

    /// The sessions open on the Mac this was made on, as `claude agents --json` lists them.
    @Test func realSessionsGetShortDistinctNames() {
        let t = { (s: Double) in Date(timeIntervalSince1970: 1_791_000_000 + s) }
        let n = SpokenNames.names([
            .init(id: "wedding", project: "wedding", title: "Create guest confirmation email with event details", label: "", started: t(0)),
            .init(id: "blog-83", project: "blog", title: "", label: "", started: t(1)),
            .init(id: "projects", project: "Projects", title: "", label: "", started: t(2)),
            .init(id: "reflow-d5", project: "reflow", title: "", label: "", started: t(3)),
            .init(id: "finebrief-5e", project: "finebrief", title: "", label: "", started: t(4)),
            .init(id: "scripts", project: "home", title: "", label: "", started: t(5)),
            .init(id: "roadmap", project: "earshot", title: "Plugin/Mac app product roadmap", label: "", started: t(6)),
            .init(id: "next", project: "finebrief", title: "What's next", label: "", started: t(7)),
            .init(id: "status", project: "reflow", title: "Project status and milestones", label: "", started: t(8)),
            .init(id: "launch", project: "finebrief", title: "Launch and onboarding UX", label: "", started: t(9)),
            .init(id: "links", project: "blog", title: "Showcase site links page", label: "", started: t(10)),
            .init(id: "overlap", project: "earshot", title: "Session overlap check", label: "", started: t(11)),
            .init(id: "icon", project: "earshot", title: "Notification icon", label: "", started: t(12)),
        ])
        #expect(n == ["wedding": "Wedding", "blog-83": "Blog", "projects": "Projects", "reflow-d5": "Reflow",
                      "finebrief-5e": "Finebrief", "scripts": "Home", "roadmap": "Earshot plugin",
                      "next": "Finebrief what's next", "status": "Reflow milestones", "launch": "Finebrief launch",
                      "links": "Blog showcase", "overlap": "Earshot overlap", "icon": "Earshot notification"])
        #expect(Set(n.values.map(NameMatch.normalize)).count == n.count)
        #expect(!n.values.contains { $0.lowercased().hasPrefix("the ") || $0.lowercased().hasSuffix(" session") })
    }

    /// Untitled sessions in one folder would all be the folder's name: they are told apart by age.
    @Test func untitledTwinsAreToldApartByAge() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let two = SpokenNames.names([.init(id: "a", project: "blog", title: "", label: "", started: t0.addingTimeInterval(60)),
                                     .init(id: "b", project: "blog", title: "", label: "", started: t0),
                                     .init(id: "c", project: "docs", title: "", label: "", started: t0)])
        #expect(two["a"] == "Newer blog")
        #expect(two["b"] == "Older blog")
        #expect(two["c"] == "Docs")
        let three = SpokenNames.names((0..<3).map {
            .init(id: "\($0)", project: "blog", title: "", label: "", started: t0.addingTimeInterval(Double(-$0)))
        })
        #expect(three["2"] == "First blog")   // the oldest
        #expect(three["1"] == "Second blog")
        #expect(three["0"] == "Third blog")
        // Without start times: in the order Claude Code lists them.
        let unknown = SpokenNames.names([.init(id: "a", project: "blog", title: "", label: ""),
                                         .init(id: "b", project: "blog", title: "", label: "")])
        #expect(unknown["a"] == "First blog")
        #expect(unknown["b"] == "Second blog")
    }

    /// A name given stays while the session lives: a newcomer in its folder,
    /// a new title or a refresh never renames it.
    @Test func namesStayWhileASessionLives() {
        let a = SpokenNames.Entry(id: "a", project: "reflow", title: "", label: "")
        var n = SpokenNames.names([a])
        #expect(n["a"] == "Reflow")
        let b = SpokenNames.Entry(id: "b", project: "reflow", title: "Retry queue", label: "")
        n = SpokenNames.names([a, b], keeping: n)
        #expect(n == ["a": "Reflow", "b": "Reflow retry"])
        // a gets a title, b's title changes: both keep their names.
        let a2 = SpokenNames.Entry(id: "a", project: "reflow", title: "Docs", label: "")
        let b2 = SpokenNames.Entry(id: "b", project: "reflow", title: "Docs site", label: "")
        n = SpokenNames.names([a2, b2], keeping: n)
        #expect(n == ["a": "Reflow", "b": "Reflow retry"])
        #expect(SpokenNames.names([a2, b2], keeping: n) == n)
        // A newcomer whose best name is taken gets the next one free.
        let c = SpokenNames.Entry(id: "c", project: "reflow", title: "Retry queue", label: "")
        n = SpokenNames.names([a2, b2, c], keeping: n)
        #expect(n["c"] == "Reflow retry queue")
        // Gone sessions drop out.
        #expect(SpokenNames.names([a2], keeping: n) == ["a": "Reflow"])
    }

    @Test(arguments: [
        ("Fix the flaky invoice test session", "reflow", ["flaky", "flaky invoice", "flaky invoice test"]),
        ("What's next", "finebrief", ["what's next"]),
        ("Project status and milestones", "reflow", ["milestones", "project status milestones"]),
        ("Reflow retry loop", "reflow", ["retry", "retry loop"]),   // the folder's own name is left out
        ("Launch and onboarding UX", "finebrief", ["launch", "launch onboarding", "launch onboarding UX"]),
        ("iOS widget", "blog", ["iOS", "iOS widget"]),
        ("the", "blog", []),
    ])
    func topicsFromTitles(_ title: String, _ project: String, _ expected: [String]) {
        #expect(SpokenNames.topics(title, project: project) == expected)
    }

    @Test(arguments: [
        ("the tax export session", "Tax export"), ("your home folder", "Home"), ("blog", "Blog"),
        ("refund rounding in billing service", "Refund rounding in billing service"), ("iOS app", "iOS app"),
    ])
    func pluginNamesAreTidied(_ plugin: String, _ expected: String) {
        #expect(SpokenNames.tidy(plugin) == expected)
    }

    /// The plugin's lines, said with Earshot's name for the session.
    @Test(arguments: [
        ("Still on reflow, about 9 minutes in.", "reflow", "Reflow docs", "Still on Reflow docs, about 9 minutes in."),
        ("Still on tax export, about 4 minutes in. Latest step: run the tests.", "the tax export session", "Billing export",
         "Still on Billing export, about 4 minutes in. Latest step: run the tests."),
        ("Hey, the tax export session needs your OK to run git push.", "the tax export session", "Billing export",
         "Hey, Billing export needs your OK to run git push."),
        ("Heads up, your home folder keeps hitting the same error. It might be stuck.", "your home folder", "Home",
         "Heads up, Home keeps hitting the same error. It might be stuck."),
        ("It's been 4 minutes. The tax export session is still waiting on you.", "the tax export session", "Billing export",
         "It's been 4 minutes. Billing export is still waiting on you."),
        ("Blog hit an error. Take a look when you can.", "blog", "Blog showcase",
         "Blog showcase hit an error. Take a look when you can."),
        ("From blog: the post is live on the blog.", "blog", "Blog showcase", "From Blog showcase: the post is live on the blog."),
        // A finished line is the session's own words: the same words there stay.
        ("Blog post is live. Blog is up.", "blog", "Blog showcase", "Blog post is live. Blog is up."),
        ("Moved the posts from blog, then the feed.", "blog", "Blog showcase", "Moved the posts from blog, then the feed."),
    ])
    func pluginLinesAreSaidWithTheName(_ text: String, _ who: String, _ name: String, _ expected: String) {
        #expect(SpokenNames.renamed(text, forms: SpokenNames.pluginForms(who), to: name) == expected)
    }

    @Test func defaultNamesAreNotTitles() {
        #expect(SpokenNames.isDefaultName("blog-83", cwd: "/Users/me/blog"))
        #expect(SpokenNames.isDefaultName("projects-2c", cwd: "/Users/me/Projects"))
        #expect(!SpokenNames.isDefaultName("Fix refund rounding", cwd: "/Users/me/billing"))
        #expect(!SpokenNames.isDefaultName("blog-redesign", cwd: "/Users/me/blog"))
    }

    struct FixedModel: LabelModel {
        let answer: String?
        func label(for title: String) async -> String? { answer }
    }

    @Test func shortTitlesAreUsedAsTheyAre() async {
        let l = Labeler(model: FixedModel(answer: "should not be asked"), liveDir: NSTemporaryDirectory())
        #expect(await l.label(session: "s", title: "Fix RSS feed") == "Fix RSS feed")
    }

    /// The rule label at once; the model's once it has answered.
    @Test func theModelShortensLongTitles() async {
        let l = Labeler(model: FixedModel(answer: "voice orchestrator"), liveDir: NSTemporaryDirectory())
        let title = "Orchestrator agent for multi-session voice control"
        #expect(await l.label(session: "s", title: title) == "Orchestrator agent")
        await l.settle()
        #expect(await l.label(session: "s", title: title) == "voice orchestrator")
    }

    @Test func aBadModelAnswerFallsBackToTheRule() async {
        let l = Labeler(model: FixedModel(answer: "a label that is far too long to say"), liveDir: NSTemporaryDirectory())
        _ = await l.label(session: "s", title: "Create guest confirmation email with event details")
        await l.settle()
        #expect(await l.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
        let none = Labeler(model: nil, liveDir: NSTemporaryDirectory())
        #expect(await none.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
    }

    struct SlowModel: LabelModel {
        func label(for title: String) async -> String? {
            try? await Task.sleep(for: .seconds(5))
            return "voice orchestrator"
        }
    }

    /// The directory asks for labels on every refresh: a slow model never holds one up.
    @Test func aSlowModelNeverHoldsUpALabel() async {
        let l = Labeler(model: SlowModel(), liveDir: NSTemporaryDirectory(), timeout: .milliseconds(50))
        let start = ContinuousClock.now
        #expect(await l.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
        #expect(ContinuousClock.now - start < .milliseconds(40))
        await l.settle()   // the model's time ran out: the rule label stays
        #expect(await l.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    final class CountingModel: LabelModel, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func label(for title: String) async -> String? {
            lock.withLock { n += 1 }
            return "voice orchestrator"
        }
    }

    /// The model runs once per session and title, however often the directory asks.
    @Test func theModelIsAskedOncePerTitle() async {
        let model = CountingModel()
        let l = Labeler(model: model, liveDir: NSTemporaryDirectory())
        let title = "Orchestrator agent for multi-session voice control"
        for _ in 0..<20 { _ = await l.label(session: "s", title: title) }
        await l.settle()
        for _ in 0..<20 { _ = await l.label(session: "s", title: title) }
        await l.settle()
        #expect(model.count == 1)
        // A closed session's labels are forgotten.
        await l.keep([])
        _ = await l.label(session: "s", title: title)
        await l.settle()
        #expect(model.count == 2)
    }

    /// The plugin keeps line 3 while the title is the same.
    @Test func theLabelIsWrittenToThePluginsLiveFile() async throws {
        let dir = NSTemporaryDirectory() + "ek-live-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let title = "Orchestrator agent for multi-session voice control"
        try "earshot\n\(title)\n".write(toFile: "\(dir)/s1", atomically: true, encoding: .utf8)
        try "blog\nOther title\n".write(toFile: "\(dir)/s2", atomically: true, encoding: .utf8)
        let l = Labeler(model: FixedModel(answer: "voice orchestrator"), liveDir: dir)
        _ = await l.label(session: "s1", title: title)
        _ = await l.label(session: "s2", title: "A different title than the file has now")
        await l.settle()
        #expect(try String(contentsOfFile: "\(dir)/s1", encoding: .utf8) == "earshot\n\(title)\nvoice orchestrator\n")
        #expect(try String(contentsOfFile: "\(dir)/s2", encoding: .utf8) == "blog\nOther title\n")   // stale: left alone
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/s3"))   // never created
    }
    /// L1: the plugin globs the live folder, so no temp file may sit there beside the sessions.
    @Test func noTempFileIsLeftBesideTheSessions() async throws {
        let dir = NSTemporaryDirectory() + "ek-live-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let title = "Orchestrator agent for multi-session voice control"
        try "earshot\n\(title)\n".write(toFile: "\(dir)/s1", atomically: true, encoding: .utf8)
        try "blog\nOther title\n".write(toFile: "\(dir)/s2", atomically: true, encoding: .utf8)
        let l = Labeler(model: FixedModel(answer: "voice orchestrator"), liveDir: dir)
        _ = await l.label(session: "s1", title: title)
        await l.settle()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["s1", "s2"])
    }

    /// L1: a write that cannot create its temp file leaves the folder as it was.
    @Test func aFailedWriteLeavesNoTempFile() async throws {
        let dir = NSTemporaryDirectory() + "ek-live-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let title = "Orchestrator agent for multi-session voice control"
        try "earshot\n\(title)\n".write(toFile: "\(dir)/s1", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let l = Labeler(model: FixedModel(answer: "voice orchestrator"), liveDir: dir)
        _ = await l.label(session: "s1", title: title)
        await l.settle()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["s1"])
        #expect(try String(contentsOfFile: "\(dir)/s1", encoding: .utf8) == "earshot\n\(title)\n")
    }

    /// L2: the new content is built from the text the app read, and only while line 2 is still the title.
    @Test func newLiveContentNeedsTheSameTitle() {
        #expect(Labeler.liveContent("earshot\nNew\n", title: "New", label: "x") == "earshot\nNew\nx\n")
        #expect(Labeler.liveContent("earshot\nOld\n", title: "New", label: "x") == nil)
        #expect(Labeler.liveContent("earshot\n", title: "New", label: "x") == nil)
    }

    /// L3: a title the plugin would say as more than 3 words goes to the model, as it does for the plugin.
    @Test func theLabelDecisionMatchesThePlugin() async {
        let l = Labeler(model: FixedModel(answer: "voice control"), liveDir: NSTemporaryDirectory())
        _ = await l.label(session: "s", title: "multi-session voice control")
        await l.settle()
        #expect(await l.label(session: "s", title: "multi-session voice control") == "voice control")
        let short = Labeler(model: FixedModel(answer: "should not be asked"), liveDir: NSTemporaryDirectory())
        #expect(await short.label(session: "s", title: "Fix RSS feed") == "Fix RSS feed")
    }
}
