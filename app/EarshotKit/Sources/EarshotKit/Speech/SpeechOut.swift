import Foundation
import os

public protocol Synthesizer: Sendable {
    /// An audio file for the line, or nil when every engine failed.
    func audio(for line: SpokenLine) async -> URL?
}

public protocol LinePlayer: Sendable {
    /// Plays the file for one line. True when it played to the end, false when stopped.
    func play(_ url: URL, id: UUID) async -> Bool
    /// Stops that line's playback, even when its play has not started yet.
    func stop(_ id: UUID) async
}

public protocol MicSource: Sendable {
    /// Another app captures from the mic (a call, dictation).
    var isBusy: Bool { get async }
    /// Every change of isBusy.
    func changes() -> AsyncStream<Bool>
}

public protocol Ducking: Sendable {
    func begin() async
    func end() async
}

/// True for the first caller only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// The one speaker all sessions share: lines take turns, wait while another
/// app uses the mic, and are said in a catch-up afterwards.
public actor SpeechOut {
    public enum State: Sendable, Equatable { case idle, speaking, holding }

    public static let errorTone = URL(fileURLWithPath: "/System/Library/Sounds/Basso.aiff")
    private let log = Logger(subsystem: "com.earshot.app", category: "speech")

    private let synth: any Synthesizer
    private let player: any LinePlayer
    private let mic: any MicSource
    private let ducker: any Ducking
    private let answered: @Sendable (SpokenLine) -> Bool
    private let settle: Duration
    private let maxWait: TimeInterval
    private let lineTimeout: Duration
    private let callTimeout: Duration
    private let synthTimeout: Duration
    private let clock: @Sendable () -> Date

    private var queue: [SpokenLine] = []
    private var held = HoldQueue()
    private var started = false
    private var running = false
    /// The line being started or played; a call that begins now interrupts it.
    private var currentLine: UUID?
    private var interrupted = false
    private var lastMicBusy = false
    private var catchUpGeneration = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var stateConts: [UUID: AsyncStream<State>.Continuation] = [:]
    public private(set) var state: State = .idle {
        didSet { if state != oldValue { stateConts.values.forEach { $0.yield(state) } } }
    }

    public init(synth: any Synthesizer, player: any LinePlayer, mic: any MicSource, ducker: any Ducking,
                answered: @escaping @Sendable (SpokenLine) -> Bool = SpokenLine.transcriptAnswered,
                settle: Duration = .seconds(4), maxWait: TimeInterval = 60, lineTimeout: Duration = .seconds(30),
                callTimeout: Duration = .seconds(3), synthTimeout: Duration = .seconds(25),
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.synth = synth; self.player = player; self.mic = mic; self.ducker = ducker
        self.answered = answered; self.settle = settle; self.maxWait = maxWait
        self.lineTimeout = lineTimeout; self.callTimeout = callTimeout; self.synthTimeout = synthTimeout
        self.clock = clock
    }

    /// Starts following the mic. Later calls do nothing.
    public func start() {
        guard !started else { return }
        started = true
        let changes = mic.changes()
        Task { [weak self] in
            for await busy in changes { await self?.micChanged(busy) }
        }
    }

    public func stateChanges() -> AsyncStream<State> {
        let (stream, cont) = AsyncStream<State>.makeStream()
        let id = UUID()
        stateConts[id] = cont
        cont.yield(state)
        cont.onTermination = { [weak self] _ in Task { await self?.removeStateCont(id) } }
        return stream
    }
    private func removeStateCont(_ id: UUID) { stateConts[id] = nil }

    public func enqueue(_ line: SpokenLine) async {
        if line.kind != .roll, await micBusy() {
            hold(line)
            return
        }
        queue.append(line)
        runIfNeeded()
    }

    /// The session's prompt was answered, so its held "needs you" lines are stale.
    public func sessionAnswered(_ session: String) {
        held.dropAnswered(session: session)
        updateState()
    }

    /// Returns when nothing is queued or playing.
    public func waitUntilIdle() async {
        if !running && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: -

    private func hold(_ line: SpokenLine) {
        if line.kind.isHeld { log.info("held \(line.kind.rawValue, privacy: .public)") }
        held.hold(line)
        updateState()
        // The mic may have freed while this line was on its way here, after
        // the "free" event was handled: check again after the settle time.
        scheduleCatchUp()
    }

    private func runIfNeeded() {
        guard !running else { return }
        running = true
        Task { await run() }
    }

    private func run() async {
        var ducked = false
        while !queue.isEmpty {
            let line = queue.removeFirst()
            if clock().timeIntervalSince(line.received) > maxWait {
                log.info("dropped a line that waited over \(Int(self.maxWait)) s")
                continue
            }
            if line.kind != .roll, await micBusy() { hold(line); continue }
            let synth = self.synth
            let made = await bounded(synthTimeout, URL?.none) { await synth.audio(for: line) }
            let url = made ?? Self.errorTone
            // A call may have started while the audio was made.
            if line.kind != .roll, await micBusy() { hold(line); continue }
            // From here a call that starts interrupts this line.
            currentLine = line.id
            interrupted = false
            state = .speaking
            // Every line renews the ducking, so its safety cap never cuts a long run short.
            let ducker = self.ducker
            await bounded(callTimeout, ()) { await ducker.begin() }
            ducked = true
            let finished: Bool
            if interrupted {
                finished = false   // the call began while the ducking started
            } else if let done = await playWithTimeout(url, id: line.id) {
                finished = done
            } else {
                // Playback did not finish in time, for example a start that hangs
                // inside Core Audio while a headset switches mode. Move on, so the
                // queue and the ducking never stay stuck.
                log.error("a line did not finish in time; skipped it")
                await player.stop(line.id)
                finished = true
            }
            currentLine = nil
            if !finished && interrupted {
                // A call started: say this line and the rest later.
                hold(line)
                for rest in queue where rest.kind != .roll { hold(rest) }
                queue.removeAll { $0.kind != .roll }
            }
        }
        if ducked {
            let ducker = self.ducker
            await bounded(callTimeout, ()) { await ducker.end() }
        }
        running = false
        updateState()
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// The player's result, or nil when it took longer than lineTimeout. A
    /// player stuck in a blocking call is left behind; it cannot hold the queue.
    private func playWithTimeout(_ url: URL, id: UUID) async -> Bool? {
        let player = self.player
        return await bounded(lineTimeout, Bool?.none) { await player.play(url, id: id) }
    }

    /// The mic check, with a time limit: a Core Audio read that hangs falls
    /// back to the last state the change events reported.
    private func micBusy() async -> Bool {
        let mic = self.mic
        return await bounded(callTimeout, lastMicBusy) { await mic.isBusy }
    }

    private func micChanged(_ busy: Bool) async {
        lastMicBusy = busy
        catchUpGeneration += 1
        if busy {
            if let id = currentLine {
                interrupted = true
                await player.stop(id)
            }
            return
        }
        scheduleCatchUp()
    }

    /// Says the held lines once the mic has been free for the settle time.
    /// Free for a few seconds in a row: a short pause in a call does not count,
    /// because a "busy" event in between cancels this.
    private func scheduleCatchUp() {
        guard !held.isEmpty else { return }
        let generation = catchUpGeneration
        Task { [settle] in
            try? await Task.sleep(for: settle)
            await self.catchUp(ifStill: generation)
        }
    }

    private func catchUp(ifStill generation: Int) async {
        guard generation == catchUpGeneration, !held.isEmpty, !(await micBusy()) else { return }
        guard generation == catchUpGeneration else { return }   // a change arrived while asking the mic
        let now = clock()
        // Catch-up lines were already waiting; they count as new for the 60 s rule.
        let lines = held.takeCatchUp(now: now, answered: answered).map { line -> SpokenLine in
            var l = line
            l.received = now
            return l
        }
        queue.append(contentsOf: lines)
        updateState()
        runIfNeeded()
    }

    private func updateState() {
        if currentLine != nil { state = .speaking; return }
        state = held.isEmpty ? (running ? .speaking : .idle) : .holding
    }
}

/// The operation's result, or `fallback` when it takes longer than `limit`.
/// An operation stuck in a blocking call is left behind and cannot hold the caller.
func bounded<T: Sendable>(_ limit: Duration, _ fallback: T,
                          _ operation: @escaping @Sendable () async -> T) async -> T {
    let once = Once()
    return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        Task {
            let result = await operation()
            if once.claim() { cont.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(for: limit)
            if once.claim() { cont.resume(returning: fallback) }
        }
    }
}
