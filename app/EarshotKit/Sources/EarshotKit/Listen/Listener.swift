import Foundation
import os

/// Hears one command at a time: after "Hey Earshot", while the hotkey is
/// held, or in a short window after Earshot asked something. Audio lives
/// only in the ring buffer, and a command's audio is erased once it is heard.
public actor Listener {
    public enum FollowUp: Sendable, Equatable {
        /// The answer to a permission prompt Earshot just announced.
        case approval(id: String)
        /// The answer to a question Earshot just asked ("Which one?").
        case reply
    }

    /// `tap`: the orb or the Activity window's Talk button was clicked, as deliberate as the hotkey.
    public enum Trigger: Sendable, Equatable { case wake, hotkey, tap, followUp(FollowUp) }

    public struct Utterance: Sendable, Equatable {
        public let text: String
        public let trigger: Trigger
        public let endedAt: ContinuousClock.Instant
        /// The command ran past the length cap: it was dropped, and text is empty.
        public let tooLong: Bool
        /// What was heard without session names boosted, when the boost changed it.
        /// The boost can turn a word into a name that sounds like it ("doing" into "wedding").
        public let plain: String?

        public init(text: String, trigger: Trigger, endedAt: ContinuousClock.Instant, tooLong: Bool = false,
                    plain: String? = nil) {
            self.text = text; self.trigger = trigger; self.endedAt = endedAt; self.tooLong = tooLong; self.plain = plain
        }
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
        /// How long to wait before reopening a mic that ended on its own.
        public var reopenDelay: Duration
        /// After a line of Earshot's that says the wake phrase, how long a wake is still its own voice.
        public var ownWakeGrace: Duration
        /// How long Earshot's lines are remembered, to drop a wake that repeats one.
        public var ownLineMemory: Duration
        /// Speech that starts this soon after a follow-up's chime is the chime or the
        /// tail of Earshot's line, not the answer.
        public var followUpSettle: Duration
        /// After the hotkey is let go, how long the capture goes on, for the last word.
        public var releaseTail: Duration
        /// How long a hold waits for the mic's first audio before the chime. A mic
        /// can take most of a second after it opens to send anything, and a chime
        /// before then tells you to talk into a mic that isn't recording yet.
        /// Exact zeros count as audio: a webcam's noise gate sends them until you talk.
        public var soundWait: Duration

        public init(wakeSilence: Duration = .seconds(8), followUp: Duration = .seconds(6),
                    minHold: Duration = .milliseconds(200), maxCommandSamples: Int = 15 * 16_000,
                    preRollSamples: Int = 4_800, spotAtSamples: Int = 24_000, spotWindowSamples: Int = 32_000,
                    minClipSamples: Int = 4_800, reopenDelay: Duration = .milliseconds(500),
                    ownWakeGrace: Duration = .seconds(1), ownLineMemory: Duration = .seconds(10),
                    followUpSettle: Duration = .milliseconds(250), releaseTail: Duration = .milliseconds(200),
                    soundWait: Duration = .seconds(1)) {
            self.wakeSilence = wakeSilence; self.followUp = followUp; self.minHold = minHold
            self.maxCommandSamples = maxCommandSamples; self.preRollSamples = preRollSamples
            self.spotAtSamples = spotAtSamples; self.spotWindowSamples = spotWindowSamples
            self.minClipSamples = minClipSamples; self.reopenDelay = reopenDelay
            self.ownWakeGrace = ownWakeGrace; self.ownLineMemory = ownLineMemory
            self.followUpSettle = followUpSettle; self.releaseTail = releaseTail
            self.soundWait = soundWait
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
        /// A follow-up takes speech only from here on (see Timing.followUpSettle).
        var acceptFrom: ContinuousClock.Instant?
        /// The hotkey was let go: the capture ends after Timing.releaseTail.
        var released = false
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
    /// The mic's loudness while a command is being captured, for the orb. 0 otherwise.
    public nonisolated let level = AudioLevel()
    private let utteranceCont: AsyncStream<Utterance>.Continuation
    private var phaseConts: [UUID: AsyncStream<Phase>.Continuation] = [:]
    private var phase: Phase = .off {
        didSet { if phase != oldValue { phaseConts.values.forEach { $0.yield(phase) } } }
    }

    private var ring: SampleRing
    private var chunker = Chunker()
    private var energy = EnergyGate()
    private var streamTask: Task<Void, Never>?
    private var streamID = 0
    private var micOpen = false
    /// The mic has sent audio since it opened, and where in the ring it starts.
    private var heardSound = false
    private var soundAt = 0
    private var armed = false
    private var micBusy = false
    /// The Mac is locked or asleep, or listening can't work now (see ListenPolicy.commandBlock).
    private var blocked = false
    /// The mic must stay closed: a call, or blocked.
    private var refused: Bool { micBusy || blocked }
    private var sensitivity = 5
    private var vocabulary: [String] = []
    /// The mic chosen in Settings (nil inside: Automatic), and the choice when the
    /// mic last opened. Outer nil: not told yet.
    private var inputDevice: String??
    private var openedWith: String??
    private var segmentStart: Int?
    /// The segment began while Earshot said the wake phrase (or just after): its own voice.
    private var segmentOwn = false
    private var spotted = false
    private var capture: Capture?
    /// Where the last capture's audio ended in the ring, so the next one never starts before it.
    private var lastCaptureEnd = 0
    private var hotkeyHeld = false
    private var holdTask: Task<Void, Never>?
    private var pressID = 0
    private var openTask: Task<Bool, Never>?
    private var stopTask: Task<Void, Never>?
    /// Callers that are opening the mic to start a capture of their own.
    private var pendingOpens = 0
    /// The line Earshot is saying now, if any.
    private var speaking: String?
    /// Until then a wake is Earshot's own voice: a line of its own that says the wake phrase just ended.
    private var ownWakeUntil: ContinuousClock.Instant?
    /// Earshot's recent lines, normalised, with when they were last heard.
    private var ownLines: [(text: String, at: ContinuousClock.Instant)] = []

    /// Wakes that were not you: the transcript did not start with the wake
    /// phrase, or it was Earshot's own voice.
    public private(set) var falseWakes = 0

    public init(input: any AudioInput, gate: any SpeechGate, spotter: any WakeSpotter, transcriber: any Transcriber,
                chimes: any Chimes, timing: Timing = Timing()) {
        self.input = input; self.gate = gate; self.spotter = spotter; self.transcriber = transcriber
        self.chimes = chimes; self.timing = timing
        ring = Self.ring(timing)
        let (stream, cont) = AsyncStream<Utterance>.makeStream()
        utterances = stream
        utteranceCont = cont
    }

    /// Samples received since the mic opened (tests wait on it).
    var capturedSamples: Int { ring.total }
    /// The audio the ring still holds (tests check it was erased).
    var heldAudio: [Float] { ring.samples(from: ring.oldest) }

    /// Room for the longest command and the pre-roll before it, about 15 s
    /// (1 MB). Empty until the mic delivers audio.
    private static func ring(_ t: Timing) -> SampleRing { SampleRing(capacity: t.maxCommandSamples + t.preRollSamples) }

    public func setObserver(_ o: any ListenObserver) { observer = o }
    public func setSensitivity(_ s: Int) { sensitivity = s }
    public func setVocabulary(_ v: [String]) { vocabulary = v }

    /// The mic chosen in Settings. The input reads the choice only when it
    /// opens, so a change reopens a mic the wake word holds open, at once or
    /// when the command being heard ends.
    public func setInputDevice(_ uid: String?) async {
        inputDevice = .some(uid)
        if micOpen, openedWith == nil { openedWith = .some(uid) }   // the first call: what is open is current
        await applyInputDevice()
    }

    private func applyInputDevice() async {
        guard micOpen, let wanted = inputDevice, let opened = openedWith, wanted != opened,
              capture == nil, !hotkeyHeld, pendingOpens == 0, !refused else { return }
        log.info("the mic choice changed; reopening the mic")
        await closeMic()
        await openMic()
        settlePhase()
    }

    /// What Earshot is saying now (nil when it went quiet), so it never wakes
    /// itself: a session named "earshot" makes it say the wake phrase.
    public func setSpeaking(_ text: String?) {
        let now = ContinuousClock.now
        if let text {
            speaking = text
            ownLines.append((Self.squash(text), now))
        } else if let line = speaking {
            speaking = nil
            if Self.mentionsWake(line) { ownWakeUntil = now + timing.ownWakeGrace }
            if let i = ownLines.lastIndex(where: { $0.text == Self.squash(line) }) { ownLines[i].at = now }
        }
        ownLines.removeAll { now - $0.at > timing.ownLineMemory && $0.text != speaking.map(Self.squash) }
    }

    /// A wake now would be Earshot's own voice: it is saying the wake phrase, or just said it.
    private var ownVoiceWake: Bool {
        if let speaking, Self.mentionsWake(speaking) { return true }
        if let until = ownWakeUntil, ContinuousClock.now < until { return true }
        return false
    }

    /// The transcript is part of a line Earshot said in the last few seconds.
    private func repeatsOwnLine(_ transcript: String) -> Bool {
        let t = Self.squash(transcript)
        guard !t.isEmpty else { return false }
        let now = ContinuousClock.now, current = speaking.map(Self.squash)
        return ownLines.contains { (now - $0.at <= timing.ownLineMemory || $0.text == current) && $0.text.contains(t) }
    }

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
        guard !refused, !hotkeyHeld else { return }
        if let c = capture, c.trigger == .hotkey, c.released {
            // A press inside the release tail: what was said is done, so the tail
            // ends now and this press starts the next command.
            // The capture is taken here, so the new hold never finds it.
            ring.append(chunker.drain())
            capture = nil
            let end = ring.total
            lastCaptureEnd = end
            let clip = takeClip(c, end: end)
            Task {
                await self.dropSegment()
                await self.finish(c, end: end, claimed: true, clip: clip)
            }
        }
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
        guard hotkeyHeld, pressID == press, !refused else { return }
        let wasOpen = micOpen
        await openMic()
        // Released, pressed again, or a call started, while the mic opened.
        guard micOpen, hotkeyHeld, pressID == press, !refused else { await closeMicIfIdle(); return }
        if let c = capture {
            guard case .followUp = c.trigger else { return }
            // The hotkey takes over: end the follow-up before the new capture begins.
            capture = nil
            await observer?.captureEnded(heard: false)
            guard micOpen, hotkeyHeld, pressID == press, !refused, capture == nil else {
                await closeMicIfIdle()
                settlePhase()
                return
            }
        }
        if !wasOpen {
            // The chime means "talk now": it waits until the mic is recording, and the
            // command starts there.
            await waitForSound(upTo: timing.soundWait)
            guard micOpen, hotkeyHeld, pressID == press, !refused, capture == nil else {
                await closeMicIfIdle()
                settlePhase()
                return
            }
        }
        let start = wasOpen ? max(ring.oldest, ring.total - timing.preRollSamples, lastCaptureEnd)
            : heardSound ? max(ring.oldest, soundAt) : ring.total
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
        if var c = capture, c.trigger == .hotkey {
            // Keep listening a moment: the last word often ends after the key comes up.
            c.released = true
            capture = c
            Task { [tail = timing.releaseTail] in
                try? await Task.sleep(for: tail)
                await self.finishReleased(c.id)
            }
        } else {
            await closeMicIfIdle()
            settlePhase()
        }
    }

    private func finishReleased(_ id: UUID) async {
        guard let c = capture, c.id == id, c.released else { return }
        ring.append(chunker.drain())
        // Hotkey chunks skipped the gate, so reset it first: that clears stale VAD
        // state without wiping a wake segment that starts during the transcription.
        await dropSegment()
        await finish(c, end: ring.total)
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
        guard !refused, capture == nil, !hotkeyHeld else { return }
        pendingOpens += 1
        await openMic()
        await gate.reset()
        pendingOpens -= 1
        guard micOpen, !refused, capture == nil, !hotkeyHeld else {
            await closeMicIfIdle()
            settlePhase()
            return
        }
        var c = Capture(trigger: .followUp(f), start: ring.total, waitingForSpeech: true)
        c.acceptFrom = .now + timing.followUpSettle
        capture = c
        phase = .capturing(c.trigger)
        startPrewarm()   // the model may have unloaded since the last command
        await observer?.captureBegan(c.trigger)
        scheduleTimeout(c.id, after: within ?? timing.followUp)
        // Speech is taken only from a moment after the chime starts.
        if capture?.id == c.id { capture?.acceptFrom = .now + timing.followUpSettle }
        await chimes.play(.listening)
    }

    /// You clicked the orb: listens for one command, as after "Hey Earshot" on
    /// its own, ending when you stop talking or after the wake word's silence.
    public func tapToTalk() async {
        guard !refused, capture == nil, !hotkeyHeld else { return }
        pendingOpens += 1
        await openMic()
        await gate.reset()
        pendingOpens -= 1
        guard micOpen, !refused, capture == nil, !hotkeyHeld else {
            await closeMicIfIdle()
            settlePhase()
            return
        }
        var c = Capture(trigger: .tap, start: ring.total, waitingForSpeech: true, commandPhase: true)
        // The listening chime is not part of the command.
        c.acceptFrom = .now + timing.followUpSettle
        capture = c
        phase = .capturing(.tap)
        startPrewarm()
        await observer?.captureBegan(.tap)
        scheduleTimeout(c.id, after: timing.wakeSilence)
        if capture?.id == c.id { capture?.acceptFrom = .now + timing.followUpSettle }
        await chimes.play(.listening)
    }

    /// Another app opened the mic: drop what is being heard and close the mic.
    public func setMicBusy(_ busy: Bool) async {
        micBusy = busy
        await refusalChanged()
    }

    /// The Mac locked or went to sleep, or listening can't work now: no
    /// follow-up, no hotkey, and what is being heard is dropped, as for a call.
    public func setBlocked(_ b: Bool) async {
        blocked = b
        await refusalChanged()
    }

    private func refusalChanged() async {
        guard refused else {
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
    /// is in flight waits for it, and starts another if that one gave up
    /// while the mic is still wanted.
    private func openMic() async {
        while !micOpen, !refused {
            if openTask == nil { openTask = Task { await self.performOpen() } }
            let gaveUp = await openTask?.value ?? false
            guard gaveUp, micWanted else { return }
        }
    }

    /// Something needs the mic: wake word armed, a capture, a held hotkey, or
    /// a follow-up that is still opening it.
    private var micWanted: Bool { armed || capture != nil || hotkeyHeld || pendingOpens > 0 }

    /// Returns true when the mic was opened and then given up, because it was no longer wanted.
    private func performOpen() async -> Bool {
        await stopTask?.value
        do {
            let stream = try await input.start()
            _ = chunker.drain()
            // Nothing from before the mic closed: no pre-roll reaches it, and the last command's audio is gone.
            ring = Self.ring(timing)
            lastCaptureEnd = 0
            segmentStart = nil
            spotted = false
            await gate.reset()
            // start() and reset() suspend: a call may have started, or nobody may want the mic any more.
            guard !refused, micWanted else {
                // Clear this open before stopping, so a caller that comes during the stop starts its own.
                openTask = nil
                let stopping = Task { await self.input.stop() }
                stopTask = stopping
                await stopping.value
                if stopTask == stopping { stopTask = nil }
                return true
            }
            micOpen = true
            heardSound = false
            openedWith = inputDevice
            streamID += 1
            let id = streamID
            streamTask = Task { [weak self] in
                for await samples in stream { await self?.receive(samples) }
                // Cancelled means closeMic ended it. Otherwise the input gave up.
                if !Task.isCancelled { await self?.streamEnded(id) }
            }
        } catch {
            log.error("couldn't open the mic: \(error.localizedDescription, privacy: .public)")
        }
        openTask = nil
        return false
    }

    /// The input ended its stream without being asked (a failed rebuild after
    /// a device change). Treat it as the mic closing, then try once to reopen.
    private func streamEnded(_ id: Int) async {
        guard id == streamID, micOpen else { return }
        log.error("the mic stopped on its own")
        micOpen = false
        streamTask = nil
        _ = chunker.drain()
        segmentStart = nil
        spotted = false
        if let c = capture { await drop(c) }
        await input.stop()
        await gate.reset()
        settlePhase()
        guard micWanted, !refused else { return }
        Task { [delay = timing.reopenDelay] in
            try? await Task.sleep(for: delay)
            await self.reopenAfterLoss()
        }
    }

    /// The one retry. If start() fails again the mic stays closed.
    private func reopenAfterLoss() async {
        guard !micOpen, !refused, micWanted else { return }
        await openMic()
        settlePhase()
    }

    private func startPrewarm() {
        Task { [transcriber] in await transcriber.prewarm() }
    }

    /// A command can't be longer than what the ring still holds, less the pre-roll.
    /// The ring is sized for Timing.maxCommandSamples, so this is that cap.
    private var maxCommand: Int { min(timing.maxCommandSamples, ring.capacity - timing.preRollSamples) }

    /// A capture ended without an end edge from the VAD (the length cap, or a
    /// hotkey hold): forget the segment and reset the VAD, which would
    /// otherwise stay triggered and never report the next speech start.
    private func dropSegment() async {
        segmentStart = nil
        spotted = false
        await gate.reset()
    }

    private func closeMic() async {
        guard micOpen else { return }
        micOpen = false
        level.set(0)
        streamTask?.cancel()
        streamTask = nil
        await input.stop()
        _ = chunker.drain()
        // No audio is kept while the mic is closed.
        ring = Self.ring(timing)
        lastCaptureEnd = 0
        segmentStart = nil
        spotted = false
        await gate.reset()
    }

    /// Closes the mic when nothing needs it. When the wake word keeps it open,
    /// a mic choice made meanwhile applies now.
    private func closeMicIfIdle() async {
        guard capture == nil, !hotkeyHeld, pendingOpens == 0 else { return }
        if !armed { await closeMic() } else { await applyInputDevice() }
    }

    /// Returns once the mic has sent audio, or after `limit`, or when it closes.
    private func waitForSound(upTo limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !heardSound, micOpen, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func receive(_ samples: [Float]) async {
        if !heardSound, !samples.isEmpty {
            heardSound = true
            soundAt = ring.total + chunker.pendingCount
        }
        // Per mic buffer (about 85 ms), not per 256 ms chunk, so the orb keeps up.
        level.set(capture == nil ? 0 : AudioLevel.fromSamples(samples))
        for c in chunker.push(samples) { await process(c) }
    }

    private func process(_ chunk: [Float]) async {
        ring.append(chunk)
        if let c = capture, c.trigger == .hotkey {
            if ring.total - c.start >= maxCommand { await tooLong(c) }
            return
        }
        // Stage 1: quiet audio skips the VAD, unless something is being heard.
        let loud = energy.admit(chunk)
        guard loud || segmentStart != nil || capture != nil else { return }
        let edge = await gate.feed(chunk)
        if edge == .start, var c = capture, c.waitingForSpeech, let from = c.acceptFrom, ContinuousClock.now < from {
            // Too soon after a follow-up's chime: the chime or the tail of Earshot's line.
            // Forget it, and reset the VAD so speech that goes on starts afresh.
            c.start = ring.total
            capture = c
            await gate.reset()
            return
        }
        if edge == .start {
            // The VAD fires a little after speech starts: include the chunk before.
            segmentStart = max(ring.oldest, ring.total - 2 * chunk.count)
            spotted = false
            segmentOwn = ownVoiceWake   // a short line is spotted at its end, after Earshot went quiet
            if var c = capture, c.waitingForSpeech, let s = segmentStart {
                c.start = max(c.start, s)   // never reach back before the window opened
                c.waitingForSpeech = false
                capture = c
            }
        }
        if let c = capture, !c.waitingForSpeech {
            if edge == .end {
                segmentStart = nil
                await finish(c, end: ring.total)
            } else if ring.total - c.start >= maxCommand {
                await tooLong(c)
            }
            return
        }
        // Stage 3: the wake word, once per segment, at 1.5 s or at its end.
        if armed, capture == nil, let s = segmentStart, !spotted,
           ring.total - s >= timing.spotAtSamples || edge == .end {
            spotted = true
            let window = ring.samples(from: s, to: s + timing.spotWindowSamples)
            let ownBefore = ownVoiceWake
            let woke = await spotter.heardWake(window, sensitivity: sensitivity)
            if woke, segmentOwn || ownBefore || ownVoiceWake {
                // Earshot said the wake phrase itself (a session named "earshot"): not a wake, no barge-in.
                falseWakes += 1
            } else if woke, capture == nil, !refused, micOpen {
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

    /// The capture's audio, which is then erased from the ring: once heard, a
    /// command is kept only as text.
    private func takeClip(_ c: Capture, end: Int) -> [Float] {
        let clip = ring.samples(from: c.start, to: end)
        ring.erase(upTo: end)
        return clip
    }

    /// Stage 4: transcribes the clip and hands it on.
    /// `claimed`: the capture was already taken off `capture` (a new press during the tail),
    /// and `clip` is its audio, taken then.
    private func finish(_ c: Capture, end: Int, claimed: Bool = false, clip taken: [Float]? = nil) async {
        guard claimed || capture?.id == c.id else { return }
        if !claimed {
            capture = nil
            phase = .transcribing
        }
        lastCaptureEnd = max(lastCaptureEnd, end)
        let clip = taken ?? takeClip(c, end: end)
        var text = ""
        var plain: String?
        if clip.count >= timing.minClipSamples {
            do {
                (text, plain) = try await transcriber.transcribeBoth(clip, vocabulary: vocabulary)
                plain = plain?.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A result that arrives after a call started, or the Mac locked, is dropped.
        let dropped = refused
        if c.trigger == .wake, !c.commandPhase {
            if repeatsOwnLine(text) {
                // The mic heard Earshot's own line.
                falseWakes += 1
                text = ""
            } else if let rest = Self.stripWake(text) {
                text = rest
                // The unboosted words lose the wake phrase too; without it they can't be compared.
                plain = plain.flatMap(Self.stripWake)
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
            utteranceCont.yield(Utterance(text: text, trigger: c.trigger, endedAt: .now,
                                          plain: plain?.isEmpty == false ? plain : nil))
        } else if !refused, capture == nil {
            await chimes.play(.closed)
        }
        await closeMicIfIdle()
        settlePhase()
    }

    /// The command ran past the cap while you were still talking. Sending it cut off
    /// would send half of it, so it is dropped and Earshot says it was too long. Only
    /// a wake capture's first seconds are transcribed, to check it was the wake word.
    private func tooLong(_ c: Capture) async {
        guard capture?.id == c.id else { return }
        capture = nil
        lastCaptureEnd = ring.total
        let head = ring.samples(from: c.start, to: c.start + timing.spotWindowSamples)
        ring.erase(upTo: ring.total)
        await dropSegment()
        var heard = true
        if c.trigger == .wake, !c.commandPhase {
            phase = .transcribing
            var text = ""
            do { text = try await transcriber.transcribe(head, vocabulary: []) } catch {
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            }
            if repeatsOwnLine(text) || Self.stripWake(text) == nil {
                falseWakes += 1
                heard = false
            }
        }
        if refused { heard = false }
        if !refused, capture == nil { await chimes.play(.closed) }
        await observer?.captureEnded(heard: heard)
        if heard { utteranceCont.yield(Utterance(text: "", trigger: c.trigger, endedAt: .now, tooLong: true)) }
        await closeMicIfIdle()
        settlePhase()
    }

    /// Ends a capture without a command: a call started, or the hotkey was cancelled.
    private func drop(_ c: Capture) async {
        guard capture?.id == c.id else { return }
        capture = nil
        ring.erase(upTo: ring.total)
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

    nonisolated(unsafe) private static let wakeAnywhere = try! Regex(#"\b(?:ear\s*shot|air\s*shot)\b"#).ignoresCase()

    /// The text after the wake phrase, or nil when it does not start with it.
    public static func stripWake(_ text: String) -> String? {
        guard let m = text.prefixMatch(of: wakePrefix) else { return nil }
        return String(text[m.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The wake phrase anywhere in the text ("Hey, earshot needs your OK").
    public static func mentionsWake(_ text: String) -> Bool { text.contains(wakeAnywhere) }

    /// Lowercase letters and digits only, so "Hey, Earshot" and "hey ear shot" compare equal.
    static func squash(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
