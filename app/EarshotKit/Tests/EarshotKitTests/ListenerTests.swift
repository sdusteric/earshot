import Foundation
import Testing
@testable import EarshotKit

func chunk(_ v: Float) -> [Float] { [Float](repeating: v, count: 4096) }

actor FakeInput: AudioInput {
    private var cont: AsyncStream<[Float]>.Continuation?
    private(set) var starts = 0, stops = 0
    var isOpen: Bool { cont != nil }
    func start() async throws -> AsyncStream<[Float]> {
        starts += 1
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
    func reset() async { inSpeech = false; quiet = 0 }
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
    func prewarm() async {}
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

    func make(_ t: Listener.Timing = .forTests) async -> Listener {
        let l = Listener(input: input, gate: gate, spotter: spotter, transcriber: transcriber, chimes: chimes, timing: t)
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
                                          minHold: .milliseconds(30))
}
