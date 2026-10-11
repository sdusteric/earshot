import Darwin
import Foundation
import Testing
@testable import EarshotKit

@Suite(.serialized) struct SessionTransportTests {
    @Test func theLineIsTheMessagingFormat() throws {
        let data = CCSocketTransport.line(sessionID: "3b4f", text: "run the \"tests\"", priority: .next)
        let o = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(o["type"] as? String == "user")
        #expect(o["from"] as? String == "earshot")
        #expect(o["session_id"] as? String == "3b4f")
        #expect(o["priority"] as? String == "next")
        let m = try #require(o["message"] as? [String: Any])
        #expect(m["role"] as? String == "user")
        #expect(m["content"] as? String == "run the \"tests\"")
        #expect(!data.contains(10))   // one line
    }

    @Test func writesOneLineToThePidsSocket() async throws {
        let dir = "/tmp/ek-cc-\(UUID().uuidString.prefix(4))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let got = Collected<String>()
        let server = LineServer(path: "\(dir)/4242.sock") { (line: Data) -> Data in
            let s = String(decoding: line, as: UTF8.self)
            Task { await got.add(s) }
            return Data()
        }
        try server.start()
        defer { server.stop() }
        let ok = await CCSocketTransport(dir: dir).send(pid: 4242, sessionID: "s1", text: "hi", priority: .now)
        #expect(ok)
        #expect(await eventually { await got.items.count == 1 })
        #expect(await got.items.first?.contains(#""priority":"now""#) == true)
    }

    @Test func aMissingSocketIsFalse() async {
        #expect(await CCSocketTransport(dir: "/tmp/ek-none").send(pid: 1, sessionID: "s", text: "x", priority: .next) == false)
    }

    /// Only a socket you own: a plain file or a link at the path is refused.
    @Test func refusesSomethingThatIsNotYourSocket() async throws {
        let dir = "/tmp/ek-cc-\(UUID().uuidString.prefix(4))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/7.sock", contents: Data())
        #expect(await CCSocketTransport(dir: dir).send(pid: 7, sessionID: "s", text: "x", priority: .next) == false)
    }
}
