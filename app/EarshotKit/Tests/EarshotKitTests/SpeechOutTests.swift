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

/// Plays instantly, or holds each line until released, so a test can act mid-line.
actor FakePlayer: LinePlayer {
    private(set) var played: [String] = []
    private var blocking: Bool
    private var waiter: CheckedContinuation<Bool, Never>?
    init(blocking: Bool = false) { self.blocking = blocking }
    func play(_ url: URL) async -> Bool {
        played.append(url.lastPathComponent)
        guard blocking else { return true }
        return await withCheckedContinuation { waiter = $0 }
    }
    func stop() async { waiter?.resume(returning: false); waiter = nil }
    func finish() { waiter?.resume(returning: true); waiter = nil }
    func unblock() { blocking = false; finish() }
    var isPlaying: Bool { waiter != nil }
}

struct FakeSynth: Synthesizer {
    func audio(for line: SpokenLine) async -> URL? { URL(fileURLWithPath: "/fake/\(line.text)") }
}

actor FakeDucker: Ducking {
    private(set) var begins = 0, ends = 0
    func begin() async { begins += 1 }
    func end() async { ends += 1 }
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

    @Test func playsInOrderAndDucksOncePerRun() async {
        let player = FakePlayer()
        let s = await make(player)
        await s.enqueue(line("one")); await s.enqueue(line("two"))
        await s.waitUntilIdle()
        #expect(await player.played == ["one", "two"])
        #expect(await ducker.begins == 1)
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
}
