import Foundation
import Testing
@testable import KobiKit

struct SessionTranscriptTests {
    func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    func user(_ text: Any, meta: Bool = false, id: String = UUID().uuidString) -> Data {
        line(["type": "user", "uuid": id, "isMeta": meta, "timestamp": "2026-10-14T07:07:45.553Z",
              "message": ["role": "user", "content": text]])
    }
    func assistant(_ blocks: [[String: Any]], id: String = UUID().uuidString) -> Data {
        line(["type": "assistant", "uuid": id, "timestamp": "2026-10-14T07:08:03.088Z",
              "message": ["role": "assistant", "content": blocks]])
    }
    func tool(_ name: String, _ input: [String: Any], id: String = "t") -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    @Test func turnsReadAsYouClaudeAndTheWorkBetween() {
        let r = SessionTranscript.parse([
            user("Add a page that links to my projects"),
            assistant([tool("Bash", ["command": "ls"], id: "a"), tool("Bash", ["command": "cat about.md"], id: "b")]),
            user([["type": "tool_result", "tool_use_id": "a", "content": "x"]]),
            assistant([tool("Edit", ["file_path": "/p/blog/about.md"], id: "c"), ["type": "text", "text": "Done. The page is up."]]),
        ])
        #expect(r.turns.map(\.role) == [.you, .work, .claude])
        #expect(r.turns[0].text == "Add a page that links to my projects")
        #expect(r.turns[1].text == "Ran 2 commands, edited about.md")
        #expect(r.turns[2].text == "Done. The page is up.")
        #expect(r.turns[0].at != nil)
        #expect(r.asked == nil)
    }

    @Test func whatClaudeCodeAddsToYourTurnIsLeftOut() {
        let r = SessionTranscript.parse([
            user("<command-name>/compact</command-name>"),
            user("Caveat: the messages below", meta: true),
            user("[Request interrupted by user]"),
            user([["type": "text", "text": "<system-reminder>x</system-reminder>"], ["type": "text", "text": "Ship it"]]),
            line(["type": "attachment", "uuid": "z"]),
        ])
        #expect(r.turns.map(\.text) == ["Ship it"])
    }

    @Test func anUnansweredQuestionIsPending() {
        let ask = tool("AskUserQuestion", ["questions": [["question": "Retry the whole upload?",
                                                         "options": [["label": "Whole upload"], ["label": "Only the call"]]]]], id: "q")
        let open = SessionTranscript.parse([user("Fix retries"), assistant([ask])])
        #expect(open.asked == AskedQuestion(question: "Retry the whole upload?", options: ["Whole upload", "Only the call"]))
        let done = SessionTranscript.parse([user("Fix retries"), assistant([ask]),
                                            user([["type": "tool_result", "tool_use_id": "q", "content": "Whole upload"]])])
        #expect(done.asked == nil)
    }

    @Test func toolsReadAsAFewWords() {
        #expect(SessionTranscript.step("mcp__computer-use__screenshot", [:]) == "used computer use")
        #expect(SessionTranscript.step("mcp__Claude_Browser__navigate", [:]) == "used Claude Browser")
        #expect(SessionTranscript.step("Read", ["file_path": "/a/b/c.swift"]) == "read c.swift")
        #expect(SessionTranscript.summary(["ran a command", "ran a command", "read c.swift"]) == "Ran 2 commands, read c.swift")
    }

    @Test func onlyTheLastTurnsAreKept() {
        let lines = (1...20).map { user("prompt \($0)") }
        #expect(SessionTranscript.parse(lines, limit: 3).turns.map(\.text) == ["prompt 18", "prompt 19", "prompt 20"])
    }

    @Test func theFileIsFoundByFolderOrBySessionID() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "eh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appending(path: ".claude/projects/-Users-me-Projects-blog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appending(path: "abc.jsonl")
        try (String(data: user("hello"), encoding: .utf8)! + "\n").write(to: f, atomically: true, encoding: .utf8)
        let path = { (u: URL?) in u?.resolvingSymlinksInPath().path }
        #expect(path(SessionTranscript.file(sessionID: "abc", cwd: "/Users/me/Projects/blog", home: home)) == path(f))
        #expect(path(SessionTranscript.file(sessionID: "abc", cwd: "/Users/me/elsewhere", home: home)) == path(f))
        #expect(SessionTranscript.file(sessionID: "../x", cwd: "/", home: home) == nil)
        #expect(SessionTranscript.recent(f)?.turns.map(\.text) == ["hello"])
    }

    /// Megabytes of tool output after the last words: it reads further back to find them.
    @Test func aTailFullOfToolOutputReadsFurtherBack() throws {
        let f = FileManager.default.temporaryDirectory.appending(path: "bulk-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: f) }
        let bulk = String(repeating: "x", count: 50_000)
        var lines = (1...8).map { String(data: user("prompt \($0)"), encoding: .utf8)! }
        lines += (1...40).map { i in
            String(data: user([["type": "tool_result", "tool_use_id": "t\(i)", "content": bulk]]), encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
        let r = SessionTranscript.recent(f, limit: 12, tailBytes: 100_000)
        #expect(r?.turns.count == 8)
    }

    @Test func aBackgroundJobReadsAsNotesAndItsNeed() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appending(path: ".claude/jobs/2bc20c28")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"state":"blocked","needs":"provide a test invitation code"}"#.write(to: dir.appending(path: "state.json"), atomically: true, encoding: .utf8)
        try ([#"{"at":"2026-07-01T01:22:05.251Z","state":"working","detail":"building the RSVP flow"}"#,
              #"{"at":"2026-07-01T01:23:05.251Z","state":"working","detail":"building the RSVP flow"}"#,
              #"{"at":"2026-07-01T01:24:05.251Z","state":"working","detail":"checking the rsv"}"#,
              #"{"at":"2026-07-01T01:24:06.251Z","state":"working","detail":"checking the rsvp"}"#,
              #"{"at":"2026-07-01T01:25:45.631Z","state":"blocked","detail":"prod deployed"}"#].joined(separator: "\n"))
            .write(to: dir.appending(path: "timeline.jsonl"), atomically: true, encoding: .utf8)
        let r = SessionTranscript.job(sessionID: "2bc20c28-fe31-4c8d-be2f-cddffee12b94", home: home)
        #expect(r?.turns.map(\.text) == ["building the RSVP flow", "checking the rsvp", "prod deployed"])
        #expect(r?.asked == AskedQuestion(question: "Provide a test invitation code", options: []))
        #expect(SessionTranscript.job(sessionID: "ffffffff-0000", home: home) == nil)
    }

    @Test func aTailReadSkipsThePartLineItStartsIn() throws {
        let f = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: f) }
        let text = (1...50).map { String(data: user("prompt \($0)"), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        try text.write(to: f, atomically: true, encoding: .utf8)
        let r = SessionTranscript.recent(f, limit: 100, tailBytes: 2_000)
        #expect(r?.turns.last?.text == "prompt 50")
        #expect((r?.turns.count ?? 0) > 3)
    }

    @Test func timestampsReadWithAndWithoutFractions() {
        let ms = SessionTranscript.date("2026-10-14T07:07:45.553Z")
        let whole = SessionTranscript.date("2026-10-14T07:07:45Z")
        #expect(whole == Date(timeIntervalSince1970: 1_791_961_665))
        #expect(ms.map { $0.timeIntervalSince1970 - 1_791_961_665 }.map { abs($0 - 0.553) < 0.001 } == true)
        #expect(SessionTranscript.date("yesterday") == nil)
    }
}
