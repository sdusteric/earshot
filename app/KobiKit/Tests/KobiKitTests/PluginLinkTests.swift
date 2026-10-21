import Foundation
import Synchronization
import Testing
@testable import KobiKit

/// Answers `claude plugin ...` calls from a script, by the joined arguments.
actor PluginRunner: ClaudeRunner {
    var answers: [String: RunResult]
    private(set) var calls: [String] = []
    init(_ answers: [String: RunResult]) { self.answers = answers }
    func set(_ key: String, _ r: RunResult) { answers[key] = r }
    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        let key = args.joined(separator: " ")
        calls.append(key)
        return answers[key] ?? RunResult(status: 0, stdout: Data("[]".utf8))
    }
    func version() async -> String? { "2.1.296" }
}

func listJSON(_ entries: [[String: Any]]) -> RunResult {
    RunResult(status: 0, stdout: try! JSONSerialization.data(withJSONObject: entries))
}

@Suite struct PluginLinkTests {
    @Test func readsTheList() {
        let on = try! JSONSerialization.data(withJSONObject: [["id": "kobi@kobi", "version": "0.12.0", "enabled": true]])
        #expect(PluginLink.status(fromList: on) == .connected(version: "0.12.0"))
        let off = try! JSONSerialization.data(withJSONObject: [["id": "kobi@kobi", "version": "0.12.0", "enabled": false]])
        #expect(PluginLink.status(fromList: off) == .disabled)
        let old = try! JSONSerialization.data(withJSONObject: [["id": "kobi@kobi", "version": "0.9.2", "enabled": true]])
        #expect(PluginLink.status(fromList: old) == .outdated(version: "0.9.2"))
        let other = try! JSONSerialization.data(withJSONObject: [["id": "superpowers@x", "version": "6", "enabled": true]])
        #expect(PluginLink.status(fromList: other) == .notInstalled)
        #expect(PluginLink.status(fromList: Data("nope".utf8)) == .checkFailed("Couldn't read Claude Code's plugin list."))
    }

    /// The plugin under the app's old name, alone or next to the new one, needs the switch.
    @Test func theOldPluginNeedsTheSwitch() {
        let old: [String: Any] = ["id": "earshot@earshot", "version": "0.11.0", "enabled": true, "scope": "user"]
        let new: [String: Any] = ["id": "kobi@kobi", "version": "0.12.0", "enabled": true, "scope": "user"]
        #expect(PluginLink.status(fromList: try! JSONSerialization.data(withJSONObject: [old])) == .renamed)
        #expect(PluginLink.status(fromList: try! JSONSerialization.data(withJSONObject: [old, new])) == .renamed)
        #expect(PluginStatus.renamed.action == "Switch" && !PluginStatus.renamed.actionRechecks)
    }

    static var old: [String: Any] { ["id": "earshot@earshot", "version": "0.11.0", "enabled": true, "scope": "user"] }
    static var new: [String: Any] { ["id": "kobi@kobi", "version": "0.12.0", "enabled": true, "scope": "user"] }
    static let repo = "/Users/me/Projects/earshot"
    static let notPublished = PluginStatus.failed("The Kobi plugin isn't published yet.")

    /// Before the push (or, for the repo folder, before the merge) the old marketplace's source
    /// offers only earshot: the switch touches nothing, so the old plugin keeps working.
    @Test(arguments: [repo, "sdusteric/kobi"])
    func theSwitchBeforeTheSourceOffersKobiChangesNothing(_ source: String) async {
        let c = FakeClaude(plugins: [Self.old], added: [("earshot", source)], sources: Dictionary([(source, .earshot), ("sdusteric/kobi", .earshot)]) { a, _ in a })
        #expect(await PluginLink(c).connect() == Self.notPublished)
        #expect(await c.installed == ["earshot@earshot"])
        #expect(await c.marketplaces == ["earshot"])
        #expect(await !c.calls.contains { $0.hasPrefix("plugin uninstall") || $0.hasPrefix("plugin marketplace remove") || $0.hasPrefix("plugin marketplace add") })
        #expect(Self.notPublished.action == "Try Again")
    }

    /// After the merge the repo folder offers kobi, but Claude Code keeps the marketplace's first
    /// name: it is removed and added again from the same folder, so it is named kobi, and the
    /// plugin keeps being read from the folder (not a GitHub clone).
    @Test func theSwitchReAddsTheOldMarketplacesOwnSource() async {
        let c = FakeClaude(plugins: [Self.old], added: [("earshot", Self.repo)],
                           sources: [Self.repo: .kobi, "sdusteric/kobi": .kobi])
        #expect(await PluginLink(c).connect() == .connected(version: "0.12.0"))
        #expect(await c.installed == ["kobi@kobi"])
        #expect(await c.added.map(\.source) == [Self.repo])
        #expect(await c.marketplaces == ["kobi"])
        #expect(await !c.calls.contains("plugin marketplace add sdusteric/kobi"))
    }

    /// A GitHub source after the push: the same, from the repo.
    @Test func theSwitchFromGitHubAfterThePush() async {
        let c = FakeClaude(plugins: [Self.old], added: [("earshot", "sdusteric/kobi")], sources: ["sdusteric/kobi": .kobi])
        #expect(await PluginLink(c).connect() == .connected(version: "0.12.0"))
        #expect(await c.installed == ["kobi@kobi"])
        #expect(await c.added.map(\.source) == ["sdusteric/kobi"])
        // The clone is brought up to date before its manifest is read.
        let calls = await c.calls
        #expect(calls.firstIndex(of: "plugin marketplace update earshot")! < calls.firstIndex(of: "plugin marketplace remove earshot")!)
    }

    /// The old marketplace removed and the add failed: the source is added back, and Try Again
    /// (the status is now not installed, since the removal took the old plugin with it) adds the
    /// same source, not the GitHub one.
    @Test func aFailedAddIsUndoneAndTryAgainUsesTheSameSource() async {
        let c = FakeClaude(plugins: [Self.old], added: [("earshot", Self.repo)], sources: [Self.repo: .kobi, "sdusteric/kobi": .earshot],
                           failing: ["plugin marketplace add \(Self.repo)"])
        let link = PluginLink(c)
        #expect(await link.connect() == .failed("Couldn't add the Kobi plugin source."))
        #expect(await c.calls.filter { $0 == "plugin marketplace add \(Self.repo)" }.count == 2)
        await c.fail("plugin marketplace add \(Self.repo)", false)
        #expect(await link.check() == .notInstalled)
        #expect(await link.connect() == .connected(version: "0.12.0"))
        #expect(await c.added.map(\.source) == [Self.repo])
        #expect(await c.marketplaces == ["kobi"])
    }

    /// Kobi installed and the old plugin not removed yet (a switch cut short): only the old one goes.
    @Test func theSwitchNextToTheNewPluginOnlyRemovesTheOld() async {
        let c = FakeClaude(plugins: [Self.old, Self.new], added: [("earshot", "sdusteric/kobi"), ("kobi", Self.repo)],
                           sources: [Self.repo: .kobi, "sdusteric/kobi": .earshot])
        #expect(await PluginLink(c).connect() == .connected(version: "0.12.0"))
        #expect(await c.installed == ["kobi@kobi"])
        #expect(await c.marketplaces == ["kobi"])
        #expect(await !c.calls.contains { $0.hasPrefix("plugin install") || $0.hasPrefix("plugin marketplace add") })
    }

    /// Kobi installed from the old marketplace (kobi@earshot): the old plugin goes, the marketplace
    /// stays, since removing it would take kobi with it.
    @Test func kobiFromTheOldMarketplaceKeepsIt() async {
        let fromOld: [String: Any] = ["id": "kobi@earshot", "version": "0.12.0", "enabled": true, "scope": "user"]
        let c = FakeClaude(plugins: [Self.old, fromOld], added: [("earshot", Self.repo)], sources: [Self.repo: .kobi])
        #expect(await PluginLink(c).connect() == .connected(version: "0.12.0"))
        #expect(await c.installed == ["kobi@earshot"])
        #expect(await c.marketplaces == ["earshot"])
    }

    /// Another plugin from the old marketplace keeps it: kobi is installed from it as it is.
    @Test func theOldMarketplaceStaysWhileAnotherPluginUsesIt() async {
        let helper: [String: Any] = ["id": "helper@earshot", "version": "1", "enabled": true, "scope": "user"]
        var both = FakeClaude.Manifest.kobi
        both.plugins["helper"] = "1"
        let c = FakeClaude(plugins: [Self.old, helper], added: [("earshot", Self.repo)], sources: [Self.repo: both])
        #expect(await PluginLink(c).connect() == .connected(version: "0.12.0"))
        #expect(await c.installed == ["helper@earshot", "kobi@earshot"])
        #expect(await !c.calls.contains { $0.hasPrefix("plugin marketplace remove") })
    }

    /// A failed uninstall of the old plugin leaves kobi installed: Try Again only removes the old one.
    @Test func aFailedUninstallKeepsKobiAndTryAgainFinishes() async {
        let c = FakeClaude(plugins: [Self.old, Self.new], added: [("earshot", "sdusteric/kobi"), ("kobi", Self.repo)],
                           sources: [Self.repo: .kobi, "sdusteric/kobi": .earshot],
                           failing: ["plugin uninstall earshot@earshot --scope user"])
        let link = PluginLink(c)
        #expect(await link.connect() == .failed("Couldn't remove the Earshot plugin from Claude Code."))
        #expect(await c.installed.contains("kobi@kobi"))
        await c.fail("plugin uninstall earshot@earshot --scope user", false)
        #expect(await link.connect() == .connected(version: "0.12.0"))
    }

    /// Nothing installed and no marketplace: GitHub before the push adds a marketplace named
    /// earshot, which is taken out again, and the status says so.
    @Test func installBeforeThePushLeavesNothingBehind() async {
        let c = FakeClaude(plugins: [], added: [], sources: ["sdusteric/kobi": .earshot])
        #expect(await PluginLink(c).connect() == Self.notPublished)
        #expect(await c.marketplaces == [])
        #expect(await c.installed == [])
    }

    @Test func installAddsTheMarketplaceFirstWhenItIsMissing() async {
        let c = FakeClaude(plugins: [], added: [], sources: ["sdusteric/kobi": .kobi])
        #expect(await PluginLink(c).connect() == .connected(version: "0.12.0"))
        let calls = await c.calls
        let add = calls.firstIndex(of: "plugin marketplace add sdusteric/kobi")!
        let install = calls.firstIndex(of: "plugin install kobi@kobi --scope user")!
        #expect(add < install)
    }

    @Test func aKnownMarketplaceIsNotAddedAgain() async {
        let c = FakeClaude(plugins: [], added: [("kobi", Self.repo)], sources: [Self.repo: .kobi])
        #expect(await PluginLink(c).connect() == .connected(version: "0.12.0"))
        #expect(await !c.calls.contains { $0.hasPrefix("plugin marketplace add") })
    }

    @Test func aFailedInstallSaysSo() async {
        let c = FakeClaude(plugins: [], added: [("kobi", Self.repo)], sources: [Self.repo: .kobi],
                           failing: ["plugin install kobi@kobi --scope user"])
        #expect(await PluginLink(c).connect() == .failed("Couldn't install the plugin."))
    }

    /// Kobi from any marketplace is the plugin: Install never adds a second copy, and Turn On and
    /// Update act on the one there is.
    @Test func kobiFromAnyMarketplaceCounts() async {
        let other: [String: Any] = ["id": "kobi@earshot", "version": "0.12.0", "enabled": true, "scope": "user"]
        #expect(PluginLink.status(fromList: try! JSONSerialization.data(withJSONObject: [other])) == .connected(version: "0.12.0"))
        var off = other
        off["enabled"] = false
        let c = FakeClaude(plugins: [off], added: [("earshot", Self.repo)], sources: [Self.repo: .kobi])
        _ = await PluginLink(c).connect()
        let calls = await c.calls
        #expect(calls.contains("plugin enable kobi@earshot"))
        #expect(!calls.contains { $0.hasPrefix("plugin install") || $0.hasPrefix("plugin marketplace add") })
    }

    /// A project-scope earshot@earshot whose project folder is gone can't be uninstalled, and
    /// does nothing: it is ignored.
    @Test func anOldPluginInAGoneProjectIsIgnored() async {
        var gone = Self.old
        gone["scope"] = "project"
        gone["projectPath"] = "/Users/me/gone"
        let list = try! JSONSerialization.data(withJSONObject: [gone, Self.new])
        let exists: @Sendable (String) -> Bool = { $0 != "/Users/me/gone" }
        #expect(PluginLink.status(fromList: list, exists: exists) == .connected(version: "0.12.0"))
        #expect(PluginLink.status(fromList: try! JSONSerialization.data(withJSONObject: [gone]), exists: exists) == .notInstalled)
        #expect(PluginLink.status(fromList: list, exists: { _ in true }) == .renamed)
    }

    @Test func versionsCompareByNumber() {
        #expect(PluginLink.isOlder("0.9.2", than: "0.11.0"))
        #expect(!PluginLink.isOlder("0.11.0", than: "0.11.0"))
        #expect(!PluginLink.isOlder("1.0", than: "0.11.0"))
    }

    @Test func aDisabledPluginIsTurnedOnNotReinstalled() async {
        let r = PluginRunner(["plugin list --json": listJSON([["id": "kobi@kobi", "version": "0.12.0", "enabled": false]])])
        _ = await PluginLink(runner: r).connect()
        let calls = await r.calls
        #expect(calls.contains("plugin enable kobi@kobi"))
        #expect(!calls.contains { $0.hasPrefix("plugin install") })
    }

    @Test func noClaudeMeansNoClaude() async {
        #expect(await PluginLink(runner: nil).check() == .noClaude)
        #expect(PluginStatus.noClaude.action == "Check Again")
        #expect(PluginStatus.noClaude.actionRechecks)
    }

    /// Claude Code installed after Kobi opened is found at the next check.
    @Test func claudeIsLookedForAgainUntilFound() async {
        let r = PluginRunner(["plugin list --json": listJSON([])])
        let found = Mutex(false)
        let link = PluginLink(find: { found.withLock { $0 } ? r : nil })
        #expect(await link.check() == .noClaude)
        found.withLock { $0 = true }
        #expect(await link.check() == .notInstalled)
    }

    /// Try Again after a failed `plugin list` asks again; it never installs on a guess.
    @Test func aFailedCheckInstallsNothing() async {
        let r = PluginRunner(["plugin list --json": RunResult(status: 1)])
        let status = await PluginLink(runner: r).connect()
        #expect(status == .checkFailed("Couldn't ask Claude Code about its plugins."))
        #expect(status.action == "Check Again" && status.actionRechecks)
        #expect(await r.calls == ["plugin list --json"])
    }

    @Test func aFailedInstallIsTriedAgainNotRechecked() {
        #expect(PluginStatus.failed("Couldn't install the plugin.").action == "Try Again")
        #expect(!PluginStatus.failed("Couldn't install the plugin.").actionRechecks)
    }
}

/// `claude plugin` with state, by the rules Claude Code 2.1.302 follows (checked against the real CLI
/// with a throwaway HOME): a marketplace is named after the `name` in its source's manifest when it
/// is added, and keeps that name; adding a source already known succeeds and changes nothing;
/// removing a marketplace uninstalls every plugin from it; a plugin installs only from a marketplace
/// whose source's manifest offers it now. `sources` is each source's manifest: its name and the
/// plugins it offers with their versions, which a test changes to stand for a merge or a push.
actor FakeClaude: ClaudeRunner {
    struct Manifest { var name: String; var plugins: [String: String] }
    var plugins: [[String: Any]]
    /// The marketplaces added, in order: the name they took, and their source.
    var added: [(name: String, source: String)]
    var sources: [String: Manifest]
    var failing: Set<String>
    private(set) var calls: [String] = []

    init(plugins: [[String: Any]], added: [(name: String, source: String)], sources: [String: Manifest],
         failing: Set<String> = []) {
        self.plugins = plugins
        self.added = added
        self.sources = sources
        self.failing = failing
    }

    var marketplaces: [String] { added.map(\.name) }
    var installed: [String] { plugins.compactMap { $0["id"] as? String } }
    func set(_ source: String, _ m: Manifest) { sources[source] = m }
    func fail(_ key: String, _ on: Bool = true) { if on { failing.insert(key) } else { failing.remove(key) } }

    /// Where a marketplace's manifest is, as `plugin marketplace list --json` gives installLocation.
    static func location(_ name: String) -> String { "/fake/marketplaces/\(name)" }

    /// The manifest file at `path`, as the source of the marketplace there says now.
    func file(_ path: String) -> Data? {
        guard let m = added.first(where: { path == Self.location($0.name) + "/.claude-plugin/marketplace.json" }),
              let manifest = sources[m.source] else { return nil }
        let entries = manifest.plugins.keys.sorted().map { ["name": $0, "source": "./plugin"] }
        return try? JSONSerialization.data(withJSONObject: ["name": manifest.name, "plugins": entries])
    }

    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        let key = args.joined(separator: " ")
        calls.append(key)
        if failing.contains(key) { return RunResult(status: 1) }
        let ok = RunResult(status: 0, stdout: Data("[]".utf8))
        switch Array(args.prefix(3)) {
        case ["plugin", "list", "--json"]: return listJSON(plugins)
        case ["plugin", "marketplace", "list"]:
            return listJSON(added.map { m in
                var e: [String: Any] = ["name": m.name, "installLocation": Self.location(m.name)]
                if m.source.hasPrefix("/") { e["source"] = "directory"; e["path"] = m.source } else { e["source"] = "github"; e["repo"] = m.source }
                return e
            })
        case ["plugin", "marketplace", "add"]:
            let source = args[3]
            guard !added.contains(where: { $0.source == source }) else { return ok }   // "already on disk"
            guard let m = sources[source], !added.contains(where: { $0.name == m.name }) else { return RunResult(status: 1) }
            added.append((m.name, source))
        case ["plugin", "marketplace", "remove"]:
            guard added.contains(where: { $0.name == args[3] }) else { return RunResult(status: 1) }
            added.removeAll { $0.name == args[3] }
            plugins.removeAll { ($0["id"] as? String)?.hasSuffix("@" + args[3]) == true }
        case ["plugin", "marketplace", "update"]: return ok
        case _ where args.starts(with: ["plugin", "install"]):
            let id = args[2].split(separator: "@").map(String.init)
            guard id.count == 2, let m = added.first(where: { $0.name == id[1] }),
                  let version = sources[m.source]?.plugins[id[0]] else { return RunResult(status: 1) }
            plugins.removeAll { ($0["id"] as? String) == args[2] }
            plugins.append(["id": args[2], "version": version, "enabled": true, "scope": "user"])
        case _ where args.starts(with: ["plugin", "uninstall"]):
            guard plugins.contains(where: { ($0["id"] as? String) == args[2] }) else { return RunResult(status: 1) }
            plugins.removeAll { ($0["id"] as? String) == args[2] }
        default: break
        }
        return ok
    }
    func version() async -> String? { "2.1.302" }
}

extension FakeClaude.Manifest {
    /// The repo before the rename, and after it.
    static let earshot = Self(name: "earshot", plugins: ["earshot": "0.11.0"])
    static let kobi = Self(name: "kobi", plugins: ["kobi": "0.12.0"])
}

extension PluginLink {
    /// A link to the fake, which reads its manifests from it.
    init(_ fake: FakeClaude, exists: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.init(runner: fake, readFile: { await fake.file($0) }, exists: exists)
    }
}
