import Foundation
import Testing
@testable import EarshotKit

@Suite(.serialized) struct CoreTests {
    func path() -> String { "/tmp/ek-core-\(UUID().uuidString.prefix(6)).sock" }
    func send(_ path: String, _ json: String) throws -> String {
        String(decoding: try LineClient.send(path: path, line: Data(json.utf8), timeout: 0.2), as: UTF8.self)
    }

    @Test func sessionsNeedingYouComeFirstAndClosedOnesGo() async {
        let store = SessionStore()
        await store.apply(.init(session: "a", state: .working, name: "blog"))
        await store.apply(.init(session: "b", state: .needs, detail: "needs your OK", name: "billing service"))
        await store.apply(.init(session: "c", state: .done, name: "docs"))
        #expect(await store.sessions.map { $0.id } == ["b", "a", "c"])
        await store.apply(.init(session: "a", state: .closed))
        #expect(await store.sessions.map { $0.id } == ["b", "c"])
    }

    @Test func eventLogKeepsTheLastFifty() async {
        let log = EventLog()
        for i in 0..<60 { await log.add("e\(i)") }
        let recent = await log.recent
        #expect(recent.count == 50)
        #expect(recent.last?.hasSuffix("e59") == true)
    }

    @Test func socketToSpeakerEndToEnd() async throws {
        let player = FakePlayer()
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: FakeMic(), ducker: FakeDucker(), settle: .milliseconds(30))
        let p = path()
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog())
        try await core.start()
        defer { core.stop() }
        for text in ["one", "two", "three"] {
            #expect(try send(p, #"{"v":1,"type":"say","text":"\#(text)","kind":"done","session":"s"}"#) == #"{"ok":true}"#)
        }
        for _ in 0..<100 where await player.played.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await player.played == ["one", "two", "three"])
    }

    @Test func rejectsWhatItCannotRead() async throws {
        let speech = SpeechOut(synth: FakeSynth(), player: FakePlayer(), mic: FakeMic(), ducker: FakeDucker())
        let p = path()
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog())
        try await core.start()
        defer { core.stop() }
        #expect(try send(p, #"{"v":9,"type":"say"}"#) == #"{"ok":false,"reason":"version"}"#)
        #expect(try send(p, "garbage") == #"{"ok":false,"reason":"unreadable"}"#)
    }

    /// The plugin gave up after 0.2 s and said the line itself, so the app
    /// must not say it again when it reads the line late.
    @Test func aLineReadLateIsRefusedNotPlayed() async throws {
        let player = FakePlayer()
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: FakeMic(), ducker: FakeDucker())
        let p = path()
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog())
        try await core.start()
        defer { core.stop() }
        let old = Int(Date().timeIntervalSince1970 * 1000) - 1000
        let fresh = Int(Date().timeIntervalSince1970 * 1000)
        #expect(try send(p, #"{"sent":\#(old),"v":1,"type":"say","text":"late","kind":"done","session":"s"}"#)
            == #"{"ok":false,"reason":"late"}"#)
        #expect(try send(p, #"{"sent":\#(fresh),"v":1,"type":"say","text":"fresh","kind":"done","session":"s"}"#)
            == #"{"ok":true}"#)
        await speech.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await player.played == ["fresh"])
    }

    /// The plugin stopped waiting before the answer was written: the app must
    /// not keep the line.
    @Test func aLineWhoseAnswerCannotBeDeliveredIsDropped() async throws {
        let delivered = Counter()
        let p = path()
        let server = LineServer(path: p) { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return LineServer.Answer(reply: Data("ok".utf8)) { Task { await delivered.bump() } }
        }
        try server.start()
        defer { server.stop() }
        #expect(throws: LineClient.Failure.timeout) {
            try LineClient.send(path: p, line: Data("x".utf8), timeout: 0.1)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await delivered.n == 0)
        _ = try LineClient.send(path: p, line: Data("y".utf8), timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await delivered.n == 1)
    }

    @Test func theCoreFollowsTheMic() async throws {
        let player = FakePlayer(), mic = FakeMic()
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: FakeDucker(),
                               answered: { _ in false }, settle: .milliseconds(30))
        let p = path()
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog())
        try await core.start()
        defer { core.stop() }
        mic.set(true)
        _ = try send(p, #"{"v":1,"type":"say","text":"held line","kind":"done","session":"s"}"#)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await player.played.isEmpty)
        mic.set(false)
        for _ in 0..<100 where await player.played.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await player.played == ["held line"])
    }

    @Test func leavingNeedsDropsHeldNeeds() async throws {
        let player = FakePlayer(), mic = FakeMic()
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: FakeDucker(),
                               answered: { _ in false }, settle: .milliseconds(30))
        let p = path()
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog())
        try await core.start()
        defer { core.stop() }
        mic.set(true)
        _ = try send(p, #"{"v":1,"type":"status","session":"s","state":"needs"}"#)
        _ = try send(p, #"{"v":1,"type":"say","text":"needs you","kind":"need","session":"s"}"#)
        _ = try send(p, #"{"v":1,"type":"status","session":"s","state":"working"}"#)
        try await Task.sleep(for: .milliseconds(50))
        mic.set(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await player.played.isEmpty)
    }
}
