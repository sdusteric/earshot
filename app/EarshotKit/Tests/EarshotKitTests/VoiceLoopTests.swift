import Foundation
import Testing
@testable import EarshotKit

actor FakeFollowUps: FollowUpListening {
    private(set) var calls: [Listener.FollowUp] = []
    private(set) var vocabulary: [String] = []
    private var delay: Duration = .zero
    /// Opening a window takes this long, like starting the recognizer.
    func slow(_ d: Duration) { delay = d }
    func listenFollowUp(_ f: Listener.FollowUp, within: Duration?) async {
        calls.append(f)
        if delay > .zero { try? await Task.sleep(for: delay) }
    }
    func setVocabulary(_ v: [String]) async { vocabulary = v }
    private(set) var speaking: [String?] = []
    func setSpeaking(_ text: String?) async { speaking.append(text) }
}

/// Counts the loop's begin and end calls on the real SpeechOut.
actor CountingSpeaker: LineSpeaker {
    let inner: SpeechOut
    private(set) var begins = 0, ends = 0
    init(_ inner: SpeechOut) { self.inner = inner }
    func enqueue(_ line: SpokenLine) async { await inner.enqueue(line) }
    func beginListening() async { begins += 1; await inner.beginListening() }
    func endListening() async { ends += 1; await inner.endListening() }
    func lineEvents() async -> AsyncStream<SpeechOut.LineEvent> { await inner.lineEvents() }
    func holdAfter(_ id: UUID) async { await inner.holdAfter(id) }
    func releaseHold() async { await inner.releaseHold() }
}

@Suite struct VoiceLoopTests {
    let mic = FakeMic()
    let ducker = FakeDucker()
    let followUps = FakeFollowUps()
    let chimes = FakeChimes()
    let transport = FakeTransport()
    let store = SessionStore()
    let approvalsDir: String = {
        let d = NSTemporaryDirectory() + "ek-vl-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    let secret = "0123456789abcdef0123456789abcdef"

    struct Rig {
        let loop: VoiceLoop
        let speech: SpeechOut
        let player: FakePlayer
        let book: ApprovalBook
        let heard: AsyncStream<Listener.Utterance>.Continuation
        let counter: CountingSpeaker
    }

    func rig(_ agents: [AgentEntry], blocking: Bool = false) async -> Rig {
        let player = FakePlayer(blocking: blocking)
        let speech = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: ducker, settle: .milliseconds(30))
        await speech.start()
        let runner = FakeRunner(agents)
        let directory = SessionDirectory(runner: runner, store: store, labeler: Labeler(model: nil, liveDir: NSTemporaryDirectory()),
                                         claudeJSON: "/nonexistent")
        await directory.refresh()
        let book = ApprovalBook(stateDir: approvalsDir, isAlive: { _ in true })
        let dispatcher = Dispatcher(directory: directory, store: store, transport: transport, runner: runner, approvals: book,
                                    say: { _ in }, receiptTimeout: .seconds(60))
        let counter = CountingSpeaker(speech)
        let loop = VoiceLoop(followUps: followUps, parser: CommandParser(model: nil), dispatcher: dispatcher,
                             directory: directory, approvals: book, speech: counter, chimes: chimes, events: EventLog())
        let (stream, cont) = AsyncStream<Listener.Utterance>.makeStream()
        await loop.start(utterances: stream)
        return Rig(loop: loop, speech: speech, player: player, book: book, heard: cont, counter: counter)
    }

    func said(_ text: String, _ trigger: Listener.Trigger = .hotkey) -> Listener.Utterance {
        .init(text: text, trigger: trigger, endedAt: .now)
    }

    func approval(_ id: String = "1-1-1", session: String = "s1") -> AppMessage.Approval {
        .init(session: session, id: id, name: "billing service", what: "to run the migration",
              answer: "\(approvalsDir)/answer-\(session)-\(id)", secret: secret, pid: 1)
    }

    @Test func aCommandIsCarriedOutAndConfirmed() async {
        let r = await rig([agent("b", "blog", pid: 11)])
        let player = r.player
        r.heard.yield(said("Tell blog to deploy."))
        #expect(await eventually { await player.played == ["Sent to blog."] })
        #expect(await transport.sent.map(\.text) == ["deploy"])
    }

    @Test func notUnderstoodSendsNothing() async {
        let r = await rig([agent("b", "blog")])
        let player = r.player
        r.heard.yield(said("Banana."))
        #expect(await eventually { await player.played == ["Sorry, I didn't get that."] })
        #expect(await transport.sent.isEmpty)
    }

    /// Earshot must not hear its own "needs your OK" line as the answer.
    @Test func approvalWindowOpensOnlyAfterTheLineFinished() async {
        let r = await rig([agent("s1", "billing-service")], blocking: true)
        await r.book.apply(approval())
        await r.speech.enqueue(SpokenLine(text: "Hey, billing service needs your OK to run the migration.", kind: .need, session: "s1"))
        let player = r.player
        #expect(await eventually { await player.isPlaying })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await followUps.calls.isEmpty)
        await player.finish()
        #expect(await eventually { await followUps.calls == [.approval(id: "1-1-1")] })
    }

    @Test func noWindowWithoutAnOpenPrompt() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.speech.enqueue(SpokenLine(text: "Hey, billing service needs your input.", kind: .need, session: "s1"))
        await r.speech.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await followUps.calls.isEmpty)
    }

    @Test func yesInTheWindowApproves() async throws {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        let player = r.player
        r.heard.yield(said("Yeah.", .followUp(.approval(id: "1-1-1"))))
        #expect(await eventually { await player.played == ["Approved."] })
        #expect(await chimes.played == [.confirm])
        #expect(try String(contentsOfFile: "\(approvalsDir)/answer-s1-1-1-1", encoding: .utf8) == "allow \(secret)\n")
    }

    /// The spec: the wake word does not approve on its own.
    @Test func aWakeWordYesDoesNotApprove() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        let player = r.player
        r.heard.yield(said("Yes.", .wake))
        #expect(await eventually { await player.played == ["Hold the hotkey to answer it."] })
        #expect(!FileManager.default.fileExists(atPath: "\(approvalsDir)/answer-s1-1-1-1"))
        #expect(await r.book.current.count == 1)
    }

    @Test func aHotkeyYesApproves() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        let player = r.player
        r.heard.yield(said("Yes.", .hotkey))
        #expect(await eventually { await player.played == ["Approved."] })
        #expect(FileManager.default.fileExists(atPath: "\(approvalsDir)/answer-s1-1-1-1"))
    }

    @Test func yesAfterTheDialogClosedSaysNothing() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        await r.book.apply(.init(session: "s1", id: "1-1-1", state: "closed", by: "screen"))
        r.heard.yield(said("Yes.", .followUp(.approval(id: "1-1-1"))))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await r.player.played.isEmpty)
        #expect(await chimes.played.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: "\(approvalsDir)/answer-s1-1-1-1"))
    }

    @Test func otherWordsInTheWindowDoNothing() async {
        let r = await rig([agent("s1", "billing-service")])
        await r.book.apply(approval())
        r.heard.yield(said("Yes but use the other file.", .followUp(.approval(id: "1-1-1"))))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await r.player.played.isEmpty)
        #expect(await r.book.current.count == 1)
    }

    @Test func whichOneThenTheAnswer() async {
        let r = await rig([agent("a", "billing-service", name: "Fix refund rounding", pid: 10),
                           agent("b", "billing-service", name: "Invoice export", pid: 11)])
        let player = r.player
        r.heard.yield(said("Tell billing to run the tests."))
        #expect(await eventually { await followUps.calls == [.reply] })   // after the question was said
        #expect(await player.played == ["Billing service has two: Fix refund rounding and Invoice export. Which one?"])
        r.heard.yield(said("Invoice export.", .followUp(.reply)))
        #expect(await eventually { await transport.sent.map(\.pid) == [11] })
    }

    /// Other audio stays low from the wake word through the answer.
    @Test func duckingSpansTheCommandAndItsAnswer() async {
        let r = await rig([agent("b", "blog")])
        await r.loop.captureBegan(.hotkey)
        await r.loop.captureEnded(heard: true)
        #expect(await ducker.ends == 0)
        r.heard.yield(said("What's everyone doing?"))
        let player = r.player
        #expect(await eventually { await player.played.count == 1 })
        await r.speech.waitUntilIdle()
        #expect(await ducker.ends == 1)
    }

    @Test func aCaptureWithNothingHeardEndsListeningAtOnce() async {
        let r = await rig([agent("b", "blog")])
        await r.loop.captureBegan(.wake)
        await r.loop.captureEnded(heard: false)
        #expect(await ducker.ends == 1)
    }

    @Test func twoOverlappingHeardCapturesEndListeningTwice() async {
        let r = await rig([agent("b", "blog")])
        await r.loop.captureBegan(.hotkey)
        await r.loop.captureEnded(heard: true)
        await r.loop.captureBegan(.hotkey)
        await r.loop.captureEnded(heard: true)
        r.heard.yield(said("What's everyone doing?"))
        r.heard.yield(said("What's everyone doing?"))
        let player = r.player
        #expect(await eventually { await player.played.count == 2 })
        await r.speech.waitUntilIdle()
        // Both captures are paid: the ducking ended, and not before the second answer.
        #expect(await ducker.ends == 1)
        // The count is back to zero: a new capture that hears nothing ends at once.
        await r.loop.captureBegan(.wake)
        await r.loop.captureEnded(heard: false)
        #expect(await ducker.ends == 2)
    }

    /// Prompt A closes on screen and B opens for the same session during A's line.
    @Test func theWindowIsOnlyForThePromptTheLineWasAbout() async {
        let r = await rig([agent("s1", "billing-service")], blocking: true)
        await r.book.apply(approval("1-1-1"))
        await r.speech.enqueue(SpokenLine(text: "Hey, billing service needs your OK to run the migration.", kind: .need, session: "s1"))
        let player = r.player
        #expect(await eventually { await player.isPlaying })
        await r.book.apply(.init(session: "s1", id: "1-1-1", state: "closed", by: "screen"))
        await r.book.apply(approval("2-2-2"))
        await player.finish()
        await r.speech.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await followUps.calls.isEmpty)
    }

    /// The next line waits for the window of the one before it.
    @Test func theNextLineWaitsForTheWindow() async {
        let r = await rig([agent("s1", "billing-service"), agent("s2", "blog")], blocking: true)
        await r.book.apply(approval("1-1-1"))
        await r.book.apply(approval("2-2-2", session: "s2"))
        await r.speech.enqueue(SpokenLine(text: "one needs your OK", kind: .need, session: "s1"))
        await r.speech.enqueue(SpokenLine(text: "two needs your OK", kind: .need, session: "s2"))
        let player = r.player
        await followUps.slow(.milliseconds(300))
        #expect(await eventually { await player.isPlaying })
        await player.finish()
        #expect(await eventually { await followUps.calls == [.approval(id: "1-1-1")] })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await player.played.count == 1)   // still waiting for the window to open
        #expect(await eventually { await player.played.count == 2 })
        #expect(await followUps.calls.first == .approval(id: "1-1-1"))
        #expect(await eventually { await player.isPlaying })
        await player.finish()
        #expect(await eventually { await followUps.calls.count == 2 })
    }

    @Test func listeningIsNeverEndedMoreOftenThanItBegan() async {
        let r = await rig([agent("b", "blog")])
        await r.loop.captureBegan(.hotkey)
        await r.loop.captureEnded(heard: true)
        await r.loop.captureBegan(.wake)
        await r.loop.captureEnded(heard: true)
        r.heard.yield(said("What's everyone doing?"))
        r.heard.yield(said("What's everyone doing?"))
        let player = r.player
        #expect(await eventually { await player.played.count == 2 })
        await r.speech.waitUntilIdle()
        let c = r.counter
        #expect(await c.begins == 2)
        #expect(await c.ends == 2)
    }

    /// The listener knows what Earshot says, so a line naming "earshot" never wakes it.
    @Test func theListenerIsToldWhatEarshotSays() async {
        let r = await rig([agent("b", "blog")])
        await r.speech.enqueue(SpokenLine(text: "Hey, earshot needs your OK.", kind: .need, session: "x"))
        #expect(await eventually { await followUps.speaking == ["Hey, earshot needs your OK.", nil] })
    }

    @Test func theWakeWordRefreshesTheVocabulary() async {
        let r = await rig([agent("a", "finebrief")])
        await r.loop.captureBegan(.wake)
        #expect(await eventually { await followUps.vocabulary.contains("finebrief") })
    }
}
