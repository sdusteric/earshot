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

    @Test func theSwitchRemovesTheOldPluginAndItsMarketplaceBeforeInstalling() async {
        let c = FakeClaude(plugins: [["id": "earshot@earshot", "version": "0.11.0", "enabled": true, "scope": "user"]],
                           marketplaces: ["earshot"])
        #expect(await PluginLink(runner: c).connect() == .connected(version: "0.12.0"))
        let calls = await c.calls
        let order = ["plugin uninstall earshot@earshot --scope user", "plugin marketplace remove earshot",
                     "plugin marketplace add sdusteric/earshot", "plugin install kobi@kobi --scope user"]
        let at = order.map { calls.firstIndex(of: $0) }
        #expect(!at.contains(nil))
        #expect(at.compactMap { $0 } == at.compactMap { $0 }.sorted())
        #expect(await c.marketplaces == ["kobi"])
    }

    /// Another plugin from the old marketplace keeps it.
    @Test func theOldMarketplaceStaysWhileAnotherPluginUsesIt() async {
        let c = FakeClaude(plugins: [["id": "earshot@earshot", "version": "0.11.0", "enabled": true, "scope": "user"],
                                     ["id": "helper@earshot", "version": "1", "enabled": true, "scope": "user"]],
                           marketplaces: ["earshot"])
        _ = await PluginLink(runner: c).connect()
        let calls = await c.calls
        #expect(calls.contains("plugin uninstall earshot@earshot --scope user"))
        #expect(!calls.contains { $0.hasPrefix("plugin marketplace remove") })
    }

    /// With the new plugin there already, the switch only removes the old one.
    @Test func theSwitchNextToTheNewPluginOnlyRemovesTheOld() async {
        let c = FakeClaude(plugins: [["id": "earshot@earshot", "version": "0.11.0", "enabled": true, "scope": "user"],
                                     ["id": "kobi@kobi", "version": "0.12.0", "enabled": true, "scope": "user"]],
                           marketplaces: ["earshot", "kobi"])
        #expect(await PluginLink(runner: c).connect() == .connected(version: "0.12.0"))
        #expect(await !c.calls.contains { $0.hasPrefix("plugin install") })
    }

    @Test func aFailedUninstallInstallsNothing() async {
        let c = FakeClaude(plugins: [["id": "earshot@earshot", "version": "0.11.0", "enabled": true, "scope": "user"]],
                           marketplaces: ["earshot"], failing: ["plugin uninstall earshot@earshot --scope user"])
        #expect(await PluginLink(runner: c).connect() == .failed("Couldn't remove the Earshot plugin from Claude Code."))
        #expect(await !c.calls.contains { $0.hasPrefix("plugin install") })
    }

    @Test func versionsCompareByNumber() {
        #expect(PluginLink.isOlder("0.9.2", than: "0.11.0"))
        #expect(!PluginLink.isOlder("0.11.0", than: "0.11.0"))
        #expect(!PluginLink.isOlder("1.0", than: "0.11.0"))
    }

    @Test func installAddsTheMarketplaceFirstWhenItIsMissing() async {
        let r = PluginRunner(["plugin list --json": listJSON([])])
        let link = PluginLink(runner: r)
        _ = await link.connect()
        let calls = await r.calls
        #expect(calls.contains("plugin marketplace add sdusteric/earshot"))
        #expect(calls.contains("plugin install kobi@kobi --scope user"))
        let add = calls.firstIndex(of: "plugin marketplace add sdusteric/earshot")!
        let install = calls.firstIndex(of: "plugin install kobi@kobi --scope user")!
        #expect(add < install)
    }

    @Test func aKnownMarketplaceIsNotAddedAgain() async {
        let r = PluginRunner(["plugin list --json": listJSON([]),
                              "plugin marketplace list --json": listJSON([["name": "kobi"]])])
        _ = await PluginLink(runner: r).connect()
        #expect(await !r.calls.contains("plugin marketplace add sdusteric/earshot"))
    }

    @Test func aDisabledPluginIsTurnedOnNotReinstalled() async {
        let r = PluginRunner(["plugin list --json": listJSON([["id": "kobi@kobi", "version": "0.12.0", "enabled": false]])])
        _ = await PluginLink(runner: r).connect()
        let calls = await r.calls
        #expect(calls.contains("plugin enable kobi@kobi"))
        #expect(!calls.contains { $0.hasPrefix("plugin install") })
    }

    @Test func aFailedInstallSaysSo() async {
        let r = PluginRunner(["plugin list --json": listJSON([]),
                              "plugin install kobi@kobi --scope user": RunResult(status: 1)])
        #expect(await PluginLink(runner: r).connect() == .failed("Couldn't install the plugin."))
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

/// `claude plugin` with state: what is installed and which marketplaces there are, changed
/// by install, uninstall and marketplace add and remove.
actor FakeClaude: ClaudeRunner {
    var plugins: [[String: Any]]
    var marketplaces: [String]
    let failing: Set<String>
    private(set) var calls: [String] = []

    init(plugins: [[String: Any]], marketplaces: [String], failing: Set<String> = []) {
        self.plugins = plugins
        self.marketplaces = marketplaces
        self.failing = failing
    }

    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        let key = args.joined(separator: " ")
        calls.append(key)
        if failing.contains(key) { return RunResult(status: 1) }
        switch key {
        case "plugin list --json": return listJSON(plugins)
        case "plugin marketplace list --json": return listJSON(marketplaces.map { ["name": $0] })
        case "plugin marketplace add sdusteric/earshot": marketplaces.append("kobi")
        case "plugin install kobi@kobi --scope user":
            plugins.append(["id": "kobi@kobi", "version": "0.12.0", "enabled": true, "scope": "user"])
        default:
            if args.starts(with: ["plugin", "uninstall"]) { plugins.removeAll { ($0["id"] as? String) == args[2] } }
            if args.starts(with: ["plugin", "marketplace", "remove"]) { marketplaces.removeAll { $0 == args[3] } }
        }
        return RunResult(status: 0, stdout: Data("[]".utf8))
    }
    func version() async -> String? { "2.1.296" }
}
