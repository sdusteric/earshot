import Foundation
import Synchronization

public struct RunResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol ClaudeRunner: Sendable {
    func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult
    /// Claude Code's version, "2.1.296", or nil.
    func version() async -> String?
}

/// One entry of `claude agents --json`.
public struct AgentEntry: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let pid: Int32?
    public let cwd: String
    public let kind: String
    public let name: String?
    /// busy, idle or waiting, for sessions with a process.
    public let status: String?
    /// For background sessions without a process, for example blocked.
    public let state: String?

    public init(sessionId: String, pid: Int32?, cwd: String, kind: String, name: String? = nil, status: String? = nil,
                state: String? = nil) {
        self.sessionId = sessionId; self.pid = pid; self.cwd = cwd; self.kind = kind
        self.name = name; self.status = status; self.state = state
    }

    public var isBackground: Bool { kind == "background" }
    public var isBusy: Bool { status == "busy" }
    public var isWaiting: Bool { status == "waiting" }

    public static func decodeList(_ data: Data) -> [AgentEntry] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return items.compactMap { item in
            guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(AgentEntry.self, from: d)
        }
    }
}

/// Runs the claude command line. Apps opened from the Dock get a short PATH,
/// so the binary is found once, at launch.
public final class ClaudeCLI: ClaudeRunner {
    public let path: String
    private let cachedVersion = Mutex<String??>(nil)

    public init(path: String) { self.path = path }

    public static func locate() -> String? {
        locate(home: NSHomeDirectory(), isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
               loginShell: loginShellLookup)
    }

    public static func locate(home: String, isExecutable: (String) -> Bool, loginShell: () -> String?) -> String? {
        let usual = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     "\(home)/.claude/local/claude"]
        if let p = usual.first(where: isExecutable) { return p }
        if let p = loginShell(), p.hasPrefix("/"), isExecutable(p) { return p }
        return nil
    }

    /// Asks the login shell once: it has the PATH the user set up.
    static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        let path = self.path
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                var env = ProcessInfo.processInfo.environment
                let dir = (path as NSString).deletingLastPathComponent
                env["PATH"] = "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(status: -1, stderr: error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: RunResult(status: p.terminationStatus, stdout: o,
                                                 stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }

    public func version() async -> String? {
        if let v = cachedVersion.withLock({ $0 }) { return v }
        let r = await run(["--version"], cwd: nil, timeout: .seconds(5))
        let v = r.status == 0 ? String(decoding: r.stdout, as: UTF8.self).split(separator: " ").first.map(String.init) : nil
        cachedVersion.withLock { $0 = .some(v) }
        return v
    }
}
