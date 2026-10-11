import Foundation
import Testing
@testable import EarshotKit

@Suite struct SpokenNamesTests {
    @Test(arguments: [
        ("/Users/me/code/billing_service", "billing service"),
        ("/Users/me/code/billingService", "billing Service"),
        ("/Users/me/code/finebrief.app", "finebrief app"),
        ("/Users/me/code/billing-service/src/api", "billing service"),   // the git root
        ("/Users/me", "your home folder"),
    ])
    func projectNames(_ cwd: String, _ expected: String) {
        let roots: Set<String> = ["/Users/me/code/billing-service", "/Users/me/code/billing_service",
                                  "/Users/me/code/billingService", "/Users/me/code/finebrief.app"]
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
                                   .init(id: "b", project: "blog", title: "", label: "")])
        #expect(n["a"] == "billing service")
        #expect(n["b"] == "blog")
    }

    @Test func theLabelWhenTwoShareAProject() {
        let n = SpokenNames.names([.init(id: "a", project: "billing service", title: "Fix refund rounding", label: "refund rounding"),
                                   .init(id: "b", project: "billing service", title: "Invoice export", label: "invoices")])
        #expect(n["a"] == "the refund rounding session")
        #expect(n["b"] == "the invoices session")
    }

    @Test func labelAndProjectWhenTheLabelClashes() {
        let n = SpokenNames.names([.init(id: "a", project: "billing service", title: "Tests", label: "tests"),
                                   .init(id: "b", project: "billing service", title: "Docs", label: "docs"),
                                   .init(id: "c", project: "blog", title: "Tests", label: "Tests")])
        #expect(n["a"] == "tests in billing service")
        #expect(n["b"] == "the docs session")
        #expect(n["c"] == "blog")   // the only blog session
    }

    @Test func aSessionWithoutATitleIsItsProject() {
        let n = SpokenNames.names([.init(id: "a", project: "blog", title: "", label: ""),
                                   .init(id: "b", project: "blog", title: "Fix RSS", label: "Fix RSS")])
        #expect(n["a"] == "blog")
        #expect(n["b"] == "the Fix RSS session")
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

    @Test func theModelShortensLongTitles() async {
        let l = Labeler(model: FixedModel(answer: "voice orchestrator"), liveDir: NSTemporaryDirectory())
        #expect(await l.label(session: "s", title: "Orchestrator agent for multi-session voice control") == "voice orchestrator")
    }

    @Test func aBadModelAnswerFallsBackToTheRule() async {
        let l = Labeler(model: FixedModel(answer: "a label that is far too long to say"), liveDir: NSTemporaryDirectory())
        #expect(await l.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
        let none = Labeler(model: nil, liveDir: NSTemporaryDirectory())
        #expect(await none.label(session: "s", title: "Create guest confirmation email with event details") == "guest confirmation email")
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
        #expect(await l.label(session: "s", title: "multi-session voice control") == "voice control")
        let short = Labeler(model: FixedModel(answer: "should not be asked"), liveDir: NSTemporaryDirectory())
        #expect(await short.label(session: "s", title: "Fix RSS feed") == "Fix RSS feed")
    }
}
