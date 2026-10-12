import Foundation
import Testing
@testable import EarshotKit

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
        let on = try! JSONSerialization.data(withJSONObject: [["id": "earshot@earshot", "version": "0.11.0", "enabled": true]])
        #expect(PluginLink.status(fromList: on) == .connected(version: "0.11.0"))
        let off = try! JSONSerialization.data(withJSONObject: [["id": "earshot@earshot", "version": "0.12.0", "enabled": false]])
        #expect(PluginLink.status(fromList: off) == .disabled)
        let old = try! JSONSerialization.data(withJSONObject: [["id": "earshot@earshot", "version": "0.9.2", "enabled": true]])
        #expect(PluginLink.status(fromList: old) == .outdated(version: "0.9.2"))
        let other = try! JSONSerialization.data(withJSONObject: [["id": "superpowers@x", "version": "6", "enabled": true]])
        #expect(PluginLink.status(fromList: other) == .notInstalled)
        #expect(PluginLink.status(fromList: Data("nope".utf8)) == .failed("Couldn't read Claude Code's plugin list."))
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
        #expect(calls.contains("plugin install earshot@earshot --scope user"))
        let add = calls.firstIndex(of: "plugin marketplace add sdusteric/earshot")!
        let install = calls.firstIndex(of: "plugin install earshot@earshot --scope user")!
        #expect(add < install)
    }

    @Test func aKnownMarketplaceIsNotAddedAgain() async {
        let r = PluginRunner(["plugin list --json": listJSON([]),
                              "plugin marketplace list --json": listJSON([["name": "earshot"]])])
        _ = await PluginLink(runner: r).connect()
        #expect(await !r.calls.contains("plugin marketplace add sdusteric/earshot"))
    }

    @Test func aDisabledPluginIsTurnedOnNotReinstalled() async {
        let r = PluginRunner(["plugin list --json": listJSON([["id": "earshot@earshot", "version": "0.11.0", "enabled": false]])])
        _ = await PluginLink(runner: r).connect()
        let calls = await r.calls
        #expect(calls.contains("plugin enable earshot@earshot"))
        #expect(!calls.contains { $0.hasPrefix("plugin install") })
    }

    @Test func aFailedInstallSaysSo() async {
        let r = PluginRunner(["plugin list --json": listJSON([]),
                              "plugin install earshot@earshot --scope user": RunResult(status: 1)])
        #expect(await PluginLink(runner: r).connect() == .failed("Couldn't install the plugin."))
    }

    @Test func noClaudeMeansNoClaude() async {
        #expect(await PluginLink(runner: nil).check() == .noClaude)
    }
}
