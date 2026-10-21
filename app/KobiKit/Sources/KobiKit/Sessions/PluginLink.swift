import Foundation
import os

/// Whether Claude Code has the Kobi plugin, whose hooks tell the app what
/// sessions are doing. Without it voice commands still work, but nothing is
/// said about sessions and permission prompts can't be answered by voice.
public enum PluginStatus: Sendable, Equatable {
    case checking
    case connected(version: String)
    case notInstalled
    /// Installed but turned off in Claude Code.
    case disabled
    /// Older than this app needs.
    case outdated(version: String)
    /// The plugin under its old name, earshot@earshot, is still installed: its hooks
    /// would fire next to the Kobi plugin's, so it is switched for the new one.
    case renamed
    /// No `claude` command on this Mac.
    case noClaude
    /// Claude Code couldn't be asked about its plugins, or its answer couldn't be read.
    case checkFailed(String)
    /// The last install, update or turn-on failed; the text says why.
    case failed(String)

    public var isConnected: Bool { if case .connected = self { true } else { false } }

    /// One line for Settings and the panel.
    public var line: String {
        switch self {
        case .checking: "Checking Claude Code\u{2026}"
        case .connected(let v): "Connected (plugin \(v))"
        case .notInstalled: "Spoken updates and voice approvals need the Kobi plugin in Claude Code."
        case .disabled: "The Kobi plugin is turned off in Claude Code."
        case .outdated(let v): "The Kobi plugin (\(v)) is older than this app needs."
        case .renamed: "Claude Code has the Earshot plugin, this plugin's old name. Switch it for the Kobi plugin."
        case .noClaude: "Kobi couldn't find Claude Code on this Mac. Install Claude Code, then choose Check Again."
        case .checkFailed(let why), .failed(let why): why
        }
    }

    /// The action asks Claude Code again rather than changing anything.
    public var actionRechecks: Bool {
        switch self {
        case .noClaude, .checkFailed: true
        default: false
        }
    }

    /// The button that fixes it, if one can.
    public var action: String? {
        switch self {
        case .notInstalled: "Install"
        case .disabled: "Turn On"
        case .outdated: "Update"
        case .renamed: "Switch"
        case .noClaude, .checkFailed: "Check Again"
        case .failed: "Try Again"
        default: nil
        }
    }
}

/// Checks and installs the plugin through Claude Code's own `claude plugin` commands.
///
/// Claude Code names a marketplace after the `name` in its source's manifest when it is added,
/// and keeps that name: a source added before the rename stays "earshot" after its manifest says
/// "kobi", and adding it again changes nothing. Removing a marketplace uninstalls every plugin
/// from it. So the switch from the old plugin first makes sure a marketplace offers kobi (the old
/// marketplace's own source, removed and added again to take the new name, only once its manifest
/// says kobi), installs kobi from it, and only then removes earshot@earshot and its marketplace.
/// Each step checks what is there first, so Try Again picks up wherever a switch stopped.
public actor PluginLink {
    /// The oldest plugin whose messages this app understands.
    /// 0.12.0 is the first under the name Kobi.
    public static let minimumVersion = "0.12.0"
    static let pluginName = "kobi"
    static let pluginID = "kobi@kobi"
    static let marketplace = "kobi"
    /// Where the marketplace comes from when Claude Code has none to take it from: the one place
    /// the app names the GitHub repo.
    static let marketplaceSource = "sdusteric/kobi"
    /// The plugin and its marketplace under the app's old name, removed by the switch.
    static let oldPluginID = "earshot@earshot"
    static let oldMarketplace = "earshot"
    static let notPublished = "The Kobi plugin isn't published yet."

    private var runner: (any ClaudeRunner)?
    private let find: (@Sendable () async -> (any ClaudeRunner)?)?
    /// Reads a marketplace's manifest from where Claude Code keeps it.
    private let readFile: @Sendable (String) async -> Data?
    /// Whether a project folder is still there.
    private let exists: @Sendable (String) -> Bool
    /// The old marketplace's source, once read: a switch that removed the marketplace and then
    /// failed to add it again adds the same source on Try Again, not the GitHub one.
    private var oldSource: String?
    private let log = Logger(subsystem: "com.kobi.app", category: "plugin")

    static let readFromDisk: @Sendable (String) async -> Data? = { FileManager.default.contents(atPath: $0) }
    static let folderExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    /// nil runner: no `claude` was found.
    public init(runner: (any ClaudeRunner)?) {
        self.init(runner: runner, readFile: Self.readFromDisk, exists: Self.folderExists)
    }

    init(runner: (any ClaudeRunner)?, readFile: @escaping @Sendable (String) async -> Data?,
         exists: @escaping @Sendable (String) -> Bool) {
        self.runner = runner
        find = nil
        self.readFile = readFile
        self.exists = exists
    }

    /// Looks for `claude` with `find` at each check until it is found.
    public init(find: @escaping @Sendable () async -> (any ClaudeRunner)?) {
        runner = nil
        self.find = find
        readFile = Self.readFromDisk
        exists = Self.folderExists
    }

    /// The `claude` to use, looking for it again while there is none.
    private func currentRunner() async -> (any ClaudeRunner)? {
        if runner == nil, let find { runner = await find() }
        return runner
    }

    public func check() async -> PluginStatus {
        guard let runner = await currentRunner() else { return .noClaude }
        let r = await runner.run(["plugin", "list", "--json"], cwd: nil, timeout: .seconds(20))
        guard r.status == 0, !r.timedOut else { return .checkFailed("Couldn't ask Claude Code about its plugins.") }
        return Self.status(fromList: r.stdout, exists: exists)
    }

    /// Does what the status needs: adds the marketplace and installs, turns the plugin on,
    /// updates it, or switches the old plugin for it. Returns the status afterwards.
    public func connect() async -> PluginStatus {
        let before = await check()
        guard let runner else { return .noClaude }
        switch before {
        case .connected, .noClaude, .checking, .checkFailed:
            // A failed check installs nothing: only "not installed" leads to an install.
            return before
        case .disabled:
            let id = await installedKobi(runner) ?? Self.pluginID
            guard await step(runner, ["plugin", "enable", id]) else { return .failed("Couldn't turn the plugin on.") }
        case .outdated:
            let id = await installedKobi(runner) ?? Self.pluginID
            _ = await step(runner, ["plugin", "marketplace", "update", String(id.split(separator: "@").last ?? "")])
            guard await step(runner, ["plugin", "update", id]) else { return .failed("Couldn't update the plugin.") }
        case .renamed, .notInstalled, .failed:   // check() never returns .failed
            if let failure = await installKobi(runner) { return failure }
            if let failure = await removeOldPlugin(runner) { return failure }
        }
        return await check()
    }

    /// Installs kobi unless some marketplace's kobi is there already. Nil when it is there now.
    private func installKobi(_ runner: any ClaudeRunner) async -> PluginStatus? {
        if await installedKobi(runner) != nil { return nil }
        switch await kobiMarketplace(runner) {
        case .failed(let status): return status
        case .name(let name):
            guard await step(runner, ["plugin", "install", "\(Self.pluginName)@\(name)", "--scope", "user"]) else {
                return .failed("Couldn't install the plugin.")
            }
            return nil
        }
    }

    /// The name of a marketplace that offers kobi, made so when none does yet:
    /// - one named kobi;
    /// - else the old marketplace, once its source's manifest offers kobi: removed and added again
    ///   from the same source so it takes the name kobi (kept as it is while another plugin of
    ///   its own uses it). Its source not offering kobi yet (not merged or pushed) changes nothing.
    /// - else the old marketplace's source as read before, or the GitHub repo. A source that
    ///   still says earshot is taken out again.
    private func kobiMarketplace(_ runner: any ClaudeRunner) async -> Found {
        let markets = await marketplaces(runner)
        if markets.contains(where: { $0.name == Self.marketplace }) { return .name(Self.marketplace) }
        if let old = markets.first(where: { $0.name == Self.oldMarketplace }) {
            oldSource = old.source ?? oldSource
            // A git source is a clone: bring it up to date. A folder is read as it is.
            _ = await step(runner, ["plugin", "marketplace", "update", Self.oldMarketplace])
            guard await offersKobi(old) else {
                log.info("the old marketplace's source doesn't offer the kobi plugin yet")
                return .failed(.failed(Self.notPublished))
            }
            let plugins = await installedIDs(runner)
            if plugins.contains(where: { $0 != Self.oldPluginID && $0.hasSuffix("@" + Self.oldMarketplace) }) {
                return .name(Self.oldMarketplace)
            }
            guard let source = oldSource else { return .name(Self.oldMarketplace) }
            // Removing it uninstalls earshot@earshot too, whose source no longer offers it.
            guard await step(runner, ["plugin", "marketplace", "remove", Self.oldMarketplace]) else {
                return .failed(.failed("Couldn't remove the Earshot plugin source from Claude Code."))
            }
            if await add(runner, source) { return .name(Self.marketplace) }
            // Put it back, so a plugin source is there, then say so.
            if await add(runner, source) { return .name(Self.marketplace) }
            return .failed(.failed("Couldn't add the Kobi plugin source."))
        }
        let source = oldSource ?? Self.marketplaceSource
        if await add(runner, source) { return .name(Self.marketplace) }
        // Added under another name: the source doesn't offer kobi yet. Nothing used it before.
        let now = await marketplaces(runner)
        if let wrong = now.first(where: { $0.source == source && !markets.map(\.name).contains($0.name) }) {
            _ = await step(runner, ["plugin", "marketplace", "remove", wrong.name])
            return .failed(.failed(Self.notPublished))
        }
        return .failed(.failed(source == Self.marketplaceSource
            ? "Couldn't add the Kobi plugin source. Check your internet connection." : "Couldn't add the Kobi plugin source."))
    }

    /// What kobiMarketplace found: the marketplace to install from, or why there is none.
    private enum Found { case name(String), failed(PluginStatus) }

    /// Adds a marketplace from `source`; true when one named kobi is there afterwards.
    private func add(_ runner: any ClaudeRunner, _ source: String) async -> Bool {
        _ = await step(runner, ["plugin", "marketplace", "add", source])
        return await marketplaces(runner).contains { $0.name == Self.marketplace }
    }

    /// Uninstalls earshot@earshot from each scope it is in (not a project whose folder is gone),
    /// then removes the old marketplace when no other installed plugin comes from it.
    /// Nil when it is gone.
    private func removeOldPlugin(_ runner: any ClaudeRunner) async -> PluginStatus? {
        for entry in await list(runner) where (entry["id"] as? String) == Self.oldPluginID && Self.counts(entry, exists) {
            let scope = entry["scope"] as? String ?? "user"
            guard await step(runner, ["plugin", "uninstall", Self.oldPluginID, "--scope", scope],
                             cwd: entry["projectPath"] as? String) else {
                return .failed("Couldn't remove the Earshot plugin from Claude Code.")
            }
        }
        let others = await installedIDs(runner).contains { $0.hasSuffix("@" + Self.oldMarketplace) }
        if !others, await marketplaces(runner).contains(where: { $0.name == Self.oldMarketplace }) {
            _ = await step(runner, ["plugin", "marketplace", "remove", Self.oldMarketplace])
        }
        return nil
    }

    /// A marketplace as `plugin marketplace list --json` gives it.
    struct Marketplace {
        let name: String
        /// What `plugin marketplace add` takes to add it again: the folder, the GitHub repo or the URL.
        let source: String?
        /// Where Claude Code keeps it (the folder itself for a folder).
        let location: String?
    }

    private func marketplaces(_ runner: any ClaudeRunner) async -> [Marketplace] {
        let r = await runner.run(["plugin", "marketplace", "list", "--json"], cwd: nil, timeout: .seconds(20))
        guard r.status == 0, let list = try? JSONSerialization.jsonObject(with: r.stdout) as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let name = e["name"] as? String else { return nil }
            let source: String? = switch e["source"] as? String {
            case "github"?: e["repo"] as? String
            case "directory"?, "file"?: e["path"] as? String
            default: e["url"] as? String ?? e["repo"] as? String ?? e["path"] as? String
            }
            return Marketplace(name: name, source: source, location: e["installLocation"] as? String ?? e["path"] as? String)
        }
    }

    /// The marketplace's manifest lists a plugin named kobi.
    private func offersKobi(_ m: Marketplace) async -> Bool {
        guard let location = m.location else { return false }
        let path = location.hasSuffix(".json") ? location : location + "/.claude-plugin/marketplace.json"
        guard let data = await readFile(path), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = manifest["plugins"] as? [[String: Any]] else { return false }
        return plugins.contains { ($0["name"] as? String) == Self.pluginName }
    }

    private func list(_ runner: any ClaudeRunner) async -> [[String: Any]] {
        let r = await runner.run(["plugin", "list", "--json"], cwd: nil, timeout: .seconds(20))
        return (try? JSONSerialization.jsonObject(with: r.stdout) as? [[String: Any]]) ?? []
    }

    private func installedIDs(_ runner: any ClaudeRunner) async -> [String] {
        await list(runner).compactMap { $0["id"] as? String }
    }

    /// The id of the kobi plugin installed from any marketplace, if one is.
    private func installedKobi(_ runner: any ClaudeRunner) async -> String? {
        Self.kobiEntry(in: await list(runner), exists).flatMap { $0["id"] as? String }
    }

    private func step(_ runner: any ClaudeRunner, _ args: [String], cwd: String? = nil) async -> Bool {
        let r = await runner.run(args, cwd: cwd, timeout: .seconds(180))
        if r.status != 0 || r.timedOut {
            log.error("claude \(args.prefix(3).joined(separator: " "), privacy: .public) failed: \(r.status)")
            return false
        }
        return true
    }

    /// An entry of the list that does something: not one installed in a project whose folder is
    /// gone, which Claude Code can't uninstall and no session loads.
    static func counts(_ entry: [String: Any], _ exists: (String) -> Bool) -> Bool {
        guard (entry["scope"] as? String) == "project" || (entry["scope"] as? String) == "local",
              let folder = entry["projectPath"] as? String else { return true }
        return exists(folder)
    }

    /// The kobi plugin from any marketplace (kobi@kobi first).
    static func kobiEntry(in list: [[String: Any]], _ exists: (String) -> Bool) -> [String: Any]? {
        let kobi = list.filter { (($0["id"] as? String)?.split(separator: "@").first).map(String.init) == pluginName && counts($0, exists) }
        return kobi.first { ($0["id"] as? String) == pluginID } ?? kobi.first
    }

    /// Reads `claude plugin list --json`.
    static func status(fromList data: Data, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> PluginStatus {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .checkFailed("Couldn't read Claude Code's plugin list.")
        }
        // The old plugin's hooks would run next to the new one's: it goes first.
        if list.contains(where: { ($0["id"] as? String) == oldPluginID && counts($0, exists) }) { return .renamed }
        guard let entry = kobiEntry(in: list, exists) else { return .notInstalled }
        let version = entry["version"] as? String ?? "?"
        if (entry["enabled"] as? Bool) == false { return .disabled }
        if isOlder(version, than: minimumVersion) { return .outdated(version: version) }
        return .connected(version: version)
    }

    /// Dotted numeric versions, "0.9.2" < "0.11.0". Unreadable parts count as 0.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }
}
