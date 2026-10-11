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
    /// started, then finished when the line played to the end, then ended
    /// whenever a started line stops for any reason (finished, barged in,
    /// timed out, held for a call).
    public enum LineEvent: Sendable, Equatable { case started(SpokenLine), finished(SpokenLine), ended(SpokenLine) }

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
    private let holdTimeout: Duration

    private var queue: [SpokenLine] = []
    private var held = HoldQueue()
    private var started = false
    private var running = false
    /// The line being started or played; a call that begins now interrupts it.
    private var currentLine: UUID?
    private var interrupted = false
    /// How many captures are open (the wake word and the hotkey can overlap).
    /// While above 0, nothing plays and other audio stays low.
    private var listening = 0
    /// The playing line was stopped because you started talking: it is dropped.
    private var bargedIn = false
    /// A listening begin ducked other audio and nobody has ended it yet.
    private var owed = false
    /// The lines after which the queue waits (see holdAfter), and whether it is waiting now.
    private var holdIDs: Set<UUID> = []
    private var holdActive = false
    /// The line whose hold is active now.
    private var holdLine: UUID?
    private var holdGeneration = 0
    private var lineConts: [UUID: AsyncStream<LineEvent>.Continuation] = [:]
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
                clock: @escaping @Sendable () -> Date = Date.init, holdTimeout: Duration = .seconds(3)) {
        self.synth = synth; self.player = player; self.mic = mic; self.ducker = ducker
        self.answered = answered; self.settle = settle; self.maxWait = maxWait
        self.lineTimeout = lineTimeout; self.callTimeout = callTimeout; self.synthTimeout = synthTimeout
        self.clock = clock; self.holdTimeout = holdTimeout
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
            hold(line)   // a confirm line is not held: it is stale after a call
            return
        }
        if line.kind == .confirm {
            // Your answer comes before older lines, after earlier answers.
            let at = queue.firstIndex { $0.kind != .confirm } ?? queue.endIndex
            queue.insert(line, at: at)
        } else {
            queue.append(line)
        }
        runIfNeeded()
    }

    /// The session's prompt was answered, so its held "needs you" lines are stale.
    public func sessionAnswered(_ session: String) {
        held.dropAnswered(session: session)
        updateState()
    }

    /// You started talking (the wake word, the hotkey, a follow-up). The line
    /// that is playing stops and is not said again; the rest waits.
    public func beginListening() async {
        listening += 1
        owed = true
        if let id = currentLine {
            bargedIn = true
            await player.stop(id)
        }
        let ducker = self.ducker
        await bounded(callTimeout, ()) { await ducker.begin() }
    }

    public func endListening() async {
        guard listening > 0 else { return }
        listening -= 1
        guard listening == 0 else { return }
        // A running run ends the ducking in its tail; otherwise end it here.
        if !running, queue.isEmpty, owed, !holdActive {
            owed = false
            let ducker = self.ducker
            await bounded(callTimeout, ()) { await ducker.end() }
        }
        runIfNeeded()
    }

    /// When this line finishes playing, nothing else starts and the ducking
    /// stays on until releaseHold (or the safety timeout), so a follow-up
    /// window can open before the next line. A line that does not finish
    /// (stopped, dropped) creates no hold. It may be called before the line
    /// is enqueued, so a line that ends at once is still held.
    public func holdAfter(_ id: UUID) { holdIDs.insert(id) }

    /// Releases the hold that belongs to this line only: the finished event of an
    /// earlier line, handled late, cannot free the hold of a later one.
    public func releaseHold(_ id: UUID) {
        guard holdLine == id else { return }
        endHold()
    }

    private func endHold() {
        guard holdActive else { return }
        holdLine = nil
        holdActive = false
        holdGeneration += 1
        runIfNeeded()
    }

    private func startHold(_ id: UUID) {
        holdActive = true
        holdLine = id
        owed = true   // the ducking is ended when the hold is released
        holdGeneration += 1
        let generation = holdGeneration
        Task { [holdTimeout] in
            try? await Task.sleep(for: holdTimeout)
            self.holdTimedOut(generation)
        }
    }

    private func holdTimedOut(_ generation: Int) {
        guard holdActive, holdGeneration == generation else { return }
        endHold()
    }

    public func lineEvents() -> AsyncStream<LineEvent> {
        let (stream, cont) = AsyncStream<LineEvent>.makeStream()
        let id = UUID()
        lineConts[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.removeLineCont(id) } }
        return stream
    }
    private func removeLineCont(_ id: UUID) { lineConts[id] = nil }
    private func emit(_ e: LineEvent) { lineConts.values.forEach { $0.yield(e) } }

    /// Returns when nothing is queued or playing.
    public func waitUntilIdle() async {
        if !running && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: -

    private func hold(_ line: SpokenLine) {
        // A held line that is said again gets its hold anew when it starts.
        holdIDs.remove(line.id)
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
        while true {
        while !queue.isEmpty, listening == 0, !holdActive {
            let line = queue.removeFirst()
            if clock().timeIntervalSince(line.received) > maxWait {
                log.info("dropped a line that waited over \(Int(self.maxWait)) s")
                holdIDs.remove(line.id)
                continue
            }
            if line.kind != .roll, await micBusy() { hold(line); continue }
            let synth = self.synth
            let made = await bounded(synthTimeout, URL?.none) { await synth.audio(for: line) }
            let url = made ?? Self.errorTone
            // A call may have started while the audio was made.
            if line.kind != .roll, await micBusy() { hold(line); continue }
            // You began talking while the audio was made: it waits for endListening.
            if listening > 0 {
                // Same order rule as enqueue: answers stay ahead of other lines.
                let at = line.kind == .confirm ? 0 : (queue.firstIndex { $0.kind != .confirm } ?? queue.endIndex)
                queue.insert(line, at: at)
                break
            }
            // From here a call that starts interrupts this line.
            currentLine = line.id
            interrupted = false
            bargedIn = false
            state = .speaking
            // Every line renews the ducking, so its safety cap never cuts a long run short.
            let ducker = self.ducker
            await bounded(callTimeout, ()) { await ducker.begin() }
            ducked = true
            emit(.started(line))
            let finished: Bool
            var playedToEnd = false
            if interrupted || bargedIn {
                finished = false   // a call or your voice began while the ducking started
            } else if let done = await playWithTimeout(url, id: line.id) {
                finished = done
                playedToEnd = done
            } else {
                // Playback did not finish in time, for example a start that hangs
                // inside Core Audio while a headset switches mode. Move on, so the
                // queue and the ducking never stay stuck.
                log.error("a line did not finish in time; skipped it")
                await player.stop(line.id)
                finished = true
            }
            currentLine = nil
            if !(playedToEnd && made != nil) { holdIDs.remove(line.id) }   // it never finished: no hold
            if playedToEnd, made != nil {
                if holdIDs.remove(line.id) != nil { startHold(line.id) }
                emit(.finished(line))
            }
            emit(.ended(line))
            if !finished && interrupted {
                // A call started: say this line and the rest later.
                hold(line)
                for rest in queue where rest.kind != .roll { hold(rest) }
                queue.removeAll { $0.kind != .roll }
            }
            // Stopped because you talked: the line is dropped; the queue waits for endListening.
        }
        if listening == 0, !holdActive, ducked || owed {
            ducked = false
            owed = false
            let ducker = self.ducker
            await bounded(callTimeout, ()) { await ducker.end() }
        }
        // Lines or a listening begin that arrived during the awaited end: go again.
        if listening == 0, !holdActive, !queue.isEmpty || owed { continue }
        break
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
