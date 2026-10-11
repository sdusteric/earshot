import Foundation
import Testing
@testable import EarshotKit

func chunk(_ v: Float) -> [Float] { [Float](repeating: v, count: 4096) }

actor FakeInput: AudioInput {
    private var cont: AsyncStream<[Float]>.Continuation?
    private(set) var starts = 0, stops = 0
    var isOpen: Bool { cont != nil }
    private var failing = false
    struct Down: Error {}
    func failStarts(_ on: Bool) { failing = on }
    /// The input ends its stream by itself, as MicInput does when a rebuild fails.
    func endStream() { cont?.finish(); cont = nil }
    func start() async throws -> AsyncStream<[Float]> {
        starts += 1
        if failing { throw Down() }
        let (s, c) = AsyncStream<[Float]>.makeStream()
        cont = c
        return s
    }
    func stop() async { stops += 1; cont?.finish(); cont = nil }
    func push(_ values: [Float]) { for v in values { cont?.yield(chunk(v)) } }
}

/// Speech is any chunk above 0.5. Two quiet chunks end it.
actor FakeGate: SpeechGate {
    private var inSpeech = false, quiet = 0
    private(set) var resets = 0
    func reset() async { inSpeech = false; quiet = 0; resets += 1 }
    func feed(_ c: [Float]) async -> SpeechEdge? {
        if (c.first ?? 0) > 0.5 {
            quiet = 0
            if !inSpeech { inSpeech = true; return .start }
            return nil
        }
        guard inSpeech else { return nil }
        quiet += 1
        if quiet >= 2 { inSpeech = false; return .end }
        return nil
    }
}

actor FakeSpotter: WakeSpotter {
    private(set) var calls = 0
    func heardWake(_ s: [Float], sensitivity: Int) async -> Bool { calls += 1; return s.contains(2) }
}

actor FakeTranscriber: Transcriber {
    private(set) var vocabularies: [[String]] = []
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String {
        vocabularies.append(vocabulary)
        var words: [String] = []
        if s.contains(2) { words.append("Hey Earshot,") }
        if s.contains(3) { words.append("what's everyone doing?") } else if s.contains(1) { words.append("run the tests") }
        return words.joined(separator: " ")
    }
    private(set) var prewarms = 0
    func prewarm() async { prewarms += 1 }
}

/// A mic whose start() waits until the test releases it.
actor SlowInput: AudioInput {
    private var cont: AsyncStream<[Float]>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var starts = 0, stops = 0
    var waiting: Int { waiters.count }
    var isOpen: Bool { cont != nil }
    func start() async throws -> AsyncStream<[Float]> {
        starts += 1
        await withCheckedContinuation { waiters.append($0) }
        let (s, c) = AsyncStream<[Float]>.makeStream()
        cont = c
        return s
    }
    func stop() async { stops += 1; cont?.finish(); cont = nil }
    func release() { waiters.forEach { $0.resume() }; waiters = [] }
}

/// A mic whose start() and stop() both wait until the test releases them.
actor GatedInput: AudioInput {
    private var cont: AsyncStream<[Float]>.Continuation?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var starts = 0
    var startsWaiting: Int { startWaiters.count }
    var stopsWaiting: Int { stopWaiters.count }
    var isOpen: Bool { cont != nil }
    func start() async throws -> AsyncStream<[Float]> {
        starts += 1
        await withCheckedContinuation { startWaiters.append($0) }
        let (s, c) = AsyncStream<[Float]>.makeStream()
        cont = c
        return s
    }
    func stop() async {
        await withCheckedContinuation { stopWaiters.append($0) }
        cont?.finish(); cont = nil
    }
    func releaseStarts() { startWaiters.forEach { $0.resume() }; startWaiters = [] }
    func releaseStops() { stopWaiters.forEach { $0.resume() }; stopWaiters = [] }
}

/// Reads like FakeTranscriber, records the clips, can say a fixed text, and
/// can hold its first answer until released.
actor ScriptTranscriber: Transcriber {
    private(set) var clips: [[Float]] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var holdFirst: Bool
    private let fixed: String?
    var waiting: Bool { waiter != nil }
    init(holdFirst: Bool = false, fixed: String? = nil) { self.holdFirst = holdFirst; self.fixed = fixed }
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String {
        clips.append(s)
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { waiter = $0 }
        }
        if let fixed { return fixed }
        var words: [String] = []
        if s.contains(2) { words.append("Hey Earshot,") }
        if s.contains(3) { words.append("what's everyone doing?") } else if s.contains(1) { words.append("run the tests") }
        return words.joined(separator: " ")
    }
    func prewarm() async {}
    func release() { waiter?.resume(); waiter = nil }
}

/// Holds the first chime until released.
actor SlowChimes: Chimes {
    private(set) var played: [Chime] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var held = false
    var waiting: Bool { waiter != nil }
    func play(_ c: Chime) async {
        played.append(c)
        if !held {
            held = true
            await withCheckedContinuation { waiter = $0 }
        }
    }
    func release() { waiter?.resume(); waiter = nil }
}

actor FakeChimes: Chimes {
    private(set) var played: [Chime] = []
    func play(_ c: Chime) async { played.append(c) }
}

actor FakeObserver: ListenObserver {
    private(set) var events: [String] = []
    func captureBegan(_ t: Listener.Trigger) async { events.append("began") }
    private(set) var heard: [Bool] = []
    func captureEnded(heard h: Bool) async { events.append("ended"); heard.append(h) }
}

actor Collected<T: Sendable> {
    private(set) var items: [T] = []
    func add(_ x: T) { items.append(x) }
}

/// Waits up to a second for a condition that other tasks make true.
func eventually(_ check: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await check()
}

@Suite struct ListenerTests {
    let input = FakeInput(), gate = FakeGate(), spotter = FakeSpotter(), transcriber = FakeTranscriber()
    let chimes = FakeChimes(), observer = FakeObserver()
    let heard = Collected<Listener.Utterance>()

    func make(_ t: Listener.Timing = .forTests, input custom: (any AudioInput)? = nil,
              transcriber customT: (any Transcriber)? = nil, chimes customC: (any Chimes)? = nil) async -> Listener {
        let l = Listener(input: custom ?? input, gate: gate, spotter: spotter, transcriber: customT ?? transcriber,
                         chimes: customC ?? chimes, timing: t)
        await l.setObserver(observer)
        let heard = self.heard
        Task { for await u in l.utterances { await heard.add(u) } }
        return l
    }

    @Test func wakeAndCommandInOneBreath() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.text == "what's everyone doing?")
        #expect(u?.trigger == .wake)
        #expect(await spotter.calls == 1)   // once per segment
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
        #expect(await observer.heard == [true])
    }

    @Test func theGateIsResetAfterACaptureThatHitTheLengthCap() async {
        let t = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150), minHold: .milliseconds(30),
                                maxCommandSamples: 4 * 4096, spotAtSamples: 2 * 4096, reopenDelay: .milliseconds(30))
        let l = await make(t)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        let before = await gate.resets
        await input.push([2, 3, 3, 3, 3, 3, 3, 3])   // one long breath: the cap ends it, no end edge
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await gate.resets > before)   // else the VAD stays triggered and the next wake is never started
    }

    @Test func theGateIsResetWhenAHotkeyCaptureFinishesWhileTheMicStaysOpen() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        await input.push([1, 1, 1])
        try? await Task.sleep(for: .milliseconds(40))
        let before = await gate.resets
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await gate.resets > before)
    }

    @Test func aFollowUpWindowPrewarmsTheTranscriber() async {
        let l = await make()
        await l.listenFollowUp(.reply)
        #expect(await eventually { await transcriber.prewarms == 1 })
    }

    @Test func speechWithoutTheWakePhraseIsIgnored() async {
        let l = await make()
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([1, 1, 1, 1, 1, 1, 1, 1, 0, 0])
        #expect(await eventually { await spotter.calls == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
    }

    @Test func wakeThenAPauseThenTheCommand() async {
        let l = await make()
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await chimes.played == [.listening] })
        await input.push([1, 1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func wakeThenSilenceCloses() async {
        let l = await make()
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func hotkeyHoldCapturesUntilRelease() async {
        let l = await make()
        await l.setVocabulary(["billing service"])
        await l.hotkeyDown()
        #expect(await eventually { await input.isOpen })
        try? await Task.sleep(for: .milliseconds(60))   // longer than minHold
        await input.push([1, 1, 1])
        try? await Task.sleep(for: .milliseconds(30))
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.trigger == .hotkey)
        #expect(await chimes.played == [.listening])
        #expect(await transcriber.vocabularies == [["billing service"]])
        #expect(await eventually { await !input.isOpen })   // opened for this command only
    }

    @Test func aShortHoldNeverChimes() async {
        let l = await make()
        await l.hotkeyDown()
        await l.hotkeyUp()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        #expect(await heard.items.isEmpty)
        #expect(await input.starts == 0)   // the mic never opened
    }

    @Test func aCancelledHoldSendsNothing() async {
        let l = await make()
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        await input.push([1, 1])
        await l.hotkeyCancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func aCallDropsTheCapture() async {
        let l = await make()
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        await input.push([1, 1])
        await l.setMicBusy(true)
        await l.hotkeyUp()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
        #expect(await observer.heard == [false])
        #expect(await eventually { await !input.isOpen })
    }

    @Test func followUpNeedsNoWakeWord() async {
        let l = await make()
        await l.listenFollowUp(.approval(id: "a1"))
        #expect(await eventually { await input.isOpen })
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.trigger == .followUp(.approval(id: "a1")))
        #expect(await chimes.played == [.listening])
    }

    @Test func followUpTimesOutQuietly() async {
        let l = await make()
        await l.listenFollowUp(.reply)
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
        #expect(await eventually { await !input.isOpen })
    }

    @Test func disarmingClosesTheMic() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setWakeArmed(false)
        #expect(await eventually { await !input.isOpen })
    }


    // MARK: - Reentrancy

    @Test func disarmingWhileTheMicOpensLeavesItClosed() async {
        let slow = SlowInput()
        let l = await make(input: slow)
        let arming = Task { await l.setWakeArmed(true) }
        #expect(await eventually { await slow.waiting == 1 })
        await l.setWakeArmed(false)
        await slow.release()
        await arming.value
        #expect(await eventually { await !slow.isOpen })
        #expect(await slow.stops == 1)
        #expect(await observer.events.isEmpty)
    }

    @Test func aCallWhileTheMicOpensLeavesItClosedAndStartsNothing() async {
        let slow = SlowInput()
        let l = await make(input: slow)
        let follow = Task { await l.listenFollowUp(.reply) }
        #expect(await eventually { await slow.waiting == 1 })
        await l.setMicBusy(true)
        await slow.release()
        await follow.value
        #expect(await eventually { await !slow.isOpen })
        #expect(await observer.events.isEmpty)
        #expect(await chimes.played.isEmpty)
    }

    @Test func twoOpensAtOnceStartTheMicOnce() async {
        let slow = SlowInput()
        let l = await make(input: slow)
        let arming = Task { await l.setWakeArmed(true) }
        #expect(await eventually { await slow.waiting == 1 })
        let follow = Task { await l.listenFollowUp(.reply) }
        try? await Task.sleep(for: .milliseconds(30))
        await slow.release()
        await arming.value
        await follow.value
        #expect(await slow.starts == 1)
        #expect(await slow.isOpen)
        #expect(await observer.events == ["began"])
    }

    @Test func releasingDuringTheChimeStillPairsTheObserver() async {
        let slowChimes = SlowChimes()
        let l = await make(chimes: slowChimes)
        await l.hotkeyDown()
        #expect(await eventually { await slowChimes.waiting })
        await l.hotkeyUp()
        await slowChimes.release()
        #expect(await eventually { await observer.events == ["began", "ended"] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func theHotkeyTakingOverAFollowUpEndsIt() async {
        let l = await make()
        await l.listenFollowUp(.reply)
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began", "ended", "began"] })
        await l.hotkeyUp()
        #expect(await eventually { await observer.events == ["began", "ended", "began", "ended"] })
    }

    @Test func aCommandStartedDuringTranscriptionIsNotOverwritten() async {
        let t = ScriptTranscriber(holdFirst: true)
        let l = await make(transcriber: t)
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await t.waiting })
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began", "began"] })
        await input.push([1, 1])
        try? await Task.sleep(for: .milliseconds(30))
        await t.release()   // "Hey Earshot," alone: must not replace the hotkey capture
        #expect(await eventually { await observer.events.count == 3 })
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.trigger == .hotkey)
        #expect(await eventually { await observer.events.count == 4 })
    }

    @Test func aResultAfterACallStartedIsDropped() async {
        let t = ScriptTranscriber(holdFirst: true)
        let l = await make(transcriber: t)
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 3, 3, 3, 0, 0])
        #expect(await eventually { await t.waiting })
        await l.setMicBusy(true)
        await t.release()
        #expect(await eventually { await observer.events == ["began", "ended"] })
        try? await Task.sleep(for: .milliseconds(250))   // longer than wakeSilence
        #expect(await heard.items.isEmpty)
        #expect(await observer.heard == [false])
        #expect(await chimes.played == [.listening])
        #expect(await !input.isOpen)
    }

    @Test func aWakeAloneThenACallDoesNotKeepListening() async {
        let t = ScriptTranscriber(holdFirst: true)
        let l = await make(transcriber: t)
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await t.waiting })
        await l.setMicBusy(true)
        await t.release()
        #expect(await eventually { await observer.events == ["began", "ended"] })
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func anAnswerNeverReachesBackBeforeTheWindow() async {
        let t = ScriptTranscriber()
        let l = await make(transcriber: t)
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([0.25])   // the tail of Earshot's own prompt
        try? await Task.sleep(for: .milliseconds(50))
        await l.listenFollowUp(.reply)
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let clip = await t.clips.first ?? []
        #expect(!clip.isEmpty)
        #expect(!clip.contains(0.25))
    }

    @Test func aLongHoldEndsAtTheCap() async {
        let t = ScriptTranscriber()
        let l = await make(transcriber: t)
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        await input.push([Float](repeating: 1, count: 45))   // 11.5 s, the ring holds 10 s
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await t.clips.first?.count == 38 * 4096)   // 10 s less the pre-roll, to a whole chunk
        await l.hotkeyUp()
    }

    @Test func aMicThatEndsByItselfIsReopenedOnce() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.endStream()
        #expect(await eventually { let n = await input.starts; let o = await input.isOpen; return n == 2 && o })
        #expect(await eventually { await l.currentPhase == .waiting })
    }

    @Test func aFailedReopenLeavesTheListenerClosedWithoutSpinning() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.failStarts(true)
        await input.endStream()
        #expect(await eventually { await input.starts == 2 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await input.starts == 2)
        #expect(await l.currentPhase == .off)
    }

    @Test func aMicThatEndsMidCaptureDropsTheCapture() async {
        let l = await make()
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        await input.push([1, 1])
        await input.endStream()
        #expect(await eventually { await observer.events == ["began", "ended"] })
        #expect(await heard.items.isEmpty)
        await l.hotkeyUp()
    }

    @Test func aSecondPressDoesNotConfirmTheFirstOnesHold() async {
        let slow = SlowInput()
        let timing = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150),
                                     minHold: .milliseconds(100))
        let l = await make(timing, input: slow)
        await l.hotkeyDown()
        #expect(await eventually { await slow.waiting == 1 })   // the first press is confirmed and waiting on the mic
        await l.hotkeyUp()
        await l.hotkeyDown()   // a second press, still inside its own minHold
        await slow.release()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        await l.hotkeyUp()
    }

    @Test func armingDuringAGiveUpStopStillOpensTheMic() async {
        let gated = GatedInput()
        let l = await make(input: gated)
        let arming = Task { await l.setWakeArmed(true) }
        #expect(await eventually { await gated.startsWaiting == 1 })
        await l.setWakeArmed(false)
        await gated.releaseStarts()
        #expect(await eventually { await gated.stopsWaiting == 1 })   // giving up, stop in flight
        let rearming = Task { await l.setWakeArmed(true) }
        try? await Task.sleep(for: .milliseconds(30))
        await gated.releaseStops()
        #expect(await eventually { await gated.startsWaiting == 1 })
        await gated.releaseStarts()
        await arming.value
        await rearming.value
        #expect(await eventually { await gated.isOpen })
        #expect(await gated.starts == 2)
    }

    @Test func theMicReopensAfterACall() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setMicBusy(true)
        #expect(await eventually { await !input.isOpen })
        await l.setMicBusy(false)
        #expect(await eventually { await input.isOpen })
        #expect(await input.starts == 2)
    }

    @Test func aCommandPrewarmsTheModel() async {
        let l = await make()
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await eventually { await transcriber.prewarms == 1 })
        await l.hotkeyCancel()
    }

    @Test func aWakeWithoutThePhraseIsAFalseWake() async {
        let t = ScriptTranscriber(fixed: "run the tests")
        let l = await make(transcriber: t)
        await l.setWakeArmed(true)
        _ = await eventually { await input.isOpen }
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await l.falseWakes == 1)
        #expect(await observer.heard == [false])
    }

    @Test(arguments: [
        ("Hey Earshot, what's everyone doing?", "what's everyone doing?"),
        ("hey ear shot tell billing to run the tests", "tell billing to run the tests"),
        ("Earshot. Stop billing.", "Stop billing."),
        ("Hey, Earshot", ""),
        ("Hey air shot, status", "status"),
    ])
    func stripsTheWakePhrase(_ said: String, _ rest: String) {
        #expect(Listener.stripWake(said) == rest)
    }

    @Test func leavesOtherTextAlone() {
        #expect(Listener.stripWake("run the tests") == nil)
    }
}

extension Listener.Timing {
    static let forTests = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150),
                                          minHold: .milliseconds(30), reopenDelay: .milliseconds(30))
}

extension Listener {
    /// The phase right now: the stream's first value.
    var currentPhase: Phase {
        get async {
            for await p in phaseChanges() { return p }
            return .off
        }
    }
}
