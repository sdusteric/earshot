import Foundation
import Testing
@testable import EarshotKit

actor FakeFollowUps: FollowUpListening {
    private(set) var calls: [Listener.FollowUp] = []
    private(set) var vocabulary: [String] = []
    func listenFollowUp(_ f: Listener.FollowUp, within: Duration?) async { calls.append(f) }
    func setVocabulary(_ v: [String]) async { vocabulary = v }
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
        let loop = VoiceLoop(followUps: followUps, parser: CommandParser(model: nil), dispatcher: dispatcher,
                             directory: directory, approvals: book, speech: speech, chimes: chimes, events: EventLog())
        let (stream, cont) = AsyncStream<Listener.Utterance>.makeStream()
        await loop.start(utterances: stream)
        return Rig(loop: loop, speech: speech, player: player, book: book, heard: cont)
    }

    func said(_ text: String, _ trigger: Listener.Trigger = .hotkey) -> Listener.Utterance {
        .init(text: text, trigger: trigger, endedAt: .now)
    }

    func approval(_ id: String = "1-1-1") -> AppMessage.Approval {
        .init(session: "s1", id: id, name: "billing service", what: "to run the migration",
              answer: "\(approvalsDir)/answer-s1-\(id)", secret: secret, pid: 1)
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

    @Test func theWakeWordRefreshesTheVocabulary() async {
        let r = await rig([agent("a", "finebrief")])
        await r.loop.captureBegan(.wake)
        #expect(await eventually { await followUps.vocabulary.contains("finebrief") })
    }
}
