import Foundation
import Synchronization
import Testing
@testable import KobiKit

@Suite(.serialized) struct ClaudeCLITests {
    /// The shape `claude agents --json` printed on 2026-10-11 (Claude Code 2.1.296).
    static let agentsJSON = #"""
    [
      {"id":"2bc20c28","cwd":"/Users/me/wedding","kind":"background","startedAt":1782868923593,
       "sessionId":"2bc20c28-fe31-4c8d-be2f-cddffee12b94","name":"Create guest confirmation email with event details","state":"blocked"},
      {"pid":2030,"cwd":"/Users/me/blog","kind":"interactive","startedAt":1790640209107,
       "sessionId":"3b4f70dd-8dd4-4425-b46d-e2b2e85b6ad9","name":"blog-83","status":"idle"},
      {"pid":2031,"cwd":"/Users/me/billing-service","kind":"interactive","startedAt":1790640209188,
       "sessionId":"4cf0687b-7105-4ee3-a83f-33b5fdf86559","name":"Fix refund rounding","status":"busy"},
      {"pid":"not a number","sessionId":"broken"}
    ]
    """#

    @Test func readsTheSessionList() {
        let list = AgentEntry.decodeList(Data(Self.agentsJSON.utf8))
        #expect(list.map(\.sessionId) == ["2bc20c28-fe31-4c8d-be2f-cddffee12b94", "3b4f70dd-8dd4-4425-b46d-e2b2e85b6ad9",
                                          "4cf0687b-7105-4ee3-a83f-33b5fdf86559"])
        #expect(list[0].isBackground && list[0].pid == nil)
        #expect(list[1].pid == 2030 && !list[1].isBusy)
        #expect(list[2].isBusy)
    }

    @Test func notJSONIsAnEmptyList() {
        #expect(AgentEntry.decodeList(Data("Error: not signed in".utf8)).isEmpty)
    }

    @Test func locatePrefersTheUsualPlaces() {
        let found = ClaudeCLI.locate(home: "/Users/me", isExecutable: { $0 == "/opt/homebrew/bin/claude" },
                                     loginShell: { Issue.record("asked the shell"); return nil })
        #expect(found == "/opt/homebrew/bin/claude")
        #expect(ClaudeCLI.locate(home: "/Users/me", isExecutable: { $0 == "/Users/me/.local/bin/claude" },
                                 loginShell: { nil }) == "/Users/me/.local/bin/claude")
    }

    @Test func locateAsksTheLoginShellLast() {
        #expect(ClaudeCLI.locate(home: "/Users/me", isExecutable: { $0 == "/nix/bin/claude" },
                                 loginShell: { "/nix/bin/claude" }) == "/nix/bin/claude")
        #expect(ClaudeCLI.locate(home: "/Users/me", isExecutable: { _ in false }, loginShell: { nil }) == nil)
    }

    /// Your own shell first (bash or fish keep claude on their own PATH), then zsh, each once.
    @Test func loginShellsStartWithYours() {
        #expect(ClaudeCLI.loginShells(user: "/opt/homebrew/bin/fish", account: "/bin/zsh") == ["/opt/homebrew/bin/fish", "/bin/zsh"])
        #expect(ClaudeCLI.loginShells(user: nil, account: "/bin/bash") == ["/bin/bash", "/bin/zsh"])
        #expect(ClaudeCLI.loginShells(user: "/bin/zsh", account: "/bin/zsh") == ["/bin/zsh"])
        #expect(ClaudeCLI.loginShells(user: "fish", account: nil) == ["/bin/zsh"])
    }

    @Test func aMissingClaudeFailsUntilItIsFound() async {
        let path = Mutex<String?>(nil)
        let claude = LocatedClaude(find: { path.withLock { $0 } })
        #expect(await claude.locate() == nil)
        #expect(await claude.run(["--version"], cwd: nil, timeout: .seconds(1)).status == -1)
        path.withLock { $0 = "/bin/echo" }
        #expect(await claude.locate() == "/bin/echo")
        let r = await claude.run(["hi"], cwd: nil, timeout: .seconds(5))
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hi\n")
        path.withLock { $0 = nil }
        #expect(await claude.locate() == "/bin/echo")   // kept once found
    }

    @Test func overlappingLooksShareOneSearch() async {
        let searches = Mutex(0)
        let claude = LocatedClaude(find: {
            searches.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.2)
            return "/bin/echo"
        })
        async let a = claude.locate()
        async let b = claude.locate()
        let (x, y) = await (a, b)
        #expect(x == "/bin/echo" && y == "/bin/echo")
        #expect(searches.withLock { $0 } == 1)
    }

    @Test func runsAProgramAndReadsItsOutput() async {
        let r = await ClaudeCLI(path: "/bin/echo").run(["hello"], cwd: "/tmp", timeout: .seconds(5))
        #expect(r.status == 0)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hello\n")
    }

    @Test func aSlowProgramIsStopped() async {
        let start = ContinuousClock.now
        let r = await ClaudeCLI(path: "/bin/sleep").run(["10"], cwd: nil, timeout: .milliseconds(300))
        #expect(r.status != 0)
        #expect(r.timedOut)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// SIGTERM is ignored, so only SIGKILL after the grace period stops it.
    @Test func aChildThatIgnoresSIGTERMIsKilledAndTheCallReturns() async {
        let start = ContinuousClock.now
        let r = await ClaudeCLI(path: "/bin/sh").run(["-c", "trap \"\" TERM; sleep 10"], cwd: nil,
                                                    timeout: .milliseconds(300))
        #expect(r.timedOut)
        #expect(ContinuousClock.now - start < .milliseconds(2300))   // deadline + 1 s grace + 1 s
    }

    /// A grandchild holds stdout open after the child exits: do not wait for EOF.
    @Test func aGrandchildHoldingThePipeDoesNotHoldTheCall() async {
        let start = ContinuousClock.now
        let r = await ClaudeCLI(path: "/bin/sh").run(["-c", "sleep 10 & echo hi"], cwd: nil, timeout: .seconds(5))
        #expect(r.status == 0 && !r.timedOut)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hi\n")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// stderr larger than a pipe buffer must not stall the child.
    @Test func aLargeStderrDoesNotDeadlock() async {
        let start = ContinuousClock.now
        let r = await ClaudeCLI(path: "/bin/sh").run(["-c", "head -c 200000 /dev/zero >&2; echo ok"], cwd: nil,
                                                    timeout: .seconds(5))
        #expect(r.status == 0 && !r.timedOut)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "ok\n")
        #expect(r.stderr.utf8.count == 200000)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// A failed --version is not cached: the next call asks again.
    @Test func versionCachesOnlyASuccess() async throws {
        let dir = NSTemporaryDirectory() + "ek-ver-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let script = "\(dir)/claude"
        try """
        #!/bin/sh
        if [ -e "$0.ran" ]; then echo "2.1.296 (Claude Code)"; else touch "$0.ran"; exit 1; fi

        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let cli = ClaudeCLI(path: script)
        #expect(await cli.version() == nil)
        #expect(await cli.version() == "2.1.296")
        try FileManager.default.removeItem(atPath: "\(script).ran")   // now a failing script, if asked again
        #expect(await cli.version() == "2.1.296")
    }

    @Test func aMissingProgramFails() async {
        let r = await ClaudeCLI(path: "/nonexistent/claude").run(["--version"], cwd: nil, timeout: .seconds(1))
        #expect(r.status == -1)
    }
    /// Open pipes (FIFO descriptors), counted from /dev/fd. Other suites run in parallel and
    /// open their own pipes, so the leak check allows slack; a leak here is 4 pipes per run.
    static func openDescriptors() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.reduce(0) { n, name in
            guard let fd = Int32(name) else { return n }
            var st = stat()
            return fstat(fd, &st) == 0 && st.st_mode & S_IFMT == S_IFIFO ? n + 1 : n
        }
    }

    /// A launch that fails must not keep its pipes open.
    @Test func aMissingProgramLeaksNoDescriptors() async {
        let cli = ClaudeCLI(path: "/nonexistent/claude")
        _ = await cli.run(["--version"], cwd: nil, timeout: .seconds(1))   // warm up Foundation's own descriptors
        let before = Self.openDescriptors()
        for _ in 0..<50 {
            let r = await cli.run(["--version"], cwd: nil, timeout: .seconds(1))
            #expect(r.status == -1)
        }
        #expect(Self.openDescriptors() <= before + 20)
    }

    /// A launch that works must not keep its pipes open either.
    @Test func aSuccessfulRunLeaksNoDescriptors() async {
        let cli = ClaudeCLI(path: "/bin/echo")
        _ = await cli.run(["warm"], cwd: nil, timeout: .seconds(5))
        let before = Self.openDescriptors()
        for _ in 0..<50 {
            let r = await cli.run(["hi"], cwd: nil, timeout: .seconds(5))
            #expect(r.status == 0)
        }
        #expect(Self.openDescriptors() <= before + 20)
    }
}

struct AgentStateTests {
    @Test func aBlockedBackgroundSessionWaitsOnYou() {
        #expect(AgentEntry(sessionId: "a", pid: nil, cwd: "/", kind: "background", state: "blocked").isWaiting)
        #expect(!AgentEntry(sessionId: "a", pid: nil, cwd: "/", kind: "background", state: "failed").isWaiting)
        #expect(AgentEntry(sessionId: "b", pid: 1, cwd: "/", kind: "interactive", status: "waiting").isWaiting)
        #expect(!AgentEntry(sessionId: "b", pid: 1, cwd: "/", kind: "interactive", status: "idle").isWaiting)
    }
}
