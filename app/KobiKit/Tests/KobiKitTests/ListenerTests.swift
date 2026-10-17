import Foundation
import Testing
@testable import KobiKit

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

/// A window with a 2 in it scores `hit`, any other far below every threshold.
actor FakeSpotter: WakeSpotter {
    private(set) var calls = 0
    /// 0 fires the spotter and clears the strict threshold for a wake no recognizer judged.
    private(set) var hit: Float = 0
    func setHit(_ score: Float) { hit = score }
    func wakeScore(_ s: [Float]) async -> Float? { calls += 1; return s.contains(2) ? hit : -100 }
}

actor FakeTranscriber: Transcriber {
    private(set) var vocabularies: [[String]] = []
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String {
        vocabularies.append(vocabulary)
        var words: [String] = []
        if s.contains(2) { words.append("Hey Kobi,") }
        if s.contains(3) { words.append("what's everyone doing?") } else if s.contains(1) { words.append("run the tests") }
        return words.joined(separator: " ")
    }
    private(set) var prewarms = 0
    func prewarm() async { prewarms += 1 }
}

/// A second recognizer that hears fixed words, after `delay`.
actor FakeSecondHearing: SecondHearing {
    let words: String
    let delay: Duration
    private(set) var names: [[String]] = []
    private(set) var prepares = 0
    init(words: String, delay: Duration = .zero) { self.words = words; self.delay = delay }
    func hear(_ samples: [Float], names: [String]) async -> String? {
        self.names.append(names)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return words
    }
    func prepare() async { prepares += 1 }
}

/// Like a name boost that turns "doing" into a session called "wedding".
actor BoostTranscriber: Transcriber {
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String {
        try await transcribeBoth(s, vocabulary: vocabulary).text
    }
    func transcribeBoth(_ s: [Float], vocabulary: [String]) async throws -> (text: String, plain: String?) {
        let wake = s.contains(2) ? "Hey Kobi, " : ""
        return (wake + "how are you wedding", wake + "how are you doing")
    }
    func prewarm() async {}
}

/// Hears the same words in every clip, boosted and not.
actor FixedTranscriber: Transcriber {
    let text: String, plain: String?
    init(text: String, plain: String?) { self.text = text; self.plain = plain }
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String { text }
    func transcribeBoth(_ s: [Float], vocabulary: [String]) async throws -> (text: String, plain: String?) { (text, plain) }
    func prewarm() async {}
}

/// Writes `boosted` when a session it boosts sounds like `name`, and `plain` without it, as
/// Parakeet's boost does; keeps the vocabularies it was given.
actor BoostingTranscriber: Transcriber {
    let name: String, boosted: String, plain: String
    private(set) var vocabularies: [[String]] = []
    init(name: String, boosted: String, plain: String) { self.name = name; self.boosted = boosted; self.plain = plain }
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String { try await transcribeBoth(s, vocabulary: vocabulary).text }
    func transcribeBoth(_ s: [Float], vocabulary: [String]) async throws -> (text: String, plain: String?) {
        vocabularies.append(vocabulary)
        return vocabulary.contains(name) ? (boosted, plain) : (plain, nil)
    }
    func prewarm() async {}
}

/// Hears `wake` in a clip with the wake in it (a 2), after `wakeDelay`, and `command` in any other.
actor WakeAndCommandTranscriber: Transcriber {
    let wake: String, command: String, wakeDelay: Duration
    private(set) var clips: [[Float]] = []
    init(wake: String, command: String, wakeDelay: Duration = .zero) {
        self.wake = wake; self.command = command; self.wakeDelay = wakeDelay
    }
    func transcribe(_ s: [Float], vocabulary: [String]) async throws -> String {
        clips.append(s)
        guard s.contains(2) else { return command }
        if wakeDelay > .zero { try? await Task.sleep(for: wakeDelay) }
        return wake
    }
    func prewarm() async {}
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
        if s.contains(2) { words.append("Hey Kobi,") }
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

/// Hears fixed words in a wake's head, and can hold its answer until released.
actor FakeConfirmer: WakeConfirmer {
    private let words: String?
    private var hold: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var heads: [[Float]] = []
    var waiting: Bool { waiter != nil }
    init(words: String?, hold: Bool = false) { self.words = words; self.hold = hold }
    func headText(_ head: [Float]) async -> String? {
        heads.append(head)
        if hold { await withCheckedContinuation { waiter = $0 } }
        return words
    }
    func release() { hold = false; waiter?.resume(); waiter = nil }
}

actor Collected<T: Sendable> {
    private(set) var items: [T] = []
    func add(_ x: T) { items.append(x) }
}

/// Waits up to a second (or `within`) for a condition that other tasks make true.
func eventually(within limit: Duration = .seconds(1), _ check: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
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
              transcriber customT: (any Transcriber)? = nil, second: (any SecondHearing)? = nil,
              chimes customC: (any Chimes)? = nil, confirmer: any WakeConfirmer = PassThroughConfirmer()) async -> Listener {
        let l = Listener(input: custom ?? input, gate: gate, spotter: spotter, transcriber: customT ?? transcriber,
                         second: second, confirmer: confirmer, chimes: customC ?? chimes, timing: t)
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
                                maxCommandSamples: 4 * 4096, spotAtSamples: 2 * 4096, reopenDelay: .milliseconds(30), soundWait: .zero)
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
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
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
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
        await input.push([1, 1])
        await l.hotkeyCancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
    }

    @Test func aCallDropsTheCapture() async {
        let l = await make()
        await l.hotkeyDown()
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
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

    @Test func clickingTheOrbHearsOneCommandWithoutTheWakeWord() async {
        let l = await make()
        await l.tapToTalk()
        #expect(await eventually { await input.isOpen })
        try? await Task.sleep(for: .milliseconds(80))   // past the chime
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.trigger == .tap)
        #expect(await chimes.played.first == .listening)
        #expect(await spotter.calls == 0)
    }

    /// A click hears the words without the name boost too, so "doing" is not taken as a session's name.
    @Test func aClickedCommandKeepsTheUnboostedWords() async {
        let l = await make(transcriber: BoostTranscriber())
        await l.tapToTalk()
        #expect(await eventually { await input.isOpen })
        try? await Task.sleep(for: .milliseconds(80))
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.text == "how are you wedding")
        #expect(u?.plain == "how are you doing")
    }

    /// After "Hey Kobi" the unboosted words lose the wake phrase, as the boosted ones do.
    @Test func aWakeCommandKeepsTheUnboostedWordsWithoutTheWakePhrase() async {
        let l = await make(transcriber: BoostTranscriber())
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.text == "how are you wedding")
        #expect(u?.plain == "how are you doing")
    }

    /// The second hearing's words ride along with the first's.
    @Test func aCommandCarriesTheSecondHearing() async {
        let other = FakeSecondHearing(words: "how are the other sessions going")
        let l = await make(second: other)
        await l.setVocabulary(["kobi"])
        await l.tapToTalk()
        #expect(await eventually { await input.isOpen })
        #expect(await eventually { await other.prepares == 1 })   // readied when the mic opens
        try? await Task.sleep(for: .milliseconds(80))
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.text == "run the tests")
        #expect(u?.second == "how are the other sessions going")
        #expect(await other.names == [["kobi"]])
    }

    /// A second hearing that runs long is left out: it never holds up the command.
    @Test func aSlowSecondHearingIsLeftOut() async {
        var t = Listener.Timing.forTests
        t.secondGrace = .milliseconds(50)
        let l = await make(t, second: FakeSecondHearing(words: "late", delay: .seconds(5)))
        let start = ContinuousClock.now
        await l.tapToTalk()
        #expect(await eventually { await input.isOpen })
        try? await Task.sleep(for: .milliseconds(80))
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.second == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// After "Hey Kobi" the second hearing loses the wake phrase too.
    @Test func aWakeCommandsSecondHearingLosesTheWakePhrase() async {
        let l = await make(second: FakeSecondHearing(words: "Hey Kobi, what's everyone doing?"))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.second == "what's everyone doing?")
    }

    /// The ring holds the 15 s cap, not 10 s: a long prompt is heard whole.
    @Test func aHotkeyCommandCanRunPastTenSeconds() async {
        let st = ScriptTranscriber(fixed: "words")
        let l = await make(transcriber: st)
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        await input.push([Float](repeating: 1, count: 50))   // 12.8 s
        #expect(await eventually { await l.capturedSamples == 50 * 4096 })
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.tooLong == false)
        #expect(await st.clips.first?.count == 50 * 4096)
    }

    /// The wake word keeps the mic open, but a command's audio does not stay in the ring once heard.
    @Test func aCommandsAudioIsErasedOnceHeard() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        await input.push([1, 1, 1])
        #expect(await eventually { await l.capturedSamples == 3 * 4096 })
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await input.isOpen)
        #expect(await l.heldAudio.count == 3 * 4096)
        #expect(await l.heldAudio.allSatisfy { $0 == 0 })
    }

    @Test func noAudioIsKeptOnceTheMicCloses() async {
        let l = await make()
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        await input.push([1, 1, 1])
        #expect(await eventually { await l.capturedSamples == 3 * 4096 })
        await l.hotkeyUp()
        #expect(await eventually { await !input.isOpen })
        #expect(await l.heldAudio.isEmpty)
    }

    /// A new mic choice reopens the mic the wake word holds open.
    @Test func aNewMicChoiceReopensAnOpenMic() async {
        let l = await make()
        await l.setInputDevice(nil)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setInputDevice(nil)   // no change: nothing happens
        #expect(await input.starts == 1)
        await l.setInputDevice("USB-1")
        #expect(await eventually { let n = await input.starts; let o = await input.isOpen; return n == 2 && o })
        #expect(await l.currentPhase == .waiting)
    }

    /// While a command is being heard the choice waits, then applies when the command ends.
    @Test func aNewMicChoiceWaitsForTheCommandBeingHeard() async {
        let l = await make()
        await l.setInputDevice(nil)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        await l.setInputDevice("USB-1")
        #expect(await input.starts == 1)
        await input.push([1, 1])
        #expect(await eventually { await l.capturedSamples == 2 * 4096 })
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await eventually { let n = await input.starts; let o = await input.isOpen; return n == 2 && o })
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

    /// The chime waits for the mic's first audio. Zeros count: a webcam's noise
    /// gate sends them until you talk, and the chime must not wait for your voice.
    @Test func aHoldChimesOnceTheMicSendsAudio() async {
        var t = Listener.Timing.forTests
        t.soundWait = .seconds(2)
        let l = await make(t)
        await l.hotkeyDown()
        #expect(await eventually { await input.isOpen })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await observer.events.isEmpty)
        #expect(await chimes.played.isEmpty)
        await input.push([0])
        #expect(await eventually { await observer.events == ["began"] })
        #expect(await chimes.played == [.listening])
        await input.push([1, 1])
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
    }

    /// A mic that sends nothing still gets its chime after the wait, so a hold is never silent.
    @Test func aMicThatSendsNothingStillChimesAfterTheWait() async {
        var t = Listener.Timing.forTests
        t.soundWait = .milliseconds(300)
        let l = await make(t)
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        #expect(await chimes.played == [.listening])
        await l.hotkeyCancel()
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
        await t.release()   // "Hey Kobi," alone: must not replace the hotkey capture
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

    /// A transcriber that never answers can't leave Kobi listening, holding its
    /// lines back: the capture ends unheard after the limit.
    @Test func aHungTranscriberEndsTheCaptureUnheard() async {
        let t = ScriptTranscriber(holdFirst: true)
        var timing = Listener.Timing.forTests
        timing.transcribeLimit = .milliseconds(100)
        let l = await make(timing, transcriber: t)
        await l.hotkeyDown()
        #expect(await eventually { await observer.events.contains("began") })
        await input.push([1, 1])
        await l.hotkeyUp()
        #expect(await eventually { await observer.events == ["began", "ended"] })
        #expect(await observer.heard == [false])
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played.last == .closed)
        await t.release()
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
        await input.push([0.25])   // the tail of Kobi's own prompt
        try? await Task.sleep(for: .milliseconds(50))
        await l.listenFollowUp(.reply)
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let clip = await t.clips.first ?? []
        #expect(!clip.isEmpty)
        #expect(!clip.contains(0.25))
    }

    /// Cut off mid-sentence, the command would be sent half said: it is dropped instead.
    @Test func aLongHoldEndsAtTheCap() async {
        let t = ScriptTranscriber()
        let l = await make(transcriber: t)
        await l.hotkeyDown()
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
        await input.push([Float](repeating: 1, count: 60))   // 15.4 s, past the 15 s cap
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.tooLong == true)
        #expect(u?.text == "")
        #expect(await t.clips.isEmpty)   // the cut text is never transcribed
        #expect(await chimes.played == [.listening, .closed])
        #expect(await observer.heard == [true])   // a line follows: listening ends after it
        await l.hotkeyUp()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await heard.items.count == 1)   // the later release does nothing
        #expect(await chimes.played == [.listening, .closed])
        #expect(await eventually { await !input.isOpen })
    }

    @Test func aLongWakeCommandIsTooLong() async {
        let t = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150), minHold: .milliseconds(30),
                                maxCommandSamples: 4 * 4096, spotAtSamples: 2 * 4096, reopenDelay: .milliseconds(30), soundWait: .zero)
        let l = await make(t)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 3])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.tooLong == true)
        #expect(await heard.items.first?.trigger == .wake)
    }

    /// Talk that only seemed to start with the wake word stays silent at the cap.
    @Test func aFalseWakeAtTheCapSaysNothing() async {
        let st = ScriptTranscriber(fixed: "and then the tests ran")
        let t = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150), minHold: .milliseconds(30),
                                maxCommandSamples: 4 * 4096, spotAtSamples: 2 * 4096, reopenDelay: .milliseconds(30), soundWait: .zero)
        let l = await make(t, transcriber: st)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 3])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await l.falseWakes == 1)
        #expect(await observer.heard == [false])
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
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
        await input.push([1, 1])
        await input.endStream()
        #expect(await eventually { await observer.events == ["began", "ended"] })
        #expect(await heard.items.isEmpty)
        await l.hotkeyUp()
    }

    @Test func aSecondPressDoesNotConfirmTheFirstOnesHold() async {
        let slow = SlowInput()
        let timing = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150),
                                     minHold: .milliseconds(100), soundWait: .zero)
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

    /// A press during the release tail ends the first command at once and starts the next one.
    @Test func aSecondPressDuringTheReleaseTailStartsANewCapture() async {
        var timing = Listener.Timing.forTests
        timing.releaseTail = .milliseconds(600)
        let l = await make(timing)
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        await input.push([1, 1])
        #expect(await eventually { await l.capturedSamples == 2 * 4096 })
        await l.hotkeyUp()
        await l.hotkeyDown()   // inside the tail
        try? await Task.sleep(for: .milliseconds(200))   // well before the tail would end
        #expect(await heard.items.map(\.text) == ["run the tests"])
        #expect(await observer.events == ["began", "ended", "began"])
        await input.push([1, 1])
        #expect(await eventually { await l.capturedSamples == 4 * 4096 })
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 2 })
        #expect(await observer.events == ["began", "ended", "began", "ended"])
    }

    /// Two commands never share audio: the second starts where the first ended, not 0.3 s before.
    @Test func aSecondCommandDoesNotReuseTheFirstOnesAudio() async {
        var timing = Listener.Timing.forTests
        timing.releaseTail = .milliseconds(600)
        let st = ScriptTranscriber(fixed: "words")
        let l = await make(timing, transcriber: st)
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        await input.push([1, 1])
        #expect(await eventually { await l.capturedSamples == 2 * 4096 })
        await l.hotkeyUp()
        await l.hotkeyDown()   // inside the tail
        #expect(await eventually { await observer.events == ["began", "ended", "began"] })
        await input.push([3, 3])
        #expect(await eventually { await l.capturedSamples == 4 * 4096 })
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 2 })
        let clips = await st.clips
        #expect(clips.count == 2)
        #expect(clips[1].allSatisfy { $0 == 3 })   // none of the first command's audio
        #expect(clips[1].count == 2 * 4096)
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
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
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

    // MARK: - Edges of a capture

    /// The chime and the tail of Kobi's line are not your answer.
    @Test func speechInTheFirstMomentOfAFollowUpIsIgnored() async {
        let st = ScriptTranscriber()
        var timing = Listener.Timing.forTests
        timing.followUp = .seconds(2)
        timing.followUpSettle = .milliseconds(250)
        let l = await make(timing, transcriber: st)
        await l.listenFollowUp(.reply)
        await input.push([0.75, 0, 0])   // right away: the tail of Kobi's line
        try? await Task.sleep(for: .milliseconds(350))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played == [.listening])   // still listening
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(!(await st.clips.first ?? [0.75]).contains(0.75))
    }

    /// The last word often lands just after the key is let go.
    @Test func aReleaseKeepsListeningBriefly() async {
        let l = await make()
        await l.hotkeyDown()
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
        await input.push([1, 1])
        try? await Task.sleep(for: .milliseconds(30))
        await l.hotkeyUp()
        await input.push([3])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "what's everyone doing?")
    }

    @Test func reopeningTheMicForgetsTheOldAudio() async {
        let st = ScriptTranscriber()
        let l = await make(transcriber: st)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([0.25])
        try? await Task.sleep(for: .milliseconds(30))
        await l.setWakeArmed(false)
        #expect(await eventually { await !input.isOpen })
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(!(await st.clips.first ?? [0.25]).contains(0.25))   // the pre-roll reached nothing from before
    }

    // MARK: - A locked or sleeping Mac

    @Test func whileBlockedNoFollowUpOrHotkeyOpensTheMic() async {
        let l = await make()
        await l.setBlocked(true)
        await l.listenFollowUp(.approval(id: "a1"))
        await l.hotkeyDown()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await input.starts == 0)
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        await l.hotkeyUp()
    }

    @Test func blockingMidCaptureDropsIt() async {
        let l = await make()
        await l.hotkeyDown()
        // Held past minHold: wait for the capture itself, not a fixed time a busy machine can overrun.
        #expect(await eventually { await observer.events.contains("began") })
        await input.push([1, 1])
        await l.setBlocked(true)
        await l.hotkeyUp()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
        #expect(await observer.heard == [false])
        #expect(await eventually { await !input.isOpen })
    }

    @Test func theArmedMicReopensWhenUnblocked() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setBlocked(true)
        #expect(await eventually { await !input.isOpen })
        await l.setWakeArmed(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await !input.isOpen)   // arming while blocked keeps it closed
        await l.setBlocked(false)
        #expect(await eventually { await input.isOpen })
    }

    // MARK: - Confirming a wake

    /// Timing for a confirmer the test holds: long enough that the limit never passes it first.
    static var confirmTiming: Listener.Timing {
        var t = Listener.Timing.forTests
        t.confirmLimit = .seconds(10)
        return t
    }

    /// Every phase the listener goes through, from now on.
    func phases(of l: Listener) async -> Collected<Listener.Phase> {
        let seen = Collected<Listener.Phase>()
        let stream = await l.phaseChanges()
        Task { for await p in stream { await seen.add(p) } }
        return seen
    }

    /// A sentence that only sounded like the wake word stays silent: no chime, no
    /// orb, no barge-in of the line Kobi is saying.
    @Test func aRejectedWakeIsSilent() async {
        let confirmer = FakeConfirmer(words: "and then the tests ran")
        let l = await make(Self.confirmTiming, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        let seen = await phases(of: l)
        await l.setSpeaking("Billing service needs your OK to run the tests.")
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await l.falseWakes == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await confirmer.heads.count == 1)
        #expect(await confirmer.heads.first?.contains(2) == true)   // the window the spotter got
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)   // no captureBegan, so no barge-in
        #expect(await heard.items.isEmpty)
        #expect(l.level.value == 0)
        #expect(await seen.items.allSatisfy { $0 == .waiting })
        #expect(await l.currentPhase == .waiting)
    }

    /// The confirm takes its time while you go on talking: nothing said after the
    /// phrase is lost, and the chime comes once, when the wake passes.
    @Test func aSlowConfirmLosesNothingSaidAfterThePhrase() async {
        let confirmer = FakeConfirmer(words: "Hey Kobi, what's", hold: true)
        let st = ScriptTranscriber()
        let l = await make(Self.confirmTiming, transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        let seen = await phases(of: l)
        await input.push([2, 3, 3, 3, 3, 3])
        #expect(await eventually { await confirmer.waiting })
        await input.push([3, 3, 1, 1])
        #expect(await eventually { await l.capturedSamples == 10 * 4096 })
        #expect(l.level.value == 0)   // the orb shows nothing yet
        await input.push([0, 0])
        #expect(await eventually { await l.capturedSamples == 12 * 4096 })
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        #expect(await seen.items.allSatisfy { $0 == .waiting })
        await confirmer.release()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "what's everyone doing?")
        let clip = await st.clips.first ?? []
        #expect(clip.first == 2)
        #expect(clip.contains(1))   // said after the confirm began
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
        #expect(await st.clips.count == 1)
    }

    /// The segment ends while the confirm runs: a pass finishes it at once, and
    /// "Hey Kobi" alone goes on to listen for the command.
    @Test func aSegmentThatEndsDuringTheConfirmIsFinishedOnThePass() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        let l = await make(Self.confirmTiming, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 2, 2, 2, 2])
        #expect(await eventually { await confirmer.waiting })
        await input.push([0, 0])
        #expect(await eventually { await l.capturedSamples == 8 * 4096 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await observer.events.isEmpty)
        await confirmer.release()
        #expect(await eventually { await chimes.played == [.listening] })
        #expect(await eventually { await l.currentPhase == .capturing(.wake) })
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await observer.events == ["began", "ended"])
    }

    /// A call that starts during the confirm ends it silently, and the late answer does nothing.
    @Test func aCallDuringTheConfirmEndsItSilently() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        let l = await make(Self.confirmTiming, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3])
        #expect(await eventually { await confirmer.waiting })
        await l.setMicBusy(true)
        #expect(await eventually { await !input.isOpen })
        await confirmer.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        #expect(await heard.items.isEmpty)
        #expect(await l.falseWakes == 0)
        await l.setMicBusy(false)
        #expect(await eventually { await input.isOpen })
        #expect(await eventually { await l.currentPhase == .waiting })
    }

    /// A hotkey press during the confirm wins: the wake is dropped unheard, and the hold is heard.
    @Test func theHotkeyWinsOverAWakeBeingConfirmed() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        let l = await make(Self.confirmTiming, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3])
        #expect(await eventually { await confirmer.waiting })
        await l.hotkeyDown()
        #expect(await eventually { await observer.events == ["began"] })
        #expect(await l.currentPhase == .capturing(.hotkey))
        await confirmer.release()   // a pass that comes too late does nothing
        await input.push([1, 1])
        #expect(await eventually { await l.capturedSamples == 9 * 4096 })
        await l.hotkeyUp()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.trigger == .hotkey)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
    }

    /// Disarming during the confirm drops the wake unheard and closes the mic.
    @Test func disarmingDuringTheConfirmClosesTheMicSilently() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        let l = await make(Self.confirmTiming, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3])
        #expect(await eventually { await confirmer.waiting })
        await l.setWakeArmed(false)
        #expect(await eventually { await !input.isOpen })
        await confirmer.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        #expect(await l.currentPhase == .off)
    }

    /// A follow-up that opens during the confirm waits for its answer, so a rejected
    /// wake does not cost Kobi its window.
    @Test func aFollowUpWaitsForTheConfirm() async {
        let confirmer = FakeConfirmer(words: "and then the tests ran", hold: true)
        let l = await make(Self.confirmTiming, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await confirmer.waiting })
        let follow = Task { await l.listenFollowUp(.reply) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await observer.events.isEmpty)
        await confirmer.release()
        await follow.value
        #expect(await observer.events == ["began"])
        #expect(await l.falseWakes == 1)
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.trigger == .followUp(.reply))
    }

    /// A confirmer that never answers can't hold a wake back: past the limit it is no
    /// answer, as nil is. A strong score passes; one under the strict threshold is silent.
    @Test(arguments: [(Float(-4), true), (Float(-6), false)])
    func aHungConfirmerIsTreatedAsNoAnswer(score: Float, passes: Bool) async {
        await spotter.setHit(score)
        let confirmer = FakeConfirmer(words: "and then the tests ran", hold: true)
        var t = Listener.Timing.forTests
        t.confirmLimit = .milliseconds(100)
        let l = await make(t, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        if passes {
            #expect(await eventually { await heard.items.count == 1 })
            #expect(await heard.items.first?.text == "what's everyone doing?")
            #expect(await chimes.played == [.listening])
        } else {
            #expect(await eventually { await l.falseWakes == 1 })
            try? await Task.sleep(for: .milliseconds(50))
            #expect(await heard.items.isEmpty)
            #expect(await chimes.played.isEmpty)
            #expect(await observer.events.isEmpty)
        }
        await confirmer.release()
    }

    /// A wake no recognizer could judge (the confirmer has no answer) passes only on a
    /// score at or above CtcWakeSpotter.unconfirmedThreshold; under it, it is silent.
    @Test(arguments: [(Float(-3), true), (Float(-4), true), (Float(-5), false), (Float(-7.9), false)])
    func anUnjudgedWakeNeedsTheStrictScore(score: Float, passes: Bool) async {
        await spotter.setHit(score)
        let confirmer = FakeConfirmer(words: nil)
        let l = await make(confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await confirmer.heads.count == 1 })   // the spotter fired
        if passes {
            #expect(await eventually { await heard.items.count == 1 })
            #expect(await heard.items.first?.text == "what's everyone doing?")
            #expect(await chimes.played == [.listening])
            #expect(await l.falseWakes == 0)
        } else {
            #expect(await eventually { await l.falseWakes == 1 })
            try? await Task.sleep(for: .milliseconds(50))
            #expect(await heard.items.isEmpty)
            #expect(await chimes.played.isEmpty)
            #expect(await observer.events.isEmpty)
            #expect(l.level.value == 0)
            #expect(await l.currentPhase == .waiting)
        }
    }

    /// Words that start with the wake phrase pass at any score the spotter fires on.
    @Test func aConfirmedWakePassesAtALowScore() async {
        await spotter.setHit(-7.9)
        let confirmer = FakeConfirmer(words: "Hey Kobi, what's")
        let l = await make(confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "what's everyone doing?")
    }

    /// Under the threshold the spotter does not fire: nothing is confirmed.
    @Test func aScoreUnderTheThresholdIsNoWake() async {
        await spotter.setHit(CtcWakeSpotter.threshold(5) - 0.5)
        let confirmer = FakeConfirmer(words: "Hey Kobi, what's")
        let l = await make(confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await spotter.calls == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await confirmer.heads.isEmpty)
        #expect(await heard.items.isEmpty)
        #expect(await l.falseWakes == 0)
    }

    /// Confirmed from the name alone first ("Kobe, what's everyone doing?"), a wake whose
    /// transcript has the greeting and the name keeps its command.
    @Test func aBareConfirmWithALiteralTranscriptKeepsItsCommand() async {
        let confirmer = FakeConfirmer(words: "Kobe, what's everyone doing?")
        let st = ScriptTranscriber(fixed: "Hey Kobi, what's everyone doing?")
        let l = await make(transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "what's everyone doing?")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await l.falseWakes == 0)
        #expect(await chimes.played == [.listening])
        #expect(await observer.heard == [true])
    }

    /// "Kobe, approve it." with no greeting, heard word for word in every hearing: a mention
    /// cut off at the start reads the same. It chimes, but "approve it." is never sent: the
    /// listener waits for the command, as after "Hey Kobi" alone.
    @Test func theNameAloneFirstSendsNothingAndWaitsForTheCommand() async {
        let said = "Kobe, approve it."
        let st = WakeAndCommandTranscriber(wake: said, command: "run the tests")
        let other = FakeSecondHearing(words: said)
        let l = await make(transcriber: st, second: other, confirmer: FakeConfirmer(words: said))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await st.clips.count == 1 })
        #expect(await eventually { await l.currentPhase == .capturing(.wake) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began"])
        #expect(await l.falseWakes == 0)
        // The window is the one after "Hey Kobi" alone: the next thing said is the command.
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
    }

    /// A mention whose start the noise gate cut off, so the confirm heard "Kobe" alone first
    /// ("Kobe. To run."): nothing is sent, whether the transcript has the name later ("did you
    /// ask kobi to run the tests") or was cut off the same way, and the window that opens
    /// closes on silence.
    @Test(arguments: ["did you ask kobi to run the tests", "Kobe. To run the tests."])
    func aMentionCutOffAtTheStartSendsNothing(_ transcript: String) async {
        let st = WakeAndCommandTranscriber(wake: transcript, command: "")
        let l = await make(transcriber: st, confirmer: FakeConfirmer(words: "Kobe. To run."))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await observer.events == ["began", "ended"])
        #expect(await observer.heard == [false])
        #expect(await eventually { await l.currentPhase == .waiting })
    }

    /// The boost turned "Kobi" into a session's name; the plain words still have the phrase.
    @Test func thePlainWordsCanCarryThePhrase() async {
        let st = FixedTranscriber(text: "Hey reflow summarized the last session.", plain: "Hey Kobi summarized the last session.")
        let l = await make(transcriber: st, confirmer: FakeConfirmer(words: "Hey Kobi"))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "summarized the last session.")
        #expect(await chimes.played == [.listening])
    }

    /// Parakeet heard nothing; the second hearing, waited for anyway, has the phrase and the command.
    @Test func theSecondHearingCanCarryTheCommandWhenParakeetHeardNothing() async {
        let st = FixedTranscriber(text: "", plain: nil)
        let other = FakeSecondHearing(words: "Hey Kobi, pause.", delay: .milliseconds(50))
        let l = await make(transcriber: st, second: other, confirmer: FakeConfirmer(words: "Hey Kobi"))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "pause.")
        #expect(await chimes.played == [.listening])
    }

    /// "Kobi, stop" with no greeting chimes and opens the window, but sends nothing of its
    /// own segment, even when the transcript agrees: the next segment is the command.
    @Test func aBareKobiOpensTheWindowAndTheNextSegmentIsTheCommand() async {
        let st = WakeAndCommandTranscriber(wake: "Kobe, stop", command: "run the tests")
        let l = await make(transcriber: st, confirmer: FakeConfirmer(words: "Kobe, stop"))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await st.clips.count == 1 })
        #expect(await eventually { await l.currentPhase == .capturing(.wake) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played == [.listening])
        #expect(await l.falseWakes == 0)
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await observer.events == ["began", "ended"])
        #expect(await st.clips.last?.contains(2) == false)
    }

    /// "A Kobe beef burger, please." heard word for word: "a" and the name run into the sentence
    /// chime and open the window, and nothing of it is sent.
    @Test func aKobeBurgerSendsNothing() async {
        await spotter.setHit(-7.0)
        let words = "A Kobe beef burger, please."
        let l = await make(transcriber: ScriptTranscriber(fixed: words), second: FakeSecondHearing(words: words),
                           confirmer: FakeConfirmer(words: words))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await l.currentPhase == .capturing(.wake) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played == [.listening])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
    }

    /// A session named kobe would make the boost write the name over "Okay, Colby." The wake's
    /// own clip is heard without it, so the unboosted words are all there is, they lack the name,
    /// nothing is sent, and the window opens for the command.
    @Test func theBoostWritingTheNameOverAnotherSendsNothing() async {
        let st = BoostingTranscriber(name: "kobe", boosted: "Okay, Kobe, stop the blog.", plain: "Okay, Colby, stop the build.")
        let l = await make(transcriber: st, confirmer: FakeConfirmer(words: "Kobe, stop."))
        await l.setVocabulary(["blog", "kobe"])
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await l.currentPhase == .capturing(.wake) })
        #expect(await st.vocabularies == [["blog"]])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began"])
        #expect(await l.falseWakes == 0)
        // Nothing more is said: the window closes on silence.
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
    }

    /// A wake passed on the strict score alone whose boost lost the phrase: the unboosted words
    /// have it, so they are the command.
    @Test func aStrictWakeTakesTheCommandFromTheUnboostedWords() async {
        let st = FixedTranscriber(text: "Okay reflow what's the status of the blog",
                                  plain: "Okay Kobe, what's the status of the build?")
        let l = await make(transcriber: st, confirmer: FakeConfirmer(words: nil))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "what's the status of the build?")
        #expect(await heard.items.first?.plain == nil)
        #expect(await l.falseWakes == 0)
    }

    /// After a pass on the name alone first, speech begun while the confirm ran is not the
    /// command, even with the window open when it ends: the command is what starts after the chime.
    @Test func speechBegunDuringASlowConfirmAfterTheNameAloneIsNotTheCommand() async {
        let confirmer = FakeConfirmer(words: "Kobe.", hold: true)
        let st = WakeAndCommandTranscriber(wake: "Kobe.", command: "approve it")
        var t = Self.confirmTiming
        t.wakeSilence = .seconds(2)
        let l = await make(t, transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 2, 2, 2, 2])
        #expect(await eventually { await confirmer.waiting })
        await input.push([0, 0, 1, 1])   // the wake's end edge, then the next sentence's start edge
        #expect(await eventually { await l.capturedSamples == 10 * 4096 })
        await confirmer.release()
        #expect(await eventually { await chimes.played == [.listening] })
        #expect(await eventually { await st.clips.count == 1 })
        #expect(await eventually { await l.currentPhase == .capturing(.wake) })
        await input.push([1, 0, 0])   // it ends after the window opened
        #expect(await eventually { await l.capturedSamples == 13 * 4096 })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await heard.items.isEmpty)
        #expect(await st.clips.count == 1)
        // Said after the chime: the command.
        await input.push([3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "approve it")
        let command = await st.clips.last ?? []
        #expect(command.contains(3))
        #expect(!command.contains(1))
        #expect(await observer.events == ["began", "ended"])
    }

    /// The same with the whole sentence said during the confirm: it is not the command either.
    @Test func aSentenceSaidDuringASlowConfirmAfterTheNameAloneIsNotTheCommand() async {
        let confirmer = FakeConfirmer(words: "Kobe", hold: true)
        let st = WakeAndCommandTranscriber(wake: "Kobe", command: "approve it")
        let l = await make(Self.confirmTiming, transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 2, 2, 2, 2])
        #expect(await eventually { await confirmer.waiting })
        await input.push([0, 0, 1, 1, 0, 0])
        #expect(await eventually { await l.capturedSamples == 12 * 4096 })
        await confirmer.release()
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await st.clips.count == 1)
        #expect(await observer.heard == [false])
    }

    /// A wake's own clip is heard without the names that spell the wake phrase; the command
    /// after "Hey Kobi" alone is heard with all of them.
    @Test func aWakesOwnClipIsHeardWithoutNamesThatSpellThePhrase() async {
        let other = FakeSecondHearing(words: "")
        let l = await make(second: other)
        await l.setVocabulary(["billing service", "kobi", "Kobe app", "blog"])
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await chimes.played == [.listening] })
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await transcriber.vocabularies == [["billing service", "blog"], ["billing service", "kobi", "Kobe app", "blog"]])
        #expect(await other.names == [["billing service", "blog"], ["billing service", "kobi", "Kobe app", "blog"]])
    }

    /// A wake that passed on the strict score alone, with no words to go on, whose transcript
    /// has no wake words at all ("Kobi" run into a sentence is a mention): a false wake.
    @Test(arguments: ["Kobi which sessions are waiting", "which sessions are waiting"])
    func aWakePassedOnTheScoreAloneKeepsThePlainRuleAtFinish(_ transcript: String) async {
        let st = ScriptTranscriber(fixed: transcript)
        let l = await make(transcriber: st, confirmer: FakeConfirmer(words: nil))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await l.falseWakes == 1)
        #expect(await observer.heard == [false])
    }

    /// A wake passed on the strict score alone whose transcript has the name alone first: as
    /// for a wake passed on those words, it chimed, nothing of its segment is sent, it is not a
    /// false wake, and the next segment is the command.
    @Test(arguments: ["Kobe, stop", "Kobe.", "Koby, approve it."])
    func aWakePassedOnTheScoreAloneWithoutThePhraseWrittenAsSuchWaitsForTheCommand(_ transcript: String) async {
        let st = WakeAndCommandTranscriber(wake: transcript, command: "run the tests")
        let l = await make(transcriber: st, confirmer: FakeConfirmer(words: nil))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await st.clips.count == 1 })
        #expect(await eventually { await l.currentPhase == .capturing(.wake) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began"])
        #expect(await l.falseWakes == 0)
        await input.push([1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
        #expect(await st.clips.last?.contains(2) == false)
    }

    /// The settle after the chime of the name alone first runs from the chime, not from when
    /// the window opens after the wake's transcription: the audio held meanwhile, and a one-word
    /// command said soon after the chime, are not taken for the chime.
    @Test func aOneWordCommandSoonAfterTheChimeOfTheNameAloneIsHeard() async {
        let st = WakeAndCommandTranscriber(wake: "Kobe.", command: "stop", wakeDelay: .milliseconds(150))
        var t = Listener.Timing.forTests
        t.followUpSettle = .milliseconds(250)
        t.wakeSilence = .seconds(2)
        let l = await make(t, transcriber: st, confirmer: FakeConfirmer(words: "Kobe."))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await chimes.played == [.listening] })
        try? await Task.sleep(for: .milliseconds(300))
        await input.push([1, 0, 0])   // one chunk of speech, 300 ms after the chime
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "stop")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await chimes.played == [.listening])
        #expect(await l.falseWakes == 0)
        #expect(await observer.heard == [true])
    }

    /// The chime, heard while a slow transcription of the wake held audio back, is still too
    /// soon once the window opens: the settle goes by when audio came in, not when it is processed.
    @Test func theChimeHeardDuringASlowWakeTranscriptionIsNotTheCommand() async {
        let st = WakeAndCommandTranscriber(wake: "Kobe.", command: "stop", wakeDelay: .milliseconds(400))
        var t = Listener.Timing.forTests
        t.followUpSettle = .milliseconds(250)
        t.wakeSilence = .seconds(2)
        let l = await make(t, transcriber: st, confirmer: FakeConfirmer(words: "Kobe."))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 0, 0])
        #expect(await eventually { await chimes.played == [.listening] })
        await input.push([0.75, 0, 0])   // the chime, as the mic hears it
        #expect(await eventually { await l.capturedSamples == 7 * 4096 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await st.clips.count == 1)
        await input.push([1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "stop")
        #expect(await st.clips.last?.contains(0.75) == false)
        #expect(await chimes.played == [.listening])
    }

    /// A near-miss the spotter fired on and the confirmer heard word for word is rejected
    /// silently, so the rest of it never goes out as a command.
    @Test(arguments: ["Copy that, run the test.", "Hey Toby, run the tests.", "Hey, Colby, approve it.", "Kobe is listening."])
    func aNearMissIsRejectedSilently(_ words: String) async {
        await spotter.setHit(-7.877)
        let confirmer = FakeConfirmer(words: words)
        let st = ScriptTranscriber(fixed: words)
        let l = await make(transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await l.falseWakes == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
        #expect(await st.clips.isEmpty)
    }

    /// The unboosted words and the second hearing lose the phrase by the same rule,
    /// however each recognizer spelled it.
    @Test func theOtherHearingsLoseATolerantWakePhraseToo() async {
        let st = FixedTranscriber(text: "Hey Kobi, how are you wedding", plain: "Hey, Kobe. how are you doing")
        let other = FakeSecondHearing(words: "Hi Kobe. How are you doing?")
        let l = await make(transcriber: st, second: other, confirmer: FakeConfirmer(words: "Hey Kobi"))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.text == "how are you wedding")
        #expect(u?.plain == "how are you doing")
        #expect(u?.second == "How are you doing?")
    }

    /// Apple first; Parakeet only when Apple has no answer. Heard nothing is an answer.
    @Test func theConfirmChainAsksTheNextOnlyOnNoAnswer() async {
        let apple = FakeConfirmer(words: nil), parakeet = FakeConfirmer(words: "Hey Kobi")
        #expect(await FirstAnswerConfirmer([apple, parakeet]).headText([1]) == "Hey Kobi")
        #expect(await parakeet.heads.count == 1)
        let quiet = FakeConfirmer(words: ""), unasked = FakeConfirmer(words: "Hey Kobi")
        #expect(await FirstAnswerConfirmer([quiet, unasked]).headText([1]) == "")
        #expect(await unasked.heads.isEmpty)
        #expect(await FirstAnswerConfirmer([FakeConfirmer(words: nil), FakeConfirmer(words: nil)]).headText([1]) == nil)
        #expect(await FirstAnswerConfirmer([]).headText([1]) == nil)
    }

    /// A confirmer that hears the wake phrase changes nothing from before there was a confirm.
    @Test func aPassingConfirmerHearsTheWakeAsBefore() async {
        let confirmer = FakeConfirmer(words: "Hey Kobi, what's everyone")
        let l = await make(confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        let u = await heard.items.first
        #expect(u?.text == "what's everyone doing?")
        #expect(u?.trigger == .wake)
        #expect(await confirmer.heads.count == 1)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
        #expect(await observer.heard == [true])
        #expect(await l.falseWakes == 0)
    }

    /// A confirmer that hears one of Kobi's own recent lines rejects the wake, with the name as
    /// Apple writes it ("Kobe") after the grace (speakers that play late).
    @Test(arguments: ["Hey, Kobe needs your OK.", "Hey, Kobe. Needs your OK.", "Hey Koby needs your OK."])
    func aConfirmThatRepeatsKobisLineIsRejected(_ words: String) async {
        let confirmer = FakeConfirmer(words: words)
        var timing = Listener.Timing.forTests
        timing.ownWakeGrace = .zero
        let l = await make(timing, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Hey, kobi needs your OK to run the tests.")
        await l.setSpeaking(nil)
        try? await Task.sleep(for: .milliseconds(20))
        await input.push([2, 1, 1, 1, 1, 1, 1, 0, 0])
        #expect(await eventually { await l.falseWakes == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)
    }

    /// A wake whose command runs past the cap during the confirm is still too long once it passes.
    @Test func aWakeThatHitsTheCapDuringTheConfirmIsTooLongOnThePass() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        var t = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150), minHold: .milliseconds(30),
                                maxCommandSamples: 4 * 4096, spotAtSamples: 2 * 4096, reopenDelay: .milliseconds(30), soundWait: .zero)
        t.confirmLimit = .seconds(10)
        let l = await make(t, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 3])
        #expect(await eventually { await l.capturedSamples == 8 * 4096 })
        #expect(await confirmer.waiting)
        #expect(await chimes.played.isEmpty)
        await confirmer.release()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.tooLong == true)
        #expect(await chimes.played == [.listening, .closed])
        #expect(await observer.heard == [true])
    }

    /// "Hey Kobi" alone, a pause, then the command, begun before the confirm answered:
    /// the command is heard from where it began, not lost to a capture that waits for speech.
    @Test func aCommandBegunDuringTheConfirmIsHeard() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        let st = ScriptTranscriber()
        let l = await make(Self.confirmTiming, transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 2, 2, 2, 2])
        #expect(await eventually { await confirmer.waiting })
        await input.push([0, 0, 1, 1])   // the wake's end edge, then the command's start edge
        #expect(await eventually { await l.capturedSamples == 10 * 4096 })
        await confirmer.release()
        #expect(await eventually { await chimes.played == [.listening] })
        await input.push([1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await chimes.played == [.listening])   // no closed chime from a timeout
        #expect(await observer.events == ["began", "ended"])
        let command = await st.clips.last ?? []
        #expect(command.filter { $0 == 1 }.count == 3 * 4096)   // from its first chunk
        #expect(!command.contains(2))
    }

    /// The same, with the whole command said before the confirm answered: it is
    /// heard as soon as the wake passes.
    @Test func aCommandSaidDuringTheConfirmIsHeardOnThePass() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        let st = ScriptTranscriber()
        let l = await make(Self.confirmTiming, transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 2, 2, 2, 2, 2])
        #expect(await eventually { await confirmer.waiting })
        await input.push([0, 0, 1, 1, 0, 0])
        #expect(await eventually { await l.capturedSamples == 12 * 4096 })
        await confirmer.release()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "run the tests")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
        #expect(await st.clips.last?.contains(2) == false)
        #expect(await eventually { await l.currentPhase == .waiting })
    }

    /// A tap or a chord of the hotkey changes nothing, even while a wake is being
    /// confirmed: the answer that comes while the key is down still passes the wake.
    @Test(arguments: [false, true])
    func aTapOrChordDuringTheConfirmChangesNothing(chord: Bool) async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        var t = Self.confirmTiming
        t.minHold = .milliseconds(400)
        let l = await make(t, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await confirmer.waiting })
        #expect(await eventually { await l.capturedSamples == 9 * 4096 })
        await l.hotkeyDown()
        await confirmer.release()   // the answer comes while the key is down
        try? await Task.sleep(for: .milliseconds(50))
        if chord { await l.hotkeyCancel() } else { await l.hotkeyUp() }
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "what's everyone doing?")
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
        #expect(await l.falseWakes == 0)
    }

    /// A follow-up waits for the confirmer's answer, not for the passed wake's
    /// transcription: Kobi's lines are not held back while it runs.
    @Test func aFollowUpDuringAPassedWakesTranscriptionReturnsPromptly() async {
        let confirmer = FakeConfirmer(words: nil, hold: true)
        let st = ScriptTranscriber(holdFirst: true)
        let l = await make(Self.confirmTiming, transcriber: st, confirmer: confirmer)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await confirmer.waiting })
        let returned = Collected<Bool>()
        Task { await l.listenFollowUp(.reply); await returned.add(true) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await returned.items.isEmpty)   // it waits for the answer
        await confirmer.release()
        #expect(await eventually { await st.waiting })   // the wake's transcription is held
        #expect(await eventually { await returned.items.count == 1 })
        #expect(await observer.events == ["began"])   // the wake's own: no follow-up window
        await st.release()
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.trigger == .wake)
        #expect(await heard.items.first?.text == "what's everyone doing?")
        #expect(await chimes.played == [.listening])
        #expect(await observer.events == ["began", "ended"])
    }

    // MARK: - Kobi's own voice

    /// A session named "kobi": the plugin says "Hey, kobi needs your OK".
    @Test func aWakeWhileKobiSaysThePhraseIsIgnored() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Hey, kobi needs your OK to run the tests.")
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await spotter.calls == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await heard.items.isEmpty)
        #expect(await chimes.played.isEmpty)
        #expect(await observer.events.isEmpty)   // no capture, so no barge-in
        #expect(await l.falseWakes == 1)
    }

    @Test func aWakeJustAfterSuchALineIsIgnored() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Kobi finished: fixed the tests.")
        await l.setSpeaking(nil)
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await spotter.calls == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await observer.events.isEmpty)
        #expect(await l.falseWakes == 1)
    }

    /// A short line is spotted only when its segment ends, which can be over a second after it.
    @Test func aShortLineWithThePhraseIsIgnoredWhenItsSegmentEndsLater() async {
        var timing = Listener.Timing.forTests
        timing.ownWakeGrace = .milliseconds(20)
        let l = await make(timing)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Kobe finished.")
        await input.push([2])
        try? await Task.sleep(for: .milliseconds(30))
        await l.setSpeaking(nil)
        try? await Task.sleep(for: .milliseconds(60))   // past the grace
        await input.push([0, 0])
        #expect(await eventually { await spotter.calls == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await observer.events.isEmpty)
        #expect(await l.falseWakes == 1)
    }

    /// The spec: the wake word stops the line that is playing.
    @Test func aWakeDuringAnotherLineBargesIn() async {
        let l = await make()
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Billing service needs your OK to run the tests.")
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await observer.events == ["began", "ended"])
        #expect(await l.falseWakes == 0)
    }

    /// The mic hears one of Kobi's lines after the grace, the name written "Kobe": still its own line.
    @Test(arguments: ["Hey, Kobe needs your OK.", "Hey, Kobe. Needs your OK."])
    func aWakeThatRepeatsALineKobiJustSaidIsDropped(_ words: String) async {
        let t = ScriptTranscriber(fixed: words)
        var timing = Listener.Timing.forTests
        timing.ownWakeGrace = .zero
        let l = await make(timing, transcriber: t)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Hey, kobi needs your OK to run the tests.")
        await l.setSpeaking(nil)
        try? await Task.sleep(for: .milliseconds(20))
        await input.push([2, 1, 1, 1, 1, 1, 1, 0, 0])
        #expect(await eventually { await chimes.played == [.listening, .closed] })
        #expect(await heard.items.isEmpty)
        #expect(await l.falseWakes == 1)
        #expect(await observer.heard == [false])
    }

    @Test func aLineSaidLongAgoNoLongerDropsAWake() async {
        let t = ScriptTranscriber(fixed: "Hey, Kobe. Needs your OK.")
        var timing = Listener.Timing.forTests
        timing.ownWakeGrace = .zero
        timing.ownLineMemory = .milliseconds(30)
        let l = await make(timing, transcriber: t)
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Hey, kobi needs your OK to run the tests.")
        await l.setSpeaking(nil)
        try? await Task.sleep(for: .milliseconds(80))
        await input.push([2, 1, 1, 1, 1, 1, 1, 0, 0])
        #expect(await eventually { await heard.items.count == 1 })
        #expect(await heard.items.first?.text == "Needs your OK.")
    }

    /// A session named KobiKit in Kobi's own line, heard back as "Hey, Kobe kit": Kobi's own
    /// voice, so no barge-in and nothing sent.
    @Test func aLineWithTheNameInsideAWordIsKobisOwnVoice() async {
        let t = ScriptTranscriber(fixed: "Hey, Kobe kit needs your OK.")
        let l = await make(transcriber: t, confirmer: FakeConfirmer(words: "Hey, Kobe kit needs your OK."))
        await l.setWakeArmed(true)
        #expect(await eventually { await input.isOpen })
        await l.setSpeaking("Hey, KobiKit needs your OK to run the tests.")
        await input.push([2, 3, 3, 3, 3, 3, 3, 0, 0])
        #expect(await eventually { await l.falseWakes == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await observer.events.isEmpty)
        #expect(await heard.items.isEmpty)
    }

    @Test(arguments: [
        ("Hey, kobi needs your OK to run the tests.", true),
        ("Kobi finished: fixed the tests.", true),
        ("The Kobe session is done.", true),
        ("Toby finished.", false),
        ("Billing service needs your OK.", false),
        ("Kobold is not a session.", false),
        // Compounds and possessives, as the boost's vocabulary filter takes them.
        ("Hey, KobiKit needs your OK.", true), ("kobiapp finished.", true), ("kobi_api is stuck.", true),
        ("kobi2 finished.", true), ("Kobi's tests passed.", true), ("The kobi-web session is done.", true),
        // Names recognizers write for "Kobi".
        ("Coby finished.", true), ("Kobie needs your OK.", true), ("Koby is working.", true),
        ("Cob salad finished.", false), ("Coburn is working.", false),
    ])
    func findsTheWakePhraseAnywhere(_ line: String, _ found: Bool) {
        #expect(Listener.mentionsWake(line) == found)
    }

    @Test(arguments: [
        ("Hey Kobi, what's everyone doing?", "what's everyone doing?"),
        ("hey kobe tell billing to run the tests", "tell billing to run the tests"),
        ("Kobi. Stop billing.", "Stop billing."),
        ("Hey, Kobi", ""),
        ("Okay Kobe, status", "status"),
    ])
    func stripsTheWakePhrase(_ said: String, _ rest: String) {
        #expect(Listener.stripWake(said) == rest)
    }

    @Test func leavesOtherTextAlone() {
        #expect(Listener.stripWake("run the tests") == nil)
        #expect(Listener.stripWake("Hey Toby, run the tests") == nil)
        #expect(Listener.stripWake("Kobold, run the tests") == nil)
    }

    /// stripWake takes off only what wakeWords takes as the wake phrase.
    @Test(arguments: ["Kobe-san, stop.", "Kobe: keep going", "Kobe beef is expensive", "Kobe's still running",
                      "Take Kobe to the vet"])
    func stripsOnlyWhatWakes(_ said: String) {
        #expect(Listener.wakeWords(said) == nil)
        #expect(Listener.stripWake(said) == nil)
    }
}

extension Listener.Timing {
    static let forTests = Listener.Timing(wakeSilence: .milliseconds(150), followUp: .milliseconds(150),
                                          minHold: .milliseconds(30), reopenDelay: .milliseconds(30),
                                          followUpSettle: .zero, soundWait: .zero)
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
