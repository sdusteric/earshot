import Foundation
import Testing
@testable import EarshotKit

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

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

    /// Status messages are sent in the background, so they can arrive out of
    /// order: an older one must not overwrite a newer one.
    @Test func anOlderStatusDoesNotOverwriteANewerOne() async {
        let store = SessionStore()
        await store.apply(.init(session: "a", state: .needs, name: "blog", sent: 2000))
        await store.apply(.init(session: "a", state: .working, name: "blog", sent: 1000))
        #expect(await store.sessions.first?.state == .needs)
        await store.apply(.init(session: "a", state: .closed, sent: 1500))
        #expect(await store.sessions.isEmpty)   // closed always wins
    }

    /// A session that never says it closed (a crash, a closed terminal) goes
    /// after 6 quiet hours, as the plugin's own files do.
    @Test func quietSessionsExpireAfterSixHours() async {
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        let store = SessionStore(clock: { now.value })
        await store.apply(.init(session: "a", state: .working, name: "blog"))
        now.value = now.value.addingTimeInterval(6 * 3600 + 1)
        await store.apply(.init(session: "b", state: .working, name: "docs"))
        #expect(await store.sessions.map { $0.id } == ["b"])
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

    /// Away for an hour during a call: when you come back, the recap is said
    /// once the call ends, and the lines it covers are not said again.
    @Test func theRecapCoversTheLinesHeldWhileYouWereAway() async throws {
        let player = FakePlayer()
        let mic = FakeMic()
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: FakeDucker(), settle: .milliseconds(30))
        let p = path()
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog())
        try await core.start()
        defer { core.stop() }
        mic.set(true)
        await core.wentAway(at: Date().addingTimeInterval(-3600))
        _ = try send(p, #"{"v":1,"type":"status","session":"a","state":"done","name":"billing service"}"#)
        _ = try send(p, #"{"v":1,"type":"say","text":"Fixed the rounding bug.","kind":"done","session":"a","name":"billing service"}"#)
        _ = try send(p, #"{"v":1,"type":"say","text":"Hey, blog needs your OK.","kind":"need","session":"b","name":"blog"}"#)
        for _ in 0..<100 where await speech.state != .holding { try await Task.sleep(for: .milliseconds(10)) }
        let recap = await core.cameBack(speak: true)
        #expect(recap?.text == "While you were away: Blog needs you. Billing service finished.")
        mic.set(false)
        for _ in 0..<200 where await player.played.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await speech.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await player.played == ["While you were away: Blog needs you. Billing service finished."])
    }

    @Test func noRecapWhenItMayNotSpeak() async throws {
        let player = FakePlayer()
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: FakeMic(), ducker: FakeDucker())
        let p = path()
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog())
        try await core.start()
        defer { core.stop() }
        await core.wentAway(at: Date().addingTimeInterval(-3600))
        _ = try send(p, #"{"v":1,"type":"say","text":"Done.","kind":"done","session":"a","name":"blog","muted":true}"#)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await core.cameBack(speak: false) == nil)
        await speech.waitUntilIdle()
        #expect(await player.played.isEmpty)
    }

    /// Muted lines are never said. A session that needs you gets one banner,
    /// a new one only after it went back to work.
    @Test func mutedLinesMakeOneBannerForASessionThatNeedsYou() async throws {
        let player = FakePlayer()
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: FakeMic(), ducker: FakeDucker())
        let p = path()
        let banners = Banners(delay: .zero)
        let shown = Box<[Banner]>([]), removed = Box<[String]>([])
        await banners.connect(show: { shown.value.append($0) }, remove: { removed.value.append($0) })
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog(), banners: banners)
        try await core.start()
        defer { core.stop() }
        let need = #"{"v":1,"type":"say","text":"Hey, blog needs your OK.","kind":"need","session":"a","name":"blog","muted":true}"#
        #expect(try send(p, need) == #"{"ok":true}"#)
        _ = try send(p, #"{"v":1,"type":"say","text":"Fixed it.","kind":"done","session":"b","name":"docs","muted":true}"#)
        _ = try send(p, #"{"v":1,"type":"say","text":"It's been 2 minutes. Blog is still waiting on you.","kind":"need","session":"a","name":"blog","muted":true}"#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown.value == [Banner(session: "a", title: "Blog", body: "Hey, blog needs your OK.")])
        _ = try send(p, #"{"v":1,"type":"status","session":"a","state":"working","name":"blog"}"#)
        try await Task.sleep(for: .milliseconds(50))
        #expect(removed.value == ["a"])
        _ = try send(p, need)
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown.value.count == 2)
        await speech.waitUntilIdle()
        #expect(await player.played.isEmpty)
    }

    @Test func aLineHeldForACallMakesABanner() async throws {
        let mic = FakeMic()
        let speech = SpeechOut(synth: FakeSynth(), player: FakePlayer(), mic: mic, ducker: FakeDucker())
        let p = path()
        let banners = Banners(delay: .zero)
        let shown = Box<[Banner]>([])
        await banners.connect(show: { shown.value.append($0) }, remove: { _ in })
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog(), banners: banners)
        try await core.start()
        defer { core.stop() }
        mic.set(true)
        _ = try send(p, #"{"v":1,"type":"say","text":"Want one more round, or ship it?","kind":"done","session":"a","name":"blog"}"#)
        _ = try send(p, #"{"v":1,"type":"say","text":"Fixed it.","kind":"done","session":"b","name":"docs"}"#)
        for _ in 0..<100 where shown.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(shown.value.map(\.body) == ["Want one more round, or ship it?"])
    }

    @Test func noBannerWhenTheSettingIsOff() async throws {
        let speech = SpeechOut(synth: FakeSynth(), player: FakePlayer(), mic: FakeMic(), ducker: FakeDucker())
        let p = path()
        let banners = Banners(enabled: { false }, delay: .zero)
        let shown = Box<[Banner]>([])
        await banners.connect(show: { shown.value.append($0) }, remove: { _ in })
        let core = EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog(), banners: banners)
        try await core.start()
        defer { core.stop() }
        _ = try send(p, #"{"v":1,"type":"say","text":"Hey, blog needs your OK.","kind":"need","session":"a","muted":true}"#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown.value.isEmpty)
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

    func core(_ p: String, canListen: Bool, book: ApprovalBook) -> EarshotCore {
        let availability = ListenAvailability()
        availability.canListen = canListen
        let speech = SpeechOut(synth: FakeSynth(), player: FakePlayer(), mic: FakeMic(), ducker: FakeDucker())
        return EarshotCore(socketPath: p, speech: speech, sessions: SessionStore(), events: EventLog(),
                           approvals: book, availability: availability)
    }

    func approvalJSON(_ dir: String, sent: Double) -> String {
        #"{"v":1,"type":"approval","session":"s1","id":"1-2-3","name":"blog","what":"to run tests","answer":"\#(dir)/answer-s1-1-2-3","secret":"0123456789abcdef0123456789abcdef","pid":1,"sent":\#(Int(sent))}"#
    }

    /// Allow and Deny in the panel need no mic, so a prompt is taken even while
    /// Earshot can't listen (a call, no mic permission, listening off).
    @Test func takesAnApprovalWhetherOrNotItCanListen() async throws {
        let dir = NSTemporaryDirectory() + "ek-ap-\(UUID().uuidString.prefix(6))"
        for canListen in [true, false] {
            let p = path()
            let book = ApprovalBook(stateDir: dir, isAlive: { _ in true })
            let c = core(p, canListen: canListen, book: book)
            try await c.start()
            let now = Date().timeIntervalSince1970 * 1000
            #expect(try send(p, approvalJSON(dir, sent: now)) == #"{"ok":true}"#)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await book.current.count == 1)
            c.stop()
        }
    }

    /// A closed message is applied however late it is read: dropping it would
    /// leave the app listening for a prompt that is gone.
    @Test func aLateClosedIsStillApplied() async throws {
        let dir = NSTemporaryDirectory() + "ek-ap-\(UUID().uuidString.prefix(6))"
        let p = path()
        let book = ApprovalBook(stateDir: dir, isAlive: { _ in true })
        let c = core(p, canListen: true, book: book)
        try await c.start()
        _ = try send(p, approvalJSON(dir, sent: Date().timeIntervalSince1970 * 1000))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try send(p, #"{"v":1,"type":"approval","session":"s1","id":"1-2-3","state":"closed","by":"screen","sent":1000}"#) == #"{"ok":true}"#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await book.current.isEmpty)
        c.stop()
    }

    @Test func aLateOpenApprovalIsRefused() async throws {
        let dir = NSTemporaryDirectory() + "ek-ap-\(UUID().uuidString.prefix(6))"
        let p = path()
        let book = ApprovalBook(stateDir: dir, isAlive: { _ in true })
        let c = core(p, canListen: true, book: book)
        try await c.start()
        #expect(try send(p, approvalJSON(dir, sent: Date().timeIntervalSince1970 * 1000 - 1000)) == #"{"ok":false,"reason":"late"}"#)
        c.stop()
    }
}
