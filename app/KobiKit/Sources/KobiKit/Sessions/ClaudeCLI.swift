import Darwin
import Foundation
import Synchronization

public struct RunResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    /// True when the deadline fired, so the output may be cut short.
    public var timedOut: Bool
    public init(status: Int32, stdout: Data = Data(), stderr: String = "", timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
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
    /// When the session started, in milliseconds since 1970.
    public let startedAt: Double?

    public init(sessionId: String, pid: Int32?, cwd: String, kind: String, name: String? = nil, status: String? = nil,
                state: String? = nil, startedAt: Double? = nil) {
        self.sessionId = sessionId; self.pid = pid; self.cwd = cwd; self.kind = kind
        self.name = name; self.status = status; self.state = state; self.startedAt = startedAt
    }

    public var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    public var isBackground: Bool { kind == "background" }
    public var isBusy: Bool { status == "busy" }
    /// Waiting on you: a session with a process says "waiting"; a background
    /// session, which has none, is "blocked" on a prompt or a question.
    public var isWaiting: Bool { status == "waiting" || (isBackground && state == "blocked") }

    public static func decodeList(_ data: Data) -> [AgentEntry] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return items.compactMap { item in
            guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(AgentEntry.self, from: d)
        }
    }
}

/// Runs one process with a deadline. Both pipes are drained as they fill, so
/// a full pipe never stalls the child. At the deadline the process gets
/// SIGTERM, and after a 1 s grace SIGKILL. The call returns once the process
/// has exited and its pipes are drained (or 200 ms after exit, when a
/// grandchild still holds a pipe), or at deadline plus grace, whichever is first.
enum BoundedRun {
    static func run(executable: String, args: [String], cwd: String?, environment: [String: String]?,
                    timeout: Double) async -> RunResult {
        await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            let job = Job(cont)
            let p = job.process
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            p.environment = environment
            p.standardOutput = job.out
            p.standardError = job.err
            p.standardInput = FileHandle.nullDevice
            job.out.fileHandleForReading.readabilityHandler = { job.read($0, stdout: true) }
            job.err.fileHandleForReading.readabilityHandler = { job.read($0, stdout: false) }
            p.terminationHandler = { _ in job.exited() }
            do {
                try p.run()
            } catch {
                job.failed(error.localizedDescription)
                return
            }
            // The child has its own copies now. Ours must close, or EOF never reaches the reader.
            try? job.out.fileHandleForWriting.close()
            try? job.err.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { job.deadline() }
        }
    }

    private final class Job: @unchecked Sendable {
        struct State {
            var out = Data(), err = Data()
            var outDone = false, errDone = false
            var exited = false
            var status: Int32 = -1
            var timedOut = false
            var resumed = false
        }

        let process = Process()
        let out = Pipe(), err = Pipe()
        private let cont: CheckedContinuation<RunResult, Never>
        private let state = Mutex(State())

        init(_ cont: CheckedContinuation<RunResult, Never>) { self.cont = cont }

        func read(_ h: FileHandle, stdout: Bool) {
            let d = h.availableData
            let eof = d.isEmpty
            state.withLock { s in
                if !eof && stdout { s.out.append(d) }
                if !eof && !stdout { s.err.append(d) }
                if eof && stdout { s.outDone = true }
                if eof && !stdout { s.errDone = true }
            }
            if eof {
                h.readabilityHandler = nil
                try? h.close()
                maybeFinish()
            }
        }

        func exited() {
            state.withLock { s in
                s.exited = true
                s.status = process.terminationStatus
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { self.finish() }
            maybeFinish()
        }

        /// At the deadline: SIGTERM, then after the grace period SIGKILL (only while the child has not exited,
        /// so a reaped pid is never signalled) and return what was read.
        func deadline() {
            let stillRunning = state.withLock { s -> Bool in
                if s.exited { return false }
                s.timedOut = true
                return true
            }
            guard stillRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                self.state.withLock { s in
                    if !s.exited { Darwin.kill(self.process.processIdentifier, SIGKILL) }
                }
                self.finish()
            }
        }

        func failed(_ message: String) {
            state.withLock { $0.resumed = true }
            // No handler can be running on this path, so the read ends can close here.
            for pipe in [out, err] {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            process.terminationHandler = nil
            cont.resume(returning: RunResult(status: -1, stderr: message))
        }

        /// Drops the handlers. The read ends close when this job is freed (a grandchild may
        /// still be writing, so they are not closed under a running handler). Clearing the
        /// termination handler also breaks the reference cycle through this job.
        private func release() {
            process.terminationHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        private func maybeFinish() {
            let done = state.withLock { s in s.exited && s.outDone && s.errDone }
            if done { finish() }
        }

        /// Resumes once, whichever of the paths above comes first.
        func finish() {
            let result: RunResult? = state.withLock { s in
                if s.resumed { return nil }
                s.resumed = true
                return RunResult(status: s.exited ? s.status : -1, stdout: s.out,
                                 stderr: String(decoding: s.err, as: UTF8.self), timedOut: s.timedOut)
            }
            guard let result else { return }
            release()
            cont.resume(returning: result)
        }
    }
}

/// Runs the claude command line. Apps opened from the Dock get a short PATH,
/// so the binary is looked for in the usual places and then in a login shell.
public final class ClaudeCLI: ClaudeRunner {
    public let path: String
    private let cachedVersion = Mutex<String?>(nil)

    public init(path: String) { self.path = path }

    public static func locate() -> String? {
        let shells = loginShells(user: ProcessInfo.processInfo.environment["SHELL"], account: accountShell())
        return locate(home: NSHomeDirectory(), isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                      loginShell: { loginShellLookup(shells: shells) })
    }

    public static func locate(home: String, isExecutable: (String) -> Bool, loginShell: () -> String?) -> String? {
        let usual = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     "\(home)/.claude/local/claude"]
        if let p = usual.first(where: isExecutable) { return p }
        if let p = loginShell(), p.hasPrefix("/"), isExecutable(p) { return p }
        return nil
    }

    /// The shells to ask, in order: yours ($SHELL, else the account's), then zsh.
    /// bash and fish users keep claude on a PATH that only their own shell sets up.
    static func loginShells(user: String?, account: String?) -> [String] {
        var list: [String] = []
        for s in [user, account, "/bin/zsh"] {
            guard let s, s.hasPrefix("/"), !list.contains(s) else { continue }
            list.append(s)
        }
        return list
    }

    private static func accountShell() -> String? {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    /// Asks each login shell in turn, each with a 3 s limit: it has the PATH the user set up.
    static func loginShellLookup(shells: [String]) -> String? {
        for shell in shells where FileManager.default.isExecutableFile(atPath: shell) {
            if let p = ask(shell), p.hasPrefix("/") { return p }
        }
        return nil
    }

    private static func ask(_ shell: String) -> String? {
        let box = Mutex<RunResult?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let r = await BoundedRun.run(executable: shell, args: ["-lic", "command -v claude"], cwd: nil,
                                         environment: nil, timeout: 3)
            box.withLock { $0 = r }
            done.signal()
        }
        // BoundedRun returns within 4 s; the wait is a backstop only.
        guard done.wait(timeout: .now() + 5) == .success, let r = box.withLock({ $0 }),
              !r.timedOut, r.status == 0 else { return nil }
        return String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        var env = ProcessInfo.processInfo.environment
        let dir = (path as NSString).deletingLastPathComponent
        env["PATH"] = "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return await BoundedRun.run(executable: path, args: args, cwd: cwd, environment: env, timeout: seconds)
    }

    /// Only a version that was read is kept; a failure is asked again next time.
    public func version() async -> String? {
        if let v = cachedVersion.withLock({ $0 }) { return v }
        let r = await run(["--version"], cwd: nil, timeout: .seconds(5))
        let v = r.status == 0 ? String(decoding: r.stdout, as: UTF8.self).split(separator: " ").first.map(String.init) : nil
        if let v { cachedVersion.withLock { $0 = v } }
        return v
    }
}

/// The `claude` command, which may be installed after Kobi opens. Until it
/// is found, every run fails at once; `locate()` looks for it again.
public final class LocatedClaude: ClaudeRunner {
    private struct State {
        var cli: ClaudeCLI?
        var search: Task<String?, Never>?
    }

    private let find: @Sendable () -> String?
    private let state = Mutex(State())

    /// `find` blocks (it may ask login shells), so it runs off the caller's thread.
    public init(find: @escaping @Sendable () -> String? = { ClaudeCLI.locate() }) { self.find = find }

    public var path: String? { state.withLock { $0.cli?.path } }

    /// The path, looking for it when it is not known yet. Calls that overlap
    /// share one search. Once found, it is kept.
    @discardableResult
    public func locate() async -> String? {
        let search: Task<String?, Never>? = state.withLock { s in
            if s.cli != nil { return nil }
            if let t = s.search { return t }
            let find = self.find
            let t = Task.detached { find() }
            s.search = t
            return t
        }
        guard let search else { return path }
        let found = await search.value
        return state.withLock { s in
            if s.search == search { s.search = nil }
            if s.cli == nil, let found { s.cli = ClaudeCLI(path: found) }
            return s.cli?.path
        }
    }

    public func run(_ args: [String], cwd: String?, timeout: Duration) async -> RunResult {
        guard let cli = state.withLock({ $0.cli }) else { return RunResult(status: -1, stderr: "claude not found") }
        return await cli.run(args, cwd: cwd, timeout: timeout)
    }

    public func version() async -> String? {
        await state.withLock({ $0.cli })?.version()
    }
}
