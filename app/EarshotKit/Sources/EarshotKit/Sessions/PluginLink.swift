import Foundation
import os

/// Whether Claude Code has the Earshot plugin, whose hooks tell the app what
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
        case .notInstalled: "Spoken updates and voice approvals need the Earshot plugin in Claude Code."
        case .disabled: "The Earshot plugin is turned off in Claude Code."
        case .outdated(let v): "The Earshot plugin (\(v)) is older than this app needs."
        case .noClaude: "Earshot couldn't find Claude Code on this Mac. Install Claude Code, then choose Check Again."
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
        case .noClaude, .checkFailed: "Check Again"
        case .failed: "Try Again"
        default: nil
        }
    }
}

/// Checks and installs the plugin through Claude Code's own `claude plugin` commands.
public actor PluginLink {
    /// The oldest plugin whose messages this app understands.
    public static let minimumVersion = "0.11.0"
    static let pluginID = "earshot@earshot"
    static let marketplace = "earshot"
    /// Where the marketplace comes from when it isn't added yet.
    static let marketplaceSource = "sdusteric/earshot"

    private var runner: (any ClaudeRunner)?
    private let find: (@Sendable () async -> (any ClaudeRunner)?)?
    private let log = Logger(subsystem: "com.earshot.app", category: "plugin")

    /// nil runner: no `claude` was found.
    public init(runner: (any ClaudeRunner)?) {
        self.runner = runner
        find = nil
    }

    /// Looks for `claude` with `find` at each check until it is found.
    public init(find: @escaping @Sendable () async -> (any ClaudeRunner)?) {
        runner = nil
        self.find = find
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
        return Self.status(fromList: r.stdout)
    }

    /// Does what the status needs: adds the marketplace and installs, turns the
    /// plugin on, or updates it. Returns the status afterwards.
    public func connect() async -> PluginStatus {
        let before = await check()
        guard let runner else { return .noClaude }
        switch before {
        case .connected, .noClaude, .checking, .checkFailed:
            // A failed check installs nothing: only "not installed" leads to an install.
            return before
        case .disabled:
            guard await step(runner, ["plugin", "enable", Self.pluginID]) else { return .failed("Couldn't turn the plugin on.") }
        case .outdated:
            _ = await step(runner, ["plugin", "marketplace", "update", Self.marketplace])
            guard await step(runner, ["plugin", "update", Self.pluginID]) else { return .failed("Couldn't update the plugin.") }
        case .notInstalled, .failed:   // check() never returns .failed
            if !(await hasMarketplace(runner)) {
                guard await step(runner, ["plugin", "marketplace", "add", Self.marketplaceSource]) else {
                    return .failed("Couldn't add the Earshot plugin source. Check your internet connection.")
                }
            }
            guard await step(runner, ["plugin", "install", Self.pluginID, "--scope", "user"]) else {
                return .failed("Couldn't install the plugin.")
            }
        }
        return await check()
    }

    private func hasMarketplace(_ runner: any ClaudeRunner) async -> Bool {
        let r = await runner.run(["plugin", "marketplace", "list", "--json"], cwd: nil, timeout: .seconds(20))
        guard r.status == 0, let list = try? JSONSerialization.jsonObject(with: r.stdout) as? [[String: Any]] else { return false }
        return list.contains { ($0["name"] as? String) == Self.marketplace }
    }

    private func step(_ runner: any ClaudeRunner, _ args: [String]) async -> Bool {
        let r = await runner.run(args, cwd: nil, timeout: .seconds(180))
        if r.status != 0 || r.timedOut {
            log.error("claude \(args.prefix(3).joined(separator: " "), privacy: .public) failed: \(r.status)")
            return false
        }
        return true
    }

    /// Reads `claude plugin list --json`.
    static func status(fromList data: Data) -> PluginStatus {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .checkFailed("Couldn't read Claude Code's plugin list.")
        }
        guard let entry = list.first(where: { ($0["id"] as? String) == pluginID }) else { return .notInstalled }
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
