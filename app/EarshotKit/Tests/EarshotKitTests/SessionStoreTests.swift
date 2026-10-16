import Foundation
import Testing
@testable import EarshotKit

@Suite struct SessionStoreTests {
    /// A file in a folder of its own, so a test never touches the real names.
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "names-\(UUID().uuidString)/session-names.json")
    }

    func entry(_ id: String, _ project: String, _ title: String = "", started: Double? = nil) -> SpokenNames.Entry {
        .init(id: id, project: project, title: title, label: "", started: started.map { Date(timeIntervalSince1970: $0) })
    }

    func cleanUp(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func aNameSurvivesARelaunch() async {
        let url = tempURL(); defer { cleanUp(url) }
        let first = SessionStore(namesURL: url)
        // b shares a folder with a, so it is named for its title.
        let named = await first.nameSessions([entry("a", "reflow"), entry("b", "reflow", "Retry queue")])
        #expect(named == ["a": "Reflow", "b": "Reflow retry"])

        // After a relaunch the list comes in another order, and b is the only one with a title.
        let second = SessionStore(namesURL: url)
        let again = await second.nameSessions([entry("b", "reflow", "Docs"), entry("a", "reflow")])
        #expect(again == named)
    }

    @Test func aPluginOnlySessionKeepsItsNameToo() async {
        let url = tempURL(); defer { cleanUp(url) }
        let first = SessionStore(namesURL: url)
        await first.apply(.init(session: "a", state: .working, name: "reflow", project: "reflow"))
        await first.apply(.init(session: "b", state: .working, name: "reflow", project: "reflow", title: "Retry queue"))
        let names = await first.sessions.reduce(into: [String: String]()) { $0[$1.id] = $1.name }
        #expect(Set(names.values).count == 2)

        let second = SessionStore(namesURL: url)
        // b reports first this time; it still gets the name it had.
        await second.apply(.init(session: "b", state: .working, name: "reflow", project: "reflow", title: "Retry queue"))
        #expect(await second.name(of: "b") == names["b"])
        await second.apply(.init(session: "a", state: .working, name: "reflow", project: "reflow"))
        let after = await second.sessions.reduce(into: [String: String]()) { $0[$1.id] = $1.name }
        #expect(after == names)
    }

    @Test func theFileIsReadableOnlyByYou() async throws {
        let url = tempURL(); defer { cleanUp(url) }
        let store = SessionStore(namesURL: url)
        await store.nameSessions([entry("a", "blog")])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    @Test func noFileWithoutAURL() async {
        let store = SessionStore()
        let names = await store.nameSessions([entry("a", "blog")])
        #expect(names == ["a": "Blog"])
    }

    /// A session gone for more than a day is forgotten; one gone for less is not.
    @Test func entriesGoAfterADayGone() async throws {
        let url = tempURL(); defer { cleanUp(url) }
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        let first = SessionStore(clock: { now.value }, namesURL: url)
        await first.nameSessions([entry("a", "blog"), entry("b", "wedding")])

        // a is still listed 20 hours later and b is not.
        now.value = now.value.addingTimeInterval(20 * 3600)
        await first.nameSessions([entry("a", "blog")])
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        #expect(Set(saved.names.keys) == ["a", "b"])

        // 5 more hours: b was last seen 25 hours ago, a 5.
        now.value = now.value.addingTimeInterval(5 * 3600)
        let second = SessionStore(clock: { now.value }, namesURL: url)
        await second.nameSessions([entry("a", "blog")])
        let after = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        #expect(Set(after.names.keys) == ["a"])
    }

    @Test func aSessionBackWithinADayHasItsNameAgain() async {
        let url = tempURL(); defer { cleanUp(url) }
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        let first = SessionStore(clock: { now.value }, namesURL: url)
        await first.nameSessions([entry("a", "reflow"), entry("b", "reflow", "Retry queue")])
        await first.apply(.init(session: "b", state: .closed))

        now.value = now.value.addingTimeInterval(3 * 3600)
        let second = SessionStore(clock: { now.value }, namesURL: url)
        let names = await second.nameSessions([entry("b", "reflow", "Docs"), entry("a", "reflow")])
        #expect(names["b"] == "Reflow retry")
    }

    /// Two sessions remembered under the same name (each was alone in its
    /// folder at the time): the one that started first keeps it.
    @Test func aClashIsNamedAgainForTheNewerSession() async throws {
        let url = tempURL(); defer { cleanUp(url) }
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        let seen = now.value.timeIntervalSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = #"{"version":1,"names":{"old":{"name":"Reflow","seen":\#(seen)},"new":{"name":"Reflow","seen":\#(seen)}}}"#
        try Data(file.utf8).write(to: url)

        let store = SessionStore(clock: { now.value }, namesURL: url)
        // Listed newest first, so the order listed does not decide it.
        let names = await store.nameSessions([entry("new", "reflow", "Retry queue", started: 2000),
                                              entry("old", "reflow", "Docs", started: 1000)])
        #expect(names["old"] == "Reflow")
        #expect(names["new"] == "Reflow retry")
        #expect(Set(names.values).count == 2)
    }

    /// A name a live session now holds is not taken by a remembered one.
    @Test func aRememberedNameDoesNotTakeALiveSessionsName() async throws {
        let url = tempURL(); defer { cleanUp(url) }
        let first = SessionStore(namesURL: url)
        await first.nameSessions([entry("x", "blog")])   // x was "Blog"

        let second = SessionStore(namesURL: url)
        // y, a new session, reports first and is alone in its folder: "Blog".
        await second.apply(.init(session: "y", state: .working, name: "blog", project: "blog"))
        #expect(await second.name(of: "y") == "Blog")
        // x comes back; both are live and the names stay different.
        await second.apply(.init(session: "x", state: .working, name: "blog", project: "blog", title: "Notes"))
        let names = await second.sessions.map(\.name)
        #expect(Set(names).count == 2)
    }

    /// A session that closed comes back (`claude --resume` keeps its id). It
    /// started before the live session that has gone by its old name since,
    /// and the live one keeps that name, in this run and after a relaunch.
    @Test func aReturningSessionDoesNotTakeALiveSessionsName() async {
        let url = tempURL(); defer { cleanUp(url) }
        let a = entry("A", "billing", started: 1_000), b = entry("B", "billing", started: 2_000)
        let store = SessionStore(namesURL: url)
        #expect(await store.nameSessions([a])["A"] == "Billing")
        await store.nameSessions([])                  // A closed
        #expect(await store.nameSessions([b])["B"] == "Billing")
        let back = await store.nameSessions([a, b])   // A resumed
        #expect(back["B"] == "Billing")
        #expect(back["A"] != "Billing")
        #expect(Set(back.values).count == 2)

        // The same two after a relaunch: each has the name it had.
        let relaunched = SessionStore(namesURL: url)
        #expect(await relaunched.nameSessions([a, b]) == back)
    }

    /// Closed before a relaunch while another took its name: it does not take it back.
    @Test func aClosedSessionsNameGoesToTheLiveOneForGood() async {
        let url = tempURL(); defer { cleanUp(url) }
        let a = entry("A", "billing", started: 1_000), b = entry("B", "billing", started: 2_000)
        let store = SessionStore(namesURL: url)
        await store.nameSessions([a])
        await store.nameSessions([])
        await store.nameSessions([b])
        let relaunched = SessionStore(namesURL: url)
        let names = await relaunched.nameSessions([a, b])
        #expect(names["B"] == "Billing")
        #expect(names["A"] != "Billing")
    }

    @Test func aBrokenFileIsIgnored() async throws {
        let url = tempURL(); defer { cleanUp(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SessionStore(namesURL: url)
        #expect(await store.nameSessions([entry("a", "blog")]) == ["a": "Blog"])
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        #expect(saved.names["a"]?.name == "Blog")
    }

    @Test func aStatusMessageIsNotAWrite() async throws {
        let url = tempURL(); defer { cleanUp(url) }
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        let store = SessionStore(clock: { now.value }, namesURL: url)
        await store.apply(.init(session: "a", state: .working, name: "blog", project: "blog"))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(30))
        now.value = now.value.addingTimeInterval(60)
        await store.apply(.init(session: "a", state: .done, name: "blog", project: "blog"))
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    struct Saved: Decodable {
        struct Item: Decodable { let name: String; let seen: Double }
        let names: [String: Item]
    }
}
