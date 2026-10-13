import Darwin
import Foundation
import Testing
@testable import EarshotKit

@Suite struct ApprovalBookTests {
    let dir: String = {
        let d = NSTemporaryDirectory() + "ek-approvals-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    let secret = "0123456789abcdef0123456789abcdef"

    func message(_ id: String = "1790000000-1-2", session: String = "s1", pid: Int32? = 77) -> AppMessage.Approval {
        .init(session: session, id: id, name: "billing service", what: "to run the migration",
              answer: "\(dir)/answer-\(session)-\(id)", secret: secret, pid: pid)
    }

    func book(alive: Bool = true) -> ApprovalBook { ApprovalBook(stateDir: dir, isAlive: { _ in alive }) }

    @Test func keepsAnOpenPromptAndWritesTheAnswer() async throws {
        let b = book()
        #expect(await b.apply(message()))
        #expect(await b.current.map(\.id) == ["1790000000-1-2"])
        #expect(await b.answer("1790000000-1-2", allow: true) == .written)
        let path = "\(dir)/answer-s1-1790000000-1-2"
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "allow \(secret)\n")
        var st = stat()
        stat(path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(await b.current.isEmpty)   // answered once
    }

    @Test func denyWritesDeny() async throws {
        let b = book()
        _ = await b.apply(message())
        #expect(await b.answer("1790000000-1-2", allow: false) == .written)
        #expect(try String(contentsOfFile: "\(dir)/answer-s1-1790000000-1-2", encoding: .utf8) == "deny \(secret)\n")
    }

    @Test func answerAfterCloseWritesNothing() async {
        let b = book()
        _ = await b.apply(message())
        _ = await b.apply(.init(session: "s1", id: "1790000000-1-2", state: "closed", by: "screen"))
        #expect(await b.answer("1790000000-1-2", allow: true) == .closed)
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/answer-s1-1790000000-1-2"))
    }

    /// The closed message can overtake the open one (both are sent in the
    /// background). The prompt must not come back.
    @Test func aLateOpenAfterItsCloseIsRefused() async {
        let b = book()
        _ = await b.apply(.init(session: "s1", id: "1790000000-1-2", state: "closed", by: "screen"))
        #expect(await b.apply(message()) == false)
        #expect(await b.current.isEmpty)
    }

    @Test func refusesAnAnswerPathOutsideTheStateFolder() async {
        let b = book()
        var m = message()
        m.answer = "/tmp/answer-s1-1790000000-1-2"
        #expect(await b.apply(m) == false)
        m = message()
        m.answer = "\(dir)/../answer-s1-1790000000-1-2"
        #expect(await b.apply(m) == false)
    }

    @Test func refusesABadSecretOrUnsafeNames() async {
        let b = book()
        var m = message()
        m.secret = "short"
        #expect(await b.apply(m) == false)
        #expect(await b.apply(message("../x")) == false)
        #expect(await b.apply(message(session: "a/b")) == false)
    }

    /// A hook killed with SIGKILL never sends closed: its prompt goes once
    /// its process is gone.
    @Test func aPromptWhoseHookIsGoneIsDropped() async {
        let b = book(alive: false)
        _ = await b.apply(message())
        #expect(await b.current.isEmpty)
        #expect(await b.answer("1790000000-1-2", allow: true) == .closed)
    }

    @Test func latestIsPerSession() async {
        let b = book()
        _ = await b.apply(message("1790000000-1-2", session: "s1"))
        _ = await b.apply(message("1790000001-1-3", session: "s2"))
        _ = await b.apply(message("1790000002-1-4", session: "s1"))
        #expect(await b.latest(session: "s1")?.id == "1790000002-1-4")
        #expect(await b.current.count == 3)
    }

    /// The panel's rows: the list again when a prompt opens, is answered, or closes.
    @Test func changesFollowOpenAnswerAndClose() async {
        let b = book()
        var it = await b.changes().makeAsyncIterator()
        #expect(await it.next()?.isEmpty == true)
        _ = await b.apply(message("1790000000-1-2"))
        _ = await b.apply(message("1790000001-1-3", session: "s2"))
        #expect(await it.next()?.map(\.id) == ["1790000000-1-2"])
        let both = await it.next()
        #expect(both?.map(\.id) == ["1790000000-1-2", "1790000001-1-3"])
        #expect(both?.first?.line == "Billing service wants to run the migration")
        _ = await b.answer("1790000000-1-2", allow: true)
        #expect(await it.next()?.map(\.id) == ["1790000001-1-3"])
        _ = await b.apply(.init(session: "s2", id: "1790000001-1-3", state: "closed", by: "screen"))
        #expect(await it.next()?.isEmpty == true)
    }

    /// The answer file is written next to it and renamed, so the hook never
    /// reads half a file, and an existing link at the path is not followed.
    @Test func doesNotFollowALinkAtTheAnswerPath() async throws {
        let b = book()
        _ = await b.apply(message())
        let target = "\(dir)/target"
        FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/answer-s1-1790000000-1-2", withDestinationPath: target)
        #expect(await b.answer("1790000000-1-2", allow: true) == .written)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
    }
}
