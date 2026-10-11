import Foundation
import Testing
@testable import EarshotKit

/// A mic the test switches on and off. Listeners register at once, so no
/// change is missed.
final class FakeMic: MicSource, @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var conts: [AsyncStream<Bool>.Continuation] = []
    var isBusy: Bool { get async { lock.withLock { busy } } }
    func changes() -> AsyncStream<Bool> {
        let (s, c) = AsyncStream<Bool>.makeStream()
        lock.withLock { conts.append(c) }
        return s
    }
    func set(_ b: Bool) {
        let cs = lock.withLock { busy = b; return conts }
        cs.forEach { $0.yield(b) }
    }
}

/// A mic whose check is slow and sees the mic free up while it runs: it
/// reports busy, but the "free" event arrives before the answer does.
final class FreesDuringCheckMic: MicSource, @unchecked Sendable {
    let inner = FakeMic()
    private let lock = NSLock()
    private var armed = true
    var isBusy: Bool {
        get async {
            guard lock.withLock({ let a = armed; armed = false; return a }) else { return await inner.isBusy }
            inner.set(false)
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
    }
    func changes() -> AsyncStream<Bool> { inner.changes() }
}

/// Plays instantly, or holds each line until released, so a test can act mid-line.
actor FakePlayer: LinePlayer {
    private(set) var played: [String] = []
    private var blocking: Bool
    private let hangs: Bool
    private var waiter: CheckedContinuation<Bool, Never>?
    /// hangs: play never returns and stop does nothing, like a playback
    /// start that blocks inside Core Audio.
    init(blocking: Bool = false, hangs: Bool = false) { self.blocking = blocking; self.hangs = hangs }
    func play(_ url: URL, id: UUID) async -> Bool {
        played.append(url.lastPathComponent)
        if hangs {
            try? await Task.sleep(for: .seconds(3600))
            return true
        }
        guard blocking else { return true }
        return await withCheckedContinuation { waiter = $0 }
    }
    func stop(_ id: UUID) async { waiter?.resume(returning: false); waiter = nil }
    func finish() { waiter?.resume(returning: true); waiter = nil }
    func unblock() { blocking = false; finish() }
    var isPlaying: Bool { waiter != nil }
}

struct FakeSynth: Synthesizer {
    func audio(for line: SpokenLine) async -> URL? { URL(fileURLWithPath: "/fake/\(line.text)") }
}

actor FakeDucker: Ducking {
    private(set) var begins = 0, ends = 0
    private let beginDelay: Duration
    /// beginDelay: begin takes this long, like creating the aggregate device.
    init(beginDelay: Duration = .zero) { self.beginDelay = beginDelay }
    func begin() async {
        begins += 1
        if beginDelay > .zero { try? await Task.sleep(for: beginDelay) }
    }
    func end() async { ends += 1 }
}

/// Makes audio only after the test releases it.
actor GatedSynth: Synthesizer {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var asked = 0
    func audio(for line: SpokenLine) async -> URL? {
        asked += 1
        if !open { await withCheckedContinuation { waiters.append($0) } }
        return URL(fileURLWithPath: "/fake/\(line.text)")
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// The first end() suspends until released, like a slow Core Audio teardown.
actor SlowEndDucker: Ducking {
    private(set) var begins = 0, ends = 0, endStarted = false
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    func begin() async { begins += 1 }
    func end() async {
        ends += 1
        if ends == 1, !released { endStarted = true; await withCheckedContinuation { gate = $0 } }
    }
    func release() { released = true; gate?.resume(); gate = nil }
}

@Suite struct SpeechOutTests {
    let mic = FakeMic()
    let ducker = FakeDucker()

    func make(_ player: FakePlayer, answered: @escaping @Sendable (SpokenLine) -> Bool = { _ in false },
              clock: @escaping @Sendable () -> Date = Date.init) async -> SpeechOut {
        let s = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: ducker, answered: answered,
                          settle: .milliseconds(30), maxWait: 60, clock: clock)
        await s.start()
        return s
    }
    func line(_ text: String, _ kind: LineKind = .done, _ session: String = "s1") -> SpokenLine {
        SpokenLine(text: text, kind: kind, session: session)
    }
    func eventually(_ check: @escaping () async -> Bool) async {
        for _ in 0..<200 {
            if await check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func playsInOrderAndEndsDuckingOncePerRun() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.enqueue(line("one")); await s.enqueue(line("two"))
        await s.waitUntilIdle()
        #expect(await player.played == ["one", "two"])
        #expect(await ducker.ends == 1)
    }

    @Test func holdsWhileTheMicIsBusyThenCatchesUp() async {
        let player = FakePlayer()
        let s = await make(player)
        mic.set(true)
        await s.enqueue(line("needs you", .need)); await s.enqueue(line("still on it", .beat))
        #expect(await s.state == .holding)
        #expect(await player.played.isEmpty)
        mic.set(false)
        await eventually { await player.played == ["needs you"] }
        #expect(await player.played == ["needs you"])
    }

    @Test func rollCallPlaysDuringACall() async {
        let player = FakePlayer()
        let s = await make(player)
        mic.set(true)
        await s.enqueue(line("Two sessions.", .roll, ""))
        await s.waitUntilIdle()
        #expect(await player.played == ["Two sessions."])
    }

    @Test func aCallMidLineStopsItAndHoldsTheRest() async {
        let player = FakePlayer(blocking: true)
        let s = await make(player)
        await s.enqueue(line("first", .done, "a")); await s.enqueue(line("second", .done, "b"))
        await eventually { await player.isPlaying }
        mic.set(true)
        await eventually { await s.state == .holding }
        #expect(await player.played == ["first"])
        await player.unblock()
        mic.set(false)
        await eventually { await player.played.count == 3 }
        #expect(await player.played == ["first", "first", "second"])
    }

    @Test func linesThatWaitedTooLongAreDropped() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.enqueue(SpokenLine(text: "stale", kind: .done, session: "s", received: Date().addingTimeInterval(-61)))
        await s.enqueue(line("fresh"))
        await s.waitUntilIdle()
        #expect(await player.played == ["fresh"])
    }

    @Test func answeringDropsHeldNeeds() async {
        let player = FakePlayer()
        let s = await make(player)
        mic.set(true)
        await s.enqueue(line("needs you", .need, "a"))
        await s.enqueue(line("done", .done, "a"))
        await s.sessionAnswered("a")
        mic.set(false)
        await eventually { await player.played == ["done"] }
        #expect(await player.played == ["done"])
    }

    @Test func needsAnsweredWithEscAreSkipped() async {
        let player = FakePlayer()
        let s = await make(player, answered: { $0.kind == .need })
        mic.set(true)
        await s.enqueue(line("needs you", .need)); await s.enqueue(line("done"))
        mic.set(false)
        await eventually { await player.played == ["done"] }
        #expect(await player.played == ["done"])
    }

    @Test func aLineThatNeverFinishesIsAbandonedAndDuckingEnds() async {
        let player = FakePlayer(hangs: true)
        let s = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: ducker, answered: { _ in false },
                          settle: .milliseconds(30), lineTimeout: .milliseconds(100))
        await s.start()
        await s.enqueue(line("one", .done, "a")); await s.enqueue(line("two", .done, "b"))
        await eventually { await ducker.ends == 1 }
        #expect(await player.played == ["one", "two"])
        #expect(await ducker.ends == 1)
        #expect(await s.state == .idle)
    }

    /// Review finding 2: the "free" event is handled before the line is held,
    /// so nothing would start the catch-up.
    @Test func aLineHeldAsTheMicFreesStillPlays() async {
        let player = FakePlayer()
        let racing = FreesDuringCheckMic()
        racing.inner.set(true)
        let s = SpeechOut(synth: FakeSynth(), player: player, mic: racing, ducker: ducker, answered: { _ in false },
                          settle: .milliseconds(30))
        await s.start()
        await s.enqueue(line("held as the mic frees"))
        await eventually { await player.played.count == 1 }
        #expect(await player.played == ["held as the mic frees"])
    }

    /// Review finding 3: a call that starts while the ducking is being set up.
    @Test func aCallThatStartsWhileDuckingStartsHoldsTheLine() async {
        let player = FakePlayer()
        let slowDucker = FakeDucker(beginDelay: .milliseconds(150))
        let s = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: slowDucker, answered: { _ in false },
                          settle: .milliseconds(30))
        await s.start()
        await s.enqueue(line("first"))
        await eventually { await slowDucker.begins == 1 }
        mic.set(true)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await player.played.isEmpty)
        mic.set(false)
        await eventually { await player.played.count == 1 }
        #expect(await player.played == ["first"])
    }

    /// Review finding 5: a Core Audio call that never returns must not stop the queue.
    @Test func aDuckerThatHangsDoesNotStopTheLines() async {
        let player = FakePlayer()
        let stuck = FakeDucker(beginDelay: .seconds(3600))
        let s = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: stuck, answered: { _ in false },
                          settle: .milliseconds(30), callTimeout: .milliseconds(100))
        await s.start()
        await s.enqueue(line("one")); await s.enqueue(line("two"))
        await eventually { await player.played.count == 2 }
        #expect(await player.played == ["one", "two"])
    }

    @Test func eachLineRenewsTheDucking() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.enqueue(line("one")); await s.enqueue(line("two")); await s.enqueue(line("three"))
        await s.waitUntilIdle()
        #expect(await ducker.begins == 3)
        #expect(await ducker.ends == 1)
    }

    @Test func aBriefMicBlipDoesNotStartTheCatchUp() async {
        let player = FakePlayer()
        let s = await make(player)
        mic.set(true)
        await s.enqueue(line("held", .done))
        mic.set(false); mic.set(true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await player.played.isEmpty)
        mic.set(false)
        await eventually { await player.played == ["held"] }
        #expect(await player.played == ["held"])
    }

    @Test func listeningStopsTheLineAndDropsIt() async {
        let player = FakePlayer(blocking: true)
        let s = await make(player)
        await s.enqueue(line("first")); await s.enqueue(line("second"))
        await eventually { await player.isPlaying }
        await s.beginListening()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await player.played == ["first"])   // second waits while you talk
        #expect(await s.state != .holding)            // first is not kept for later
        await player.unblock()
        await s.endListening()
        await eventually { await player.played == ["first", "second"] }
        #expect(await player.played == ["first", "second"])
    }

    @Test func linesWaitWhileListening() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.beginListening()
        await s.enqueue(line("later"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await player.played.isEmpty)
        await s.endListening()
        await s.waitUntilIdle()
        #expect(await player.played == ["later"])
    }

    /// Other audio stays low from the wake word to the end of the answer, and
    /// comes back once.
    @Test func duckingSpansListeningAndTheAnswer() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.beginListening()
        #expect(await ducker.begins == 1)
        await s.enqueue(line("Sent to blog.", .confirm, ""))
        await s.endListening()
        await s.waitUntilIdle()
        #expect(await ducker.ends == 1)
    }

    @Test func listeningAloneEndsTheDucking() async {
        let s = await make(FakePlayer())
        await s.beginListening()
        await s.endListening()
        #expect(await ducker.ends == 1)
    }

    @Test func nestedListeningPausesUntilTheLastEnd() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.beginListening()
        await s.beginListening()
        await s.enqueue(line("later"))
        await s.endListening()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await player.played.isEmpty)
        await s.endListening()
        await s.waitUntilIdle()
        #expect(await player.played == ["later"])
        #expect(await ducker.ends == 1)
    }

    @Test func confirmationsGoFirst() async {
        let player = FakePlayer(blocking: true)
        let s = await make(player)
        await s.enqueue(line("x")); await s.enqueue(line("y"))
        await eventually { await player.isPlaying }
        await s.enqueue(line("Sent.", .confirm, ""))
        await s.enqueue(line("Queued.", .confirm, ""))
        await player.unblock()
        await s.waitUntilIdle()
        #expect(await player.played == ["x", "Sent.", "Queued.", "y"])
    }

    @Test func confirmationsAreDroppedDuringACall() async {
        let player = FakePlayer()
        let s = await make(player)
        mic.set(true)
        await s.enqueue(line("Sent.", .confirm, ""))
        #expect(await s.state == .idle)
        mic.set(false)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await player.played.isEmpty)
    }

    @Test func lineEventsSayWhatWasHeard() async {
        let player = FakePlayer(blocking: true)
        let s = await make(player)
        let events = Collected<SpeechOut.LineEvent>()
        let stream = await s.lineEvents()
        Task { for await e in stream { await events.add(e) } }
        let a = line("heard", .need), b = line("cut off", .need)
        await s.enqueue(a); await s.enqueue(b)
        await eventually { await player.isPlaying }
        await player.finish()
        await eventually {
            let n = await player.played.count
            let playing = await player.isPlaying
            return n == 2 && playing
        }
        await s.beginListening()
        await s.endListening()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await events.items == [.started(a), .finished(a), .started(b)])
    }

    @Test func aLineMadeWhileYouTalkWaitsForTheEnd() async {
        let synth = GatedSynth()
        let player = FakePlayer()
        let s = SpeechOut(synth: synth, player: player, mic: mic, ducker: ducker, settle: .milliseconds(30))
        await s.start()
        await s.enqueue(line("later"))
        await eventually { await synth.asked == 1 }
        await s.beginListening()
        await synth.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await player.played.isEmpty)
        await s.endListening()
        await eventually {
            let played = await player.played
            let ends = await ducker.ends
            return played == ["later"] && ends == 1
        }
        #expect(await player.played == ["later"])
        #expect(await ducker.ends == 1)
    }

    @Test func duckingEndsWhenARunExitsWithoutHavingDucked() async {
        let synth = GatedSynth()
        let s = SpeechOut(synth: synth, player: FakePlayer(), mic: mic, ducker: ducker, settle: .milliseconds(30))
        await s.start()
        await s.enqueue(line("held", .need))
        await eventually { await synth.asked == 1 }
        await s.beginListening()
        mic.set(true)
        await s.endListening()
        await synth.release()
        await eventually { await ducker.ends == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await ducker.begins == 1)
        #expect(await ducker.ends == 1)
    }

    @Test func aListeningPairDuringTheFinalEndStillEndsTheDucking() async {
        let slow = SlowEndDucker()
        let s = SpeechOut(synth: FakeSynth(), player: FakePlayer(), mic: mic, ducker: slow, settle: .milliseconds(30))
        await s.start()
        await s.enqueue(line("one"))
        await eventually { await slow.endStarted }
        await s.beginListening()
        await s.endListening()
        await slow.release()
        await eventually { await slow.ends == 2 }
        #expect(await slow.begins == 2)
        #expect(await slow.ends == 2)
    }

    @Test func aLineEnqueuedDuringTheFinalEndStillPlays() async {
        let slow = SlowEndDucker()
        let player = FakePlayer()
        let s = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: slow, settle: .milliseconds(30))
        await s.start()
        await s.enqueue(line("one"))
        await eventually { await slow.endStarted }
        await s.enqueue(line("two"))
        await slow.release()
        await eventually { await player.played == ["one", "two"] }
        await eventually { await slow.begins == slow.ends }
        #expect(await player.played == ["one", "two"])
        #expect(await slow.begins == slow.ends)
    }

    @Test func aLineThatTimedOutIsNotReportedFinished() async {
        let player = FakePlayer(hangs: true)
        let s = SpeechOut(synth: FakeSynth(), player: player, mic: mic, ducker: ducker, answered: { _ in false },
                          settle: .milliseconds(30), lineTimeout: .milliseconds(100))
        await s.start()
        let events = Collected<SpeechOut.LineEvent>()
        let stream = await s.lineEvents()
        Task { for await e in stream { await events.add(e) } }
        let a = line("stuck", .need)
        await s.enqueue(a)
        await eventually { await ducker.ends == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await events.items == [.started(a)])
    }

    @Test func aRequeuedLineStaysBehindAnswersEnqueuedMeanwhile() async {
        let synth = GatedSynth()
        let player = FakePlayer()
        let s = SpeechOut(synth: synth, player: player, mic: mic, ducker: ducker, settle: .milliseconds(30))
        await s.start()
        await s.enqueue(line("x"))
        await eventually { await synth.asked == 1 }
        await s.beginListening()
        await s.enqueue(line("Sent.", .confirm, ""))
        await synth.release()
        try? await Task.sleep(for: .milliseconds(50))
        await s.endListening()
        await eventually { await player.played.count == 2 }
        #expect(await player.played == ["Sent.", "x"])
    }
}
