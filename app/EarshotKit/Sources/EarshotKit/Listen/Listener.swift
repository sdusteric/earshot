import Foundation
import os

/// Hears one command at a time: after "Hey Earshot", while the hotkey is
/// held, or in a short window after Earshot asked something. Audio lives
/// only in the ring buffer.
public actor Listener {
    public enum FollowUp: Sendable, Equatable {
        /// The answer to a permission prompt Earshot just announced.
        case approval(id: String)
        /// The answer to a question Earshot just asked ("Which one?").
        case reply
    }

    public enum Trigger: Sendable, Equatable { case wake, hotkey, followUp(FollowUp) }

    public struct Utterance: Sendable, Equatable {
        public let text: String
        public let trigger: Trigger
        public let endedAt: ContinuousClock.Instant
    }

    public enum Phase: Sendable, Equatable { case off, waiting, capturing(Trigger), transcribing }

    public struct Timing: Sendable {
        public var wakeSilence: Duration
        public var followUp: Duration
        public var minHold: Duration
        public var maxCommandSamples: Int
        public var preRollSamples: Int
        public var spotAtSamples: Int
        public var spotWindowSamples: Int
        public var minClipSamples: Int

        public init(wakeSilence: Duration = .seconds(8), followUp: Duration = .seconds(6),
                    minHold: Duration = .milliseconds(200), maxCommandSamples: Int = 15 * 16_000,
                    preRollSamples: Int = 4_800, spotAtSamples: Int = 24_000, spotWindowSamples: Int = 32_000,
                    minClipSamples: Int = 4_800) {
            self.wakeSilence = wakeSilence; self.followUp = followUp; self.minHold = minHold
            self.maxCommandSamples = maxCommandSamples; self.preRollSamples = preRollSamples
            self.spotAtSamples = spotAtSamples; self.spotWindowSamples = spotWindowSamples
            self.minClipSamples = minClipSamples
        }
    }

    /// A command being heard.
    private struct Capture {
        let id = UUID()
        var trigger: Trigger
        var start: Int
        /// Waiting for speech to begin: after "Hey Earshot" alone, or in a follow-up window.
        var waitingForSpeech: Bool
        /// After "Hey Earshot" alone: this clip is the command itself.
        var commandPhase = false
    }

    private let input: any AudioInput
    private let gate: any SpeechGate
    private let spotter: any WakeSpotter
    private let transcriber: any Transcriber
    private let chimes: any Chimes
    private let timing: Timing
    private var observer: (any ListenObserver)?
    private let log = Logger(subsystem: "com.earshot.app", category: "listener")

    public nonisolated let utterances: AsyncStream<Utterance>
    private let utteranceCont: AsyncStream<Utterance>.Continuation
    private var phaseConts: [UUID: AsyncStream<Phase>.Continuation] = [:]
    private var phase: Phase = .off {
        didSet { if phase != oldValue { phaseConts.values.forEach { $0.yield(phase) } } }
    }

    private var ring = SampleRing()
    private var chunker = Chunker()
    private var energy = EnergyGate()
    private var streamTask: Task<Void, Never>?
    private var micOpen = false
    private var armed = false
    private var micBusy = false
    private var sensitivity = 5
    private var vocabulary: [String] = []
    private var segmentStart: Int?
    private var spotted = false
    private var capture: Capture?
    private var hotkeyHeld = false
    private var holdTask: Task<Void, Never>?
    private var pressID = 0
    private var openTask: Task<Void, Never>?
    /// Callers that are opening the mic to start a capture of their own.
    private var pendingOpens = 0

    /// Wake captures whose transcript did not start with the wake phrase.
    public private(set) var falseWakes = 0

    public init(input: any AudioInput, gate: any SpeechGate, spotter: any WakeSpotter, transcriber: any Transcriber,
                chimes: any Chimes, timing: Timing = Timing()) {
        self.input = input; self.gate = gate; self.spotter = spotter; self.transcriber = transcriber
        self.chimes = chimes; self.timing = timing
        let (stream, cont) = AsyncStream<Utterance>.makeStream()
        utterances = stream
        utteranceCont = cont
    }

    public func setObserver(_ o: any ListenObserver) { observer = o }
    public func setSensitivity(_ s: Int) { sensitivity = s }
    public func setVocabulary(_ v: [String]) { vocabulary = v }

    public func phaseChanges() -> AsyncStream<Phase> {
        let (stream, cont) = AsyncStream<Phase>.makeStream()
        let id = UUID()
        phaseConts[id] = cont
        cont.yield(phase)
        cont.onTermination = { [weak self] _ in Task { await self?.removePhaseCont(id) } }
        return stream
    }
    private func removePhaseCont(_ id: UUID) { phaseConts[id] = nil }

    // MARK: - Triggers

    /// The wake word may listen (see ListenPolicy). Opens or closes the mic.
    public func setWakeArmed(_ on: Bool) async {
        armed = on
        if on { await openMic() } else { await closeMicIfIdle() }
        settlePhase()
    }

    public func hotkeyDown() async {
        guard !micBusy, !hotkeyHeld else { return }
        hotkeyHeld = true
        pressID += 1
        let press = pressID
        holdTask?.cancel()
        holdTask = Task { [minHold = timing.minHold] in
            try? await Task.sleep(for: minHold)
            guard !Task.isCancelled else { return }
            await self.holdConfirmed(press)
        }
    }

    /// Held long enough: from here it is a command. Before this the mic is
    /// not opened and nothing is chimed or lowered, so a tap or a chord
    /// (Right Option types characters on some layouts) changes nothing. When
    /// the wake word already has the mic open, the last 0.3 s count too.
    private func holdConfirmed(_ press: Int) async {
        guard hotkeyHeld, pressID == press, !micBusy else { return }
        let wasOpen = micOpen
        await openMic()
        // Released, pressed again, or a call started, while the mic opened.
        guard micOpen, hotkeyHeld, pressID == press, !micBusy else { await closeMicIfIdle(); return }
        if let c = capture {
            guard case .followUp = c.trigger else { return }
            // The hotkey takes over: end the follow-up before the new capture begins.
            capture = nil
            await observer?.captureEnded(heard: false)
            guard micOpen, hotkeyHeld, pressID == press, !micBusy, capture == nil else {
                await closeMicIfIdle()
                settlePhase()
                return
            }
        }
        let start = wasOpen ? max(ring.oldest, ring.total - timing.preRollSamples) : ring.total
        capture = Capture(trigger: .hotkey, start: start, waitingForSpeech: false)
        phase = .capturing(.hotkey)
        startPrewarm()
        await observer?.captureBegan(.hotkey)
        await chimes.play(.listening)
    }

    public func hotkeyUp() async {
        guard hotkeyHeld else { return }
        hotkeyHeld = false
        holdTask?.cancel()
        holdTask = nil
        if let c = capture, c.trigger == .hotkey {
            ring.append(chunker.drain())
            await finish(c, end: ring.total)
        } else {
            await closeMicIfIdle()
            settlePhase()
        }
    }

    public func hotkeyCancel() async {
        guard hotkeyHeld else { return }
        hotkeyHeld = false
        holdTask?.cancel()
        holdTask = nil
        if let c = capture, c.trigger == .hotkey { await drop(c) }
        await closeMicIfIdle()
        settlePhase()
    }

    /// Listens once without the wake word, for a few seconds.
    public func listenFollowUp(_ f: FollowUp, within: Duration? = nil) async {
        guard !micBusy, capture == nil, !hotkeyHeld else { return }
        await openMic(counted: true)
        await gate.reset()
        guard micOpen, !micBusy, capture == nil, !hotkeyHeld else {
            await closeMicIfIdle()
            settlePhase()
            return
        }
        let c = Capture(trigger: .followUp(f), start: ring.total, waitingForSpeech: true)
        capture = c
        phase = .capturing(c.trigger)
        await observer?.captureBegan(c.trigger)
        scheduleTimeout(c.id, after: within ?? timing.followUp)
        await chimes.play(.listening)
    }

    /// Another app opened the mic: drop what is being heard and close the mic.
    public func setMicBusy(_ busy: Bool) async {
        micBusy = busy
        guard busy else {
            if armed { await openMic() }
            settlePhase()
            return
        }
        holdTask?.cancel()
        holdTask = nil
        if let c = capture { await drop(c) }
        await closeMic()
        settlePhase()
    }

    // MARK: - Audio

    /// Opens the mic. Opens are serialised: a caller that arrives while one
    /// is in flight waits for it. `counted` marks a caller that will start a
    /// capture once the mic is open, so the mic is wanted even if nothing else needs it.
    private func openMic(counted: Bool = false) async {
        if counted { pendingOpens += 1 }
        defer { if counted { pendingOpens -= 1 } }
        guard !micOpen, !micBusy else { return }
        if openTask == nil { openTask = Task { await self.performOpen() } }
        await openTask?.value
    }

    private func performOpen() async {
        defer { openTask = nil }
        do {
            let stream = try await input.start()
            _ = chunker.drain()
            segmentStart = nil
            spotted = false
            await gate.reset()
            // start() and reset() suspend: a call may have started, or nobody may want the mic any more.
            guard !micBusy, armed || capture != nil || hotkeyHeld || pendingOpens > 0 else {
                await input.stop()
                return
            }
            micOpen = true
            streamTask = Task { [weak self] in
                for await samples in stream { await self?.receive(samples) }
            }
        } catch {
            log.error("couldn't open the mic: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startPrewarm() {
        Task { [transcriber] in await transcriber.prewarm() }
    }

    /// A command can't be longer than what the ring still holds, less the pre-roll.
    private var maxCommand: Int { min(timing.maxCommandSamples, ring.capacity - timing.preRollSamples) }

    private func closeMic() async {
        guard micOpen else { return }
        micOpen = false
        streamTask?.cancel()
        streamTask = nil
        await input.stop()
        _ = chunker.drain()
        segmentStart = nil
        spotted = false
        await gate.reset()
    }

    private func closeMicIfIdle() async {
        if !armed, capture == nil, !hotkeyHeld { await closeMic() }
    }

    private func receive(_ samples: [Float]) async {
        for c in chunker.push(samples) { await process(c) }
    }

    private func process(_ chunk: [Float]) async {
        ring.append(chunk)
        if let c = capture, c.trigger == .hotkey {
            if ring.total - c.start >= maxCommand { await finish(c, end: ring.total) }
            return
        }
        // Stage 1: quiet audio skips the VAD, unless something is being heard.
        let loud = energy.admit(chunk)
        guard loud || segmentStart != nil || capture != nil else { return }
        let edge = await gate.feed(chunk)
        if edge == .start {
            // The VAD fires a little after speech starts: include the chunk before.
            segmentStart = max(ring.oldest, ring.total - 2 * chunk.count)
            spotted = false
            if var c = capture, c.waitingForSpeech, let s = segmentStart {
                c.start = max(c.start, s)   // never reach back before the window opened
                c.waitingForSpeech = false
                capture = c
            }
        }
        if let c = capture, !c.waitingForSpeech {
            if edge == .end || ring.total - c.start >= maxCommand {
                segmentStart = nil
                await finish(c, end: ring.total)
            }
            return
        }
        // Stage 3: the wake word, once per segment, at 1.5 s or at its end.
        if armed, capture == nil, let s = segmentStart, !spotted,
           ring.total - s >= timing.spotAtSamples || edge == .end {
            spotted = true
            let window = ring.samples(from: s, to: s + timing.spotWindowSamples)
            if await spotter.heardWake(window, sensitivity: sensitivity), capture == nil, !micBusy, micOpen {
                let c = Capture(trigger: .wake, start: s, waitingForSpeech: false)
                capture = c
                phase = .capturing(.wake)
                startPrewarm()
                await observer?.captureBegan(.wake)
                await chimes.play(.listening)
                if edge == .end { segmentStart = nil; await finish(c, end: ring.total) }
            }
        }
        if edge == .end { segmentStart = nil }
    }

    // MARK: - Ending a capture

    /// Stage 4: transcribes the clip and hands it on.
    private func finish(_ c: Capture, end: Int) async {
        guard capture?.id == c.id else { return }
        capture = nil
        phase = .transcribing
        let clip = ring.samples(from: c.start, to: end)
        var text = ""
        if clip.count >= timing.minClipSamples {
            do {
                text = try await transcriber.transcribe(clip, vocabulary: vocabulary)
            } catch {
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A result that arrives after a call started is dropped.
        let dropped = micBusy
        if c.trigger == .wake, !c.commandPhase {
            if let rest = Self.stripWake(text) {
                text = rest
                if text.isEmpty, !dropped, capture == nil, micOpen {
                    // "Hey Earshot" alone: keep listening for the command.
                    let next = Capture(trigger: .wake, start: ring.total, waitingForSpeech: true, commandPhase: true)
                    capture = next
                    phase = .capturing(.wake)
                    scheduleTimeout(next.id, after: timing.wakeSilence)
                    return
                }
            } else {
                falseWakes += 1
                text = ""
            }
        }
        if dropped { text = "" }
        let heard = !text.isEmpty
        await observer?.captureEnded(heard: heard)
        if heard {
            utteranceCont.yield(Utterance(text: text, trigger: c.trigger, endedAt: .now))
        } else if !dropped, capture == nil {
            await chimes.play(.closed)
        }
        await closeMicIfIdle()
        settlePhase()
    }

    /// Ends a capture without a command: a call started, or the hotkey was cancelled.
    private func drop(_ c: Capture) async {
        guard capture?.id == c.id else { return }
        capture = nil
        await observer?.captureEnded(heard: false)
    }

    private func scheduleTimeout(_ id: UUID, after: Duration) {
        Task {
            try? await Task.sleep(for: after)
            await self.timedOut(id)
        }
    }

    private func timedOut(_ id: UUID) async {
        guard let c = capture, c.id == id, c.waitingForSpeech else { return }
        capture = nil
        await chimes.play(.closed)
        await observer?.captureEnded(heard: false)
        await closeMicIfIdle()
        settlePhase()
    }

    private func settlePhase() {
        if let c = capture { phase = .capturing(c.trigger); return }
        phase = micOpen && armed ? .waiting : .off
    }

    // MARK: - Text

    nonisolated(unsafe) private static let wakePrefix = try! Regex(
        #"^\s*(?:(?:hey|hi|ok|okay|a)[\s,.!]*)?(?:ear\s*shot|air\s*shot|earshot)\b[\s,.!?]*"#
    ).ignoresCase()

    /// The text after the wake phrase, or nil when it does not start with it.
    public static func stripWake(_ text: String) -> String? {
        guard let m = text.prefixMatch(of: wakePrefix) else { return nil }
        return String(text[m.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
