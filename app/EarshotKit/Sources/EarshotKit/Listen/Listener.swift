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
        holdTask?.cancel()
        holdTask = Task { [minHold = timing.minHold] in
            try? await Task.sleep(for: minHold)
            guard !Task.isCancelled else { return }
            await self.holdConfirmed()
        }
    }

    /// Held long enough: from here it is a command. Before this the mic is
    /// not opened and nothing is chimed or lowered, so a tap or a chord
    /// (Right Option types characters on some layouts) changes nothing. When
    /// the wake word already has the mic open, the last 0.3 s count too.
    private func holdConfirmed() async {
        guard hotkeyHeld, !micBusy else { return }
        if let c = capture, case .followUp = c.trigger { capture = nil }   // the hotkey takes over
        else if capture != nil { return }
        let wasOpen = micOpen
        await openMic()
        // Released, or a call started, while the mic opened.
        guard micOpen, hotkeyHeld, !micBusy, capture == nil else { await closeMicIfIdle(); return }
        let start = wasOpen ? max(ring.oldest, ring.total - timing.preRollSamples) : ring.total
        capture = Capture(trigger: .hotkey, start: start, waitingForSpeech: false)
        phase = .capturing(.hotkey)
        await chimes.play(.listening)
        await observer?.captureBegan(.hotkey)
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
        await openMic()
        guard micOpen else { return }
        await gate.reset()
        let c = Capture(trigger: .followUp(f), start: ring.total, waitingForSpeech: true)
        capture = c
        phase = .capturing(c.trigger)
        await chimes.play(.listening)
        await observer?.captureBegan(c.trigger)
        scheduleTimeout(c.id, after: within ?? timing.followUp)
    }

    /// Another app opened the mic: drop what is being heard and close the mic.
    public func setMicBusy(_ busy: Bool) async {
        micBusy = busy
        guard busy else { return }
        holdTask?.cancel()
        holdTask = nil
        if let c = capture { await drop(c) }
        await closeMic()
        settlePhase()
    }

    // MARK: - Audio

    private func openMic() async {
        guard !micOpen, !micBusy else { return }
        do {
            let stream = try await input.start()
            micOpen = true
            streamTask = Task { [weak self] in
                for await samples in stream { await self?.receive(samples) }
            }
        } catch {
            log.error("couldn't open the mic: \(error.localizedDescription, privacy: .public)")
        }
    }

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
            if ring.total - c.start >= timing.maxCommandSamples { await finish(c, end: ring.total) }
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
                c.start = s
                c.waitingForSpeech = false
                capture = c
            }
        }
        if let c = capture, !c.waitingForSpeech {
            if edge == .end || ring.total - c.start >= timing.maxCommandSamples {
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
            if await spotter.heardWake(window, sensitivity: sensitivity), capture == nil, !micBusy {
                let c = Capture(trigger: .wake, start: s, waitingForSpeech: false)
                capture = c
                phase = .capturing(.wake)
                await chimes.play(.listening)
                await observer?.captureBegan(.wake)
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
        if c.trigger == .wake, let rest = Self.stripWake(text) {
            text = rest
            if text.isEmpty {
                // "Hey Earshot" alone: keep listening for the command.
                let next = Capture(trigger: .wake, start: ring.total, waitingForSpeech: true)
                capture = next
                phase = .capturing(.wake)
                scheduleTimeout(next.id, after: timing.wakeSilence)
                return
            }
        }
        await observer?.captureEnded(heard: !text.isEmpty)
        if text.isEmpty {
            await chimes.play(.closed)
        } else {
            utteranceCont.yield(Utterance(text: text, trigger: c.trigger, endedAt: .now))
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
