import Foundation
import Testing
@testable import EarshotKit

@Suite struct AppMessageTests {
    func decode(_ s: String) throws -> AppMessage { try AppMessage.decode(Data(s.utf8)) }

    @Test func decodesSay() throws {
        let m = try decode(#"{"v":1,"type":"say","text":"Hi","kind":"need","session":"s1","name":"billing service","transcript":"/t.jsonl"}"#)
        #expect(m == .say(.init(text: "Hi", kind: .need, session: "s1", name: "billing service", transcript: "/t.jsonl")))
    }

    @Test func sayWithoutSessionIsAllowed() throws {
        let m = try decode(#"{"v":1,"type":"say","text":"Two sessions.","kind":"roll"}"#)
        #expect(m == .say(.init(text: "Two sessions.", kind: .roll, session: "")))
    }

    @Test func decodesStatus() throws {
        let m = try decode(#"{"v":1,"type":"status","session":"s1","state":"needs","detail":"needs your OK","name":"billing service","project":"billing service","title":"Tax export"}"#)
        #expect(m == .status(.init(session: "s1", state: .needs, detail: "needs your OK", name: "billing service", project: "billing service", title: "Tax export")))
    }

    @Test func rejectsOtherVersions() {
        #expect(throws: AppMessage.DecodeError.version(2)) { try decode(#"{"v":2,"type":"say","text":"x","kind":"done"}"#) }
    }

    @Test func rejectsUnknownTypesAndKinds() {
        #expect(throws: AppMessage.DecodeError.unknownType("dance")) { try decode(#"{"v":1,"type":"dance"}"#) }
        #expect(throws: AppMessage.DecodeError.badMessage) { try decode(#"{"v":1,"type":"say","text":"x","kind":"shout"}"#) }
        #expect(throws: AppMessage.DecodeError.badMessage) { try decode("not json") }
    }

    @Test func heldKinds() {
        let held = [LineKind.need, .reply, .alert, .done].allSatisfy { $0.isHeld }
        let notHeld = [LineKind.beat, .ack, .roll, .intro].allSatisfy { !$0.isHeld }
        #expect(held)
        #expect(notHeld)
    }

    @Test func replyEncodesOneLine() throws {
        #expect(String(decoding: AppReply(ok: true).encoded, as: UTF8.self) == #"{"ok":true}"#)
        #expect(String(decoding: AppReply(ok: false, reason: "version").encoded, as: UTF8.self) == #"{"ok":false,"reason":"version"}"#)
    }

    @Test func decodesAnOpenApproval() throws {
        let m = try decode(#"{"v":1,"type":"approval","session":"s1","id":"1790000000-123-456","name":"billing service","what":"to run the migration","answer":"/t/earshot/answer-s1-1790000000-123-456","secret":"0123456789abcdef0123456789abcdef","pid":123,"sent":1790000000000}"#)
        guard case .approval(let a) = m else { Issue.record("not an approval"); return }
        #expect(a.session == "s1")
        #expect(a.id == "1790000000-123-456")
        #expect(a.name == "billing service")
        #expect(a.what == "to run the migration")
        #expect(a.secret == "0123456789abcdef0123456789abcdef")
        #expect(a.pid == 123)
        #expect(!a.isClosed)
    }

    @Test func decodesAClosedApproval() throws {
        let m = try decode(#"{"v":1,"type":"approval","session":"s1","id":"x","state":"closed","by":"screen"}"#)
        guard case .approval(let a) = m else { Issue.record("not an approval"); return }
        #expect(a.isClosed)
        #expect(a.by == "screen")
        #expect(a.secret == nil)
    }

    @Test func confirmLinesAreNeverHeld() {
        #expect(!LineKind.confirm.isHeld)
        #expect(LineKind.confirm.catchUpRank == 2)
    }
}
