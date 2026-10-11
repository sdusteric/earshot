import Foundation
import Testing
@testable import EarshotKit

@Suite struct ClaudeCLITests {
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

    @Test func runsAProgramAndReadsItsOutput() async {
        let r = await ClaudeCLI(path: "/bin/echo").run(["hello"], cwd: "/tmp", timeout: .seconds(5))
        #expect(r.status == 0)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hello\n")
    }

    @Test func aSlowProgramIsStopped() async {
        let start = ContinuousClock.now
        let r = await ClaudeCLI(path: "/bin/sleep").run(["10"], cwd: nil, timeout: .milliseconds(300))
        #expect(r.status != 0)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func aMissingProgramFails() async {
        let r = await ClaudeCLI(path: "/nonexistent/claude").run(["--version"], cwd: nil, timeout: .seconds(1))
        #expect(r.status == -1)
    }
}
