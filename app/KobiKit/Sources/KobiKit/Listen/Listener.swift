import Foundation
import os

/// Hears one command at a time: after "Hey Kobi", while the hotkey is
/// held, or in a short window after Kobi asked something. Audio lives
/// only in the ring buffer, and a command's audio is erased once it is heard.
///
/// A wake has two tiers (see wakeWords). A greeting, then the name written as such
/// ("Hey Kobi, stop", or "Hey Kobe, stop", which sounds the same), chimes and sends the
/// words after it. "Kobi" alone at the start ("Kobi, stop") may chime, but nothing said
/// with it is sent: Kobi waits for the command, said after the chime, since a mention whose
/// start the mic cut off ("did you ask kobi to run the tests" heard as "Kobe. To run.")
/// sounds the same.
public actor Listener {
    public enum FollowUp: Sendable, Equatable {
        /// The answer to a permission prompt Kobi just announced.
        case approval(id: String)
        /// The answer to a question Kobi just asked ("Which one?").
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
        /// The mic's noise gate likely cut the start of what was said (see ClipLevel.gated).
        public let gated: Bool
        /// The same clip as the second hearing heard it, when it was in time.
        public let second: String?

        public init(text: String, trigger: Trigger, endedAt: ContinuousClock.Instant, tooLong: Bool = false,
                    plain: String? = nil, gated: Bool = false, second: String? = nil) {
            self.text = text; self.trigger = trigger; self.endedAt = endedAt; self.tooLong = tooLong; self.plain = plain
            self.gated = gated; self.second = second
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
        /// After a line of Kobi's that says the wake phrase, how long a wake is still its own voice.
        public var ownWakeGrace: Duration
        /// How long Kobi's lines are remembered, to drop a wake that repeats one.
        public var ownLineMemory: Duration
        /// Speech that starts this soon after a follow-up's chime is the chime or the
        /// tail of Kobi's line, not the answer.
        public var followUpSettle: Duration
        /// After the hotkey is let go, how long the capture goes on, for the last word.
        public var releaseTail: Duration
        /// How long a hold waits for the mic's first audio before the chime. A mic
        /// can take most of a second after it opens to send anything, and a chime
        /// before then tells you to talk into a mic that isn't recording yet.
        /// Exact zeros count as audio: a webcam's noise gate sends them until you talk.
        public var soundWait: Duration
        /// After the transcript, how much longer the second hearing may take.
        /// It runs alongside and is usually done first; a late one is left out.
        public var secondGrace: Duration
        /// The longest a transcription may take, the model's first load included. One
        /// that hangs past it ends the capture unheard, so Kobi isn't left listening
        /// with its lines held back.
        public var transcribeLimit: Duration = .seconds(30)
        /// The longest the second look at a wake may take (see WakeConfirmer). One that
        /// runs past it is taken as no answer: the wake passes only on a strict spotter
        /// score (CtcWakeSpotter.unconfirmedThreshold). Apple's recognizer answers in about
        /// 51 ms (59 ms at the 95th percentile) on the wake bench.
        public var confirmLimit: Duration = .milliseconds(750)

        public init(wakeSilence: Duration = .seconds(8), followUp: Duration = .seconds(6),
                    minHold: Duration = .milliseconds(200), maxCommandSamples: Int = 15 * 16_000,
                    preRollSamples: Int = 4_800, spotAtSamples: Int = 24_000, spotWindowSamples: Int = 32_000,
                    minClipSamples: Int = 4_800, reopenDelay: Duration = .milliseconds(500),
                    ownWakeGrace: Duration = .seconds(1), ownLineMemory: Duration = .seconds(10),
                    followUpSettle: Duration = .milliseconds(250), releaseTail: Duration = .milliseconds(200),
                    soundWait: Duration = .seconds(1), secondGrace: Duration = .milliseconds(300)) {
            self.wakeSilence = wakeSilence; self.followUp = followUp; self.minHold = minHold
            self.maxCommandSamples = maxCommandSamples; self.preRollSamples = preRollSamples
            self.spotAtSamples = spotAtSamples; self.spotWindowSamples = spotWindowSamples
            self.minClipSamples = minClipSamples; self.reopenDelay = reopenDelay
            self.ownWakeGrace = ownWakeGrace; self.ownLineMemory = ownLineMemory
            self.followUpSettle = followUpSettle; self.releaseTail = releaseTail
            self.soundWait = soundWait; self.secondGrace = secondGrace
        }
    }

    /// A command being heard.
    private struct Capture {
        let id = UUID()
        var trigger: Trigger
        var start: Int
        /// Waiting for speech to begin: after "Hey Kobi" alone, or in a follow-up window.
        var waitingForSpeech: Bool
        /// After "Hey Kobi" alone: this clip is the command itself.
        var commandPhase = false
        /// A follow-up takes speech only from here on (see Timing.followUpSettle), by when
        /// its audio came in, so audio held back and processed later is judged by its own time.
        var acceptFrom: ContinuousClock.Instant?
        /// When a wake's listening chime played (showWake). The window a wake opens without
        /// its command takes speech from Timing.followUpSettle after it, not after the
        /// wake's transcription (see openCommandWindow).
        var chimedAt: ContinuousClock.Instant?
        /// The hotkey was let go: the capture ends after Timing.releaseTail.
        var released = false
        /// A wake the spotter heard that the confirmer has not passed yet. Its audio
        /// goes on into the ring, but nothing shows or sounds: no orb level, no
        /// captureBegan (so no barge-in), no chime. See confirmed(_:text:score:).
        var confirming = false
        /// Where the segment ended while the wake was being confirmed.
        var endAt: Int?
        /// A later segment, begun and ended while the wake was being confirmed: after
        /// "Hey Kobi" alone, the command, said before the wake passed.
        var after: Range<Int>?
        /// The command ran past the length cap while the wake was being confirmed:
        /// the first seconds, kept for tooLong's check, since the ring moves on.
        var cappedHead: [Float]?
        /// What was said ended during the confirm (or ran past the cap): a pass
        /// finishes it at once, and the VAD's later edges are not its own.
        var heardOut: Bool { endAt != nil || cappedHead != nil }
        /// Passed, and being shown (captureBegan, the chime). Until that is done the
        /// VAD's edges are noted, as during the confirm, so it never ends before it began.
        var showing = false
        /// The confirmer's words passed the wake (in any tier of wakeWords), not the strict
        /// score alone: at finish a transcript without a greeting and the phrase sends nothing
        /// and the listener waits for the command, rather than dropping the wake (see finishRemainder).
        var passedOnWords = false
    }

    private let input: any AudioInput
    private let gate: any SpeechGate
    private let spotter: any WakeSpotter
    private var confirmer: any WakeConfirmer
    private let transcriber: any Transcriber
    private let second: (any SecondHearing)?
    private let chimes: any Chimes
    private let timing: Timing
    private var observer: (any ListenObserver)?
    private let log = Logger(subsystem: "com.kobi.app", category: "listener")

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
    /// The segment began while Kobi said the wake phrase (or just after): its own voice.
    private var segmentOwn = false
    private var spotted = false
    private var capture: Capture?
    /// The confirmer's answer on the wake being confirmed (true: it passed), so a
    /// follow-up or a click can wait for it, and not for the passed wake's show and
    /// transcription. Resolved in confirmed(_:text:score:), or when the wake is dropped.
    private var decision: (id: UUID, passed: Task<Bool, Never>, answer: AsyncStream<Bool>.Continuation)?
    /// A wake that passed its confirm, being shown (and finished, when what was said
    /// already ended). Audio waits for it (see confirmed(_:text:score:)).
    private var audioHeld: Task<Void, Never>?
    /// Where the last capture's audio ended in the ring, so the next one never starts before it.
    private var lastCaptureEnd = 0
    private var hotkeyHeld = false
    private var holdTask: Task<Void, Never>?
    private var pressID = 0
    private var openTask: Task<Bool, Never>?
    private var stopTask: Task<Void, Never>?
    /// Callers that are opening the mic to start a capture of their own.
    private var pendingOpens = 0
    /// The line Kobi is saying now, if any.
    private var speaking: String?
    /// Until then a wake is Kobi's own voice: a line of its own that says the wake phrase just ended.
    private var ownWakeUntil: ContinuousClock.Instant?
    /// Kobi's recent lines, normalised, with when they were last heard.
    private var ownLines: [(text: String, at: ContinuousClock.Instant)] = []

    /// Wakes that were not you: the confirmer's words did not start with the wake
    /// phrase, no recognizer could judge it and the spotter's score was under the strict
    /// threshold, the transcript of a wake passed on that score alone had no wake words at
    /// all (wakeWords), or it was Kobi's own voice. A wake passed on words whose transcript
    /// lacks the phrase is not counted, nor one passed on the score whose transcript has
    /// "Kobi" alone first: each waits for the command (see finishRemainder).
    public private(set) var falseWakes = 0

    public init(input: any AudioInput, gate: any SpeechGate, spotter: any WakeSpotter, transcriber: any Transcriber,
                second: (any SecondHearing)? = nil, confirmer: any WakeConfirmer = PassThroughConfirmer(),
                chimes: any Chimes, timing: Timing = Timing()) {
        self.input = input; self.gate = gate; self.spotter = spotter; self.transcriber = transcriber
        self.second = second; self.confirmer = confirmer
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
    /// The second look at a wake. Takes effect from the next wake.
    public func setConfirmer(_ c: any WakeConfirmer) { confirmer = c }

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

    /// What Kobi is saying now (nil when it went quiet), so it never wakes
    /// itself: a session named "kobi" makes it say the wake phrase.
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

    /// A wake now would be Kobi's own voice: it is saying the wake phrase, or just said it.
    private var ownVoiceWake: Bool {
        if let speaking, Self.mentionsWake(speaking) { return true }
        if let until = ownWakeUntil, ContinuousClock.now < until { return true }
        return false
    }

    /// The transcript is part of a line Kobi said in the last few seconds.
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
        if !on, let c = capture, c.confirming { discard(c) }
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
        // The hotkey wins over a wake still being confirmed, which nobody saw or heard.
        if let c = capture, c.confirming { discard(c) }
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
        if await waitForConfirm() { return }
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

    /// You clicked the orb: listens for one command, as after "Hey Kobi" on
    /// its own, ending when you stop talking or after the wake word's silence.
    public func tapToTalk() async {
        if await waitForConfirm() { return }
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
        if let second { Task { await second.prepare() } }
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
        // A wake still being confirmed shows nothing.
        let shown = capture.map { !$0.confirming } ?? false
        level.set(shown ? AudioLevel.fromSamples(samples) : 0)
        let at = ContinuousClock.now
        for c in chunker.push(samples) { await process(c, heardAt: at) }
    }

    /// `heardAt`: when the mic buffer that completed the chunk came in. A wake being shown
    /// holds audio back (audioHeld), so a chunk can be processed well after it was heard.
    private func process(_ chunk: [Float], heardAt: ContinuousClock.Instant) async {
        if let held = audioHeld { await held.value }
        ring.append(chunk)
        if let c = capture, c.trigger == .hotkey {
            if ring.total - c.start >= maxCommand { await tooLong(c) }
            return
        }
        // Stage 1: quiet audio skips the VAD, unless something is being heard.
        let loud = energy.admit(chunk)
        guard loud || segmentStart != nil || capture != nil else { return }
        let edge = await gate.feed(chunk)
        if edge == .start, var c = capture, c.waitingForSpeech, let from = c.acceptFrom, heardAt < from {
            // Too soon after a follow-up's chime: the chime or the tail of Kobi's line.
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
            segmentOwn = ownVoiceWake   // a short line is spotted at its end, after Kobi went quiet
            if var c = capture, c.waitingForSpeech, let s = segmentStart {
                c.start = max(c.start, s)   // never reach back before the window opened
                c.waitingForSpeech = false
                capture = c
            }
        }
        if let c = capture, !c.waitingForSpeech {
            if c.confirming || c.showing {
                // A wake being confirmed (or passed, and being shown): note where what was
                // said ended, at its segment's end or at the length cap. The confirm's
                // answer decides what happens to it.
                if edge == .end {
                    if !c.heardOut {
                        capture?.endAt = ring.total
                    } else if c.after == nil, let end = c.endAt, let s = segmentStart {
                        // Another segment after a pause: the command, when the wake was the phrase alone.
                        capture?.after = max(s, end)..<ring.total
                    }
                    segmentStart = nil
                } else if !c.heardOut, ring.total - c.start >= maxCommand {
                    capture?.cappedHead = ring.samples(from: c.start, to: c.start + timing.spotWindowSamples)
                }
                return
            }
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
            let score = await spotter.wakeScore(window)
            let woke = score.map { $0 >= CtcWakeSpotter.threshold(sensitivity) } ?? false
            if woke, segmentOwn || ownBefore || ownVoiceWake {
                // Kobi said the wake phrase itself (a session named "kobi"): not a wake, no barge-in.
                falseWakes += 1
            } else if woke, capture == nil, !refused, micOpen {
                log.info("wake fired at \(score ?? 0, privacy: .public); confirming")
                // Nothing shows yet: the words of the same window must start with the wake
                // phrase first. The confirm runs on its own, so audio keeps coming in.
                var c = Capture(trigger: .wake, start: s, waitingForSpeech: false)
                c.confirming = true
                if edge == .end { c.endAt = ring.total }
                capture = c
                let (answers, answer) = AsyncStream<Bool>.makeStream()
                decision = (c.id, Task { for await passed in answers { return passed }; return false }, answer)
                Task { [confirmer, limit = timing.confirmLimit, score = score ?? -.infinity] in
                    let text = await bounded(limit, String?.none) { await confirmer.headText(window) }
                    await self.confirmed(c.id, text: text, score: score)
                }
            }
        }
        if edge == .end { segmentStart = nil }
    }

    // MARK: - Confirming a wake

    /// The confirmer's answer for a wake the spotter heard, whose window scored `score`.
    /// A pass does what a wake always did; a reject ends it silently, as if the spotter
    /// had not fired. Words pass when they start with the wake phrase in any tier of
    /// wakeWords. The finish decides what is a command, from the transcripts. Nil (no recognizer could tell, or the
    /// confirm was too slow) passes only when the score reaches
    /// CtcWakeSpotter.unconfirmedThreshold: at the usual threshold alone the spotter would
    /// chime about 140 times an hour of speech.
    private func confirmed(_ id: UUID, text: String?, score: Float) async {
        guard capture?.id == id, capture?.confirming == true else { return }
        // A press not yet held long enough: wait to see what it is. Held on, it wins
        // and drops the wake (see holdConfirmed); a tap or a chord changes nothing.
        if hotkeyHeld, let press = holdTask { await press.value }
        guard let c = capture, c.id == id, c.confirming else { return }
        guard !refused, micOpen, armed else { discard(c); return }
        let tier = text.flatMap { repeatsOwnLine($0) ? nil : Self.wakeWords($0) }
        let isWake = text == nil ? score >= CtcWakeSpotter.unconfirmedThreshold : tier != nil
        guard isWake, !ownVoiceWake else {
            falseWakes += 1
            discard(c)
            await closeMicIfIdle()
            settlePhase()
            return
        }
        capture?.passedOnWords = tier != nil
        let how: String
        switch tier {
        case .literal?: how = "the phrase"
        case .bare?: how = "the name alone first"
        case nil: how = "the strict score"
        }
        log.info("wake passed on \(how, privacy: .public)")
        decide(id, passed: true)
        // Audio waits while the wake is shown and, when what was said already ended,
        // finished, as it did when a wake was shown as the audio came in. Otherwise a
        // command said right after "Hey Kobi" alone could start before the capture
        // that waits for it, and pass for unrelated speech.
        let pass = Task { await self.showWake(id) }
        audioHeld = pass
        await pass.value
        if audioHeld == pass { audioHeld = nil }
    }

    /// A wake that passed its confirm: what a wake always did, then, when what was
    /// said ended during the confirm, the command is all there and is finished at once.
    private func showWake(_ id: UUID) async {
        // A hotkey press, a call or disarming may have dropped it since the pass.
        guard var c = capture, c.id == id, c.confirming else { return }
        c.confirming = false
        c.showing = true
        capture = c
        phase = .capturing(.wake)
        startPrewarm()
        await observer?.captureBegan(.wake)
        if capture?.id == id { capture?.chimedAt = .now }
        await chimes.play(.listening)
        guard var now = capture, now.id == id else { return }
        now.showing = false
        capture = now
        if now.cappedHead != nil {
            await tooLong(now)
        } else if let end = now.endAt {
            await finish(now, end: end)
        }
    }

    /// Forgets a wake still being confirmed. Nobody saw or heard it, so nothing
    /// ends either: no captureEnded, no chime.
    private func discard(_ c: Capture) {
        guard let current = capture, current.id == c.id, current.confirming else { return }
        capture = nil
        decide(c.id, passed: false)
        settlePhase()
    }

    /// The confirm of wake `id` is over: it passed, or it is gone.
    private func decide(_ id: UUID, passed: Bool) {
        guard let d = decision, d.id == id else { return }
        decision = nil
        d.answer.yield(passed)
        d.answer.finish()
    }

    /// Waits for the confirmer's answer on a wake being confirmed, so a window that
    /// opens now neither overlaps a real wake nor is lost to one that turns out not to
    /// be. Only the answer: a passed wake's show and transcription are not waited for.
    /// At most Timing.confirmLimit, and Timing.minHold for a press the answer waits on.
    /// Returns true when the wake passed: it is the one being heard, so the caller backs off.
    private func waitForConfirm() async -> Bool {
        guard let c = capture, c.confirming, let d = decision, d.id == c.id else { return false }
        return await bounded(timing.confirmLimit + timing.minHold, false) { await d.passed.value }
    }

    // MARK: - Ending a capture

    /// The capture's audio, which is then erased from the ring: once heard, a
    /// command is kept only as text.
    private func takeClip(_ c: Capture, end: Int) -> [Float] {
        let clip = ring.samples(from: c.start, to: end)
        Self.keepForDebugging(clip)
        ring.erase(upTo: end)
        return clip
    }

    /// Stage 4: transcribes the clip and hands it on. For a wake, only the words after a
    /// greeting and the phrase written as such are a command (finishRemainder); a wake passed
    /// on words whose transcripts lack them, or on the score whose words have "Kobi" alone
    /// first, sends nothing and waits for a command said after the chime
    /// (openCommandWindow).
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
        var other: String?
        // A wake's own clip is heard without names that spell the wake phrase (wakeVocabulary).
        let names = c.trigger == .wake && !c.commandPhase ? Self.wakeVocabulary(vocabulary) : vocabulary
        if clip.count >= timing.minClipSamples {
            // The second hearing starts with the first and gets a short grace after it.
            let heardToo: Task<String?, Never>? = second.map { s in
                Task { await s.hear(clip, names: names) }
            }
            defer { heardToo?.cancel() }
            if let r = await transcription({ [transcriber] in
                try await transcriber.transcribeBoth(clip, vocabulary: names)
            }) {
                (text, plain) = r
                plain = plain?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // A wake passed on words may find the phrase only in the second hearing, so it is
            // waited for even when the transcript came back empty.
            let wakeOnWords = c.trigger == .wake && !c.commandPhase && c.passedOnWords
            if let heardToo, !text.isEmpty || wakeOnWords {
                other = await bounded(timing.secondGrace, nil) { await heardToo.value }
                other = other?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A result that arrives after a call started, or the Mac locked, is dropped.
        let dropped = refused
        if c.trigger == .wake, !c.commandPhase {
            if repeatsOwnLine(text) {
                // The mic heard Kobi's own line.
                falseWakes += 1
                text = ""
            } else if let rest = Self.finishRemainder(text, plain: plain, second: other, passedOnWords: c.passedOnWords) {
                text = rest
                // The other hearings lose the wake phrase too, by the same rule; without it they can't be compared.
                plain = plain.flatMap(Self.wakeRemainder)
                if plain == text { plain = nil }   // the command came from the unboosted words
                other = other.map { Self.wakeRemainder($0) ?? $0 }
                if text.isEmpty, !dropped, capture == nil, micOpen {
                    // "Hey Kobi" alone: keep listening for the command, from where the wake ended.
                    await openCommandWindow(after: c, end: end, carryOver: true)
                    return
                }
            } else if c.passedOnWords || Self.wakeWords(plain ?? text) != nil {
                // A wake passed on words whose transcripts don't start with a greeting and the
                // name written as such ("Kobi, stop", or a mention cut off at the start,
                // "Kobe. To run."): none of its words are sent.
                // It chimed, so the command is the next thing said, after the chime. The same for
                // a wake passed on the strict score alone whose unboosted words have "Kobi"
                // alone first (not the literal tier, which finishRemainder took).
                text = ""
                plain = nil
                other = nil
                if !dropped, capture == nil, micOpen {
                    await openCommandWindow(after: c, end: end, carryOver: false)
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
                                          plain: plain?.isEmpty == false ? plain : nil, gated: ClipLevel.gated(clip),
                                          second: other?.isEmpty == false ? other : nil))
        } else if !refused, capture == nil {
            await chimes.play(.closed)
        }
        await closeMicIfIdle()
        settlePhase()
    }

    /// After a wake that sent nothing, listens for the command, from where the wake ended.
    /// `carryOver` (after "Hey Kobi" alone): speech begun or said while the wake was
    /// being confirmed is the command. Without it (a wake passed on words whose transcripts
    /// lack a greeting and the phrase, such as "Kobi" alone first), only
    /// speech that starts after the chime is, as in a follow-up window:
    /// what went on during the confirm may be the rest of a sentence that was not to Kobi.
    private func openCommandWindow(after c: Capture, end: Int, carryOver: Bool) async {
        var next = Capture(trigger: .wake, start: max(end, ring.oldest), waitingForSpeech: true, commandPhase: true)
        if carryOver {
            if let said = c.after {
                // The whole command was said while the wake was being confirmed.
                next.start = said.lowerBound
                next.waitingForSpeech = false
                capture = next
                phase = .capturing(.wake)
                await finish(next, end: said.upperBound)
                return
            }
            if let s = segmentStart {
                // The command began while the wake was being confirmed, and its start
                // edge went by. The wake's own segment ended at `end`, so this one is
                // later: the capture starts with it, and its end edge or the cap ends it.
                next.start = max(next.start, s)
                next.waitingForSpeech = false
            }
        } else {
            // The chime has played (showWake plays it before any finish). A segment still going
            // started before it: its end edge finds the window waiting and is passed over.
            // The settle runs from the chime: audio was held through the show and this clip's
            // transcription, and a command said meanwhile would otherwise count as too soon.
            next.acceptFrom = (c.chimedAt ?? .now) + timing.followUpSettle
        }
        capture = next
        phase = .capturing(.wake)
        scheduleTimeout(next.id, after: timing.wakeSilence)
    }

    /// A transcription's result, or nil when it failed or ran past `timing.transcribeLimit`.
    /// A late one is left to finish on its own; a first load it was waiting on is kept.
    private func transcription<T: Sendable>(_ run: @escaping @Sendable () async throws -> T) async -> T? {
        let result = await bounded(timing.transcribeLimit, Result<T, any Error>?.none) {
            do { return .success(try await run()) } catch { return .failure(error) }
        }
        switch result {
        case .success(let r)?: return r
        case .failure(let error)?:
            log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
        case nil:
            log.error("transcription took longer than \(self.timing.transcribeLimit, privacy: .public)")
        }
        return nil
    }

    /// For debugging recognition only: with KOBI_KEEP_AUDIO set to a folder in
    /// the environment the app was launched with, each command's audio is written
    /// there as a 16 kHz WAV. Unset (always, in normal use), nothing is written,
    /// and audio stays in memory as promised.
    static func keepForDebugging(_ clip: [Float]) {
        guard let dir = ProcessInfo.processInfo.environment["KOBI_KEEP_AUDIO"], !dir.isEmpty, !clip.isEmpty else { return }
        var pcm = Data(capacity: clip.count * 2)
        for x in clip {
            var v = Int16(max(-1, min(1, x)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        wav += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(16_000)) + le(UInt32(32_000)) + le(UInt16(2)) + le(UInt16(16))
        wav += Data("data".utf8) + le(UInt32(pcm.count)) + pcm
        let name = "command-\(Int(Date().timeIntervalSince1970)).wav"
        try? wav.write(to: URL(fileURLWithPath: dir).appending(path: name))
    }

    /// The command ran past the cap while you were still talking. Sending it cut off
    /// would send half of it, so it is dropped and Kobi says it was too long. Only
    /// a wake capture's first seconds are transcribed, to check it was the wake word.
    private func tooLong(_ c: Capture) async {
        guard capture?.id == c.id else { return }
        capture = nil
        lastCaptureEnd = ring.total
        let head = c.cappedHead ?? ring.samples(from: c.start, to: c.start + timing.spotWindowSamples)
        ring.erase(upTo: ring.total)
        await dropSegment()
        var heard = true
        if c.trigger == .wake, !c.commandPhase {
            phase = .transcribing
            let text = await transcription { [transcriber] in try await transcriber.transcribe(head, vocabulary: []) } ?? ""
            if repeatsOwnLine(text) || Self.finishRemainder(text, passedOnWords: c.passedOnWords) == nil {
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
        guard let current = capture, current.id == c.id else { return }
        capture = nil
        ring.erase(upTo: ring.total)
        // A wake still being confirmed was never shown, so it never ends either.
        if current.confirming { decide(c.id, passed: false) } else { await observer?.captureEnded(heard: false) }
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
        if let c = capture, !c.confirming { phase = .capturing(c.trigger); return }
        phase = micOpen && armed ? .waiting : .off
    }

    // MARK: - Text

    nonisolated(unsafe) private static let wakePrefix = try! Regex(
        #"^\s*(?:(?:hey|hi|ok|okay|a)[\s,.!]*)?(?:kobi|kobe|koby)\b[\s,.!?]*"#
    ).ignoresCase()

    nonisolated(unsafe) private static let wakeAnywhere = try! Regex(#"\b(?:kobi|kobe|koby)\b"#).ignoresCase()

    /// The text after the wake phrase, or nil when it does not start with it.
    public static func stripWake(_ text: String) -> String? {
        guard let m = text.prefixMatch(of: wakePrefix) else { return nil }
        return String(text[m.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How a text says the wake phrase at its start, when it does (see wakeWords(_:)).
    public enum WakeWords: Sendable, Equatable {
        /// A greeting, then the name written as such: "Kobi", "Kobe" or "Koby" (nameSpellings).
        /// `remainder` is the words after it, as written (empty for the phrase alone).
        /// Only this tier ever gives a command.
        case literal(remainder: String)
        /// The name as the first word, standing apart ("Kobe, stop", "Kobi."). A
        /// noise gate that cuts the start of a mention leaves the same words ("did you ask
        /// kobi to run the tests" heard as "Kobe. To run."), so the words after it are never
        /// a command: the wake may chime, and the command is the next thing said.
        case bare
    }

    /// What recognizers wrote for "hey", "hi" and "okay" on the wake bench, besides the
    /// words themselves ("K Kobe" for "Okay Kobi", "I Kobe" for "Hi Kobi"). No verbs: "take
    /// Kobe to the vet" is a sentence.
    private static let greetings: Set<String> = ["hey", "hi", "high", "hay", "hate", "eight", "8", "a", "i", "k", "ok", "okay"]

    /// How recognizers write "Kobi" when they get it right. Apple's recognizer writes "Kobe"
    /// for most of them, and almost never "Kobi"; "Koby" now and then. "Kobe" is said the
    /// same, so "Hey Kobe" wakes too. "Coby" is left out: on the wake bench's tune split it
    /// woke 6 more of 3200 positives, and 3 near-misses and mentions too, so it comes from
    /// other names as well.
    static let nameSpellings: Set<String> = ["kobi", "kobe", "koby"]

    /// Whether the text starts with the wake phrase, and in which tier. Two shapes pass:
    /// - a greeting, then "Kobi" (nameSpellings) as the next word: literal.
    /// - "Kobi" as the first word, with no greeting, standing apart: a comma or a stop right
    ///   after it, or nothing after it ("Kobi, stop", "Kobe."): bare. Run into a sentence it
    ///   is a mention ("Kobi is listening", "Kobe beef is expensive"). Never later in the
    ///   text: "did you ask kobi to run the tests" is about Kobi, not to it.
    /// Names that only sound like it ("Hey Colby", "Hey Toby") never pass: on the wake bench's
    /// tune split, taking "Colby" after a greeting as a window-only wake woke 30 more of 3200
    /// positives and 169 more of 6200 near-misses (kobi-probe wake-rescore).
    public static func wakeWords(_ text: String) -> WakeWords? {
        let (tokens, words) = wakeTokens(text)
        guard let first = words.first else { return nil }
        if greetings.contains(first), words.count > 1, nameSpellings.contains(words[1]) {
            return .literal(remainder: remainder(text, after: tokens[1]))
        }
        if nameSpellings.contains(first), words.count == 1 || ",.!?".contains(tokens[0].last!) { return .bare }
        return nil
    }

    /// The words after the wake phrase in the literal tier (see wakeWords): trimmed, with
    /// the punctuation right after the phrase dropped, empty for the phrase alone. Nil when
    /// the text does not start with a greeting and the phrase written as such.
    public static func wakeRemainder(_ text: String) -> String? {
        guard case .literal(let rest)? = wakeWords(text) else { return nil }
        return rest
    }

    /// The command in a finished wake's transcripts, or nil when none of them start with a
    /// greeting and the phrase written as such (wakeRemainder). `text` is the boosted
    /// transcript, `plain` the unboosted one (nil when the boost changed nothing, so `text` is
    /// unboosted too) and `second` the second hearing's.
    /// Whether there is a command is decided on the unboosted words, `plain ?? text`, and for a
    /// wake passed on the confirmer's words also on `second`, never on the boosted words alone:
    /// a session named "kobe" makes the boost write the name over words that only sound
    /// like it, so "Hey Toby, stop the build." could read as "Hey Kobe, stop the build."
    /// The command is the boosted words after the phrase when they start with it too, so the
    /// names in it are kept; otherwise the unboosted words', then the second hearing's.
    /// Nil means this clip's words are not a command. For a wake passed on words, and for one
    /// passed on the strict score alone whose unboosted words have "Kobi" alone first or a
    /// (wakeWords), the listener waits for the next; otherwise it is a false wake.
    public static func finishRemainder(_ text: String, plain: String? = nil, second: String? = nil,
                                       passedOnWords: Bool) -> String? {
        if let rest = wakeRemainder(plain ?? text) { return wakeRemainder(text) ?? rest }
        guard passedOnWords, let second else { return nil }
        return wakeRemainder(second)
    }

    /// The names a wake's own clip is heard with: those whose letters have a spelling of the
    /// name in them ("kobi", "Kobe app", "kobi-web") left out. With one, the boost writes the
    /// name over words that only sound like it, and they would pass as the phrase written as such.
    public static func wakeVocabulary(_ names: [String]) -> [String] {
        names.filter { name in
            let l = SoundsLike.letters(name)
            return !nameSpellings.contains { l.contains($0) }
        }
    }

    /// The text's words (those with a letter or digit), and each as the letters compared.
    private static func wakeTokens(_ text: String) -> (tokens: [Substring], words: [String]) {
        let tokens = text.split(whereSeparator: \.isWhitespace).filter { !SoundsLike.letters(String($0)).isEmpty }
        return (tokens, tokens.map { SoundsLike.letters(String($0)) })
    }

    /// The text after `token` (one of its words), trimmed, with the punctuation right after it dropped,
    /// so what follows the phrase keeps its own spelling.
    private static func remainder(_ text: String, after token: Substring) -> String {
        let after = text[token.endIndex...]
        let skip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let start = after.unicodeScalars.firstIndex { !skip.contains($0) } ?? after.endIndex
        return String(after[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the words of a wake's head start with the wake phrase, in any tier (see
    /// wakeWords): the confirm's rule, so "Kobi" alone first may chime too.
    public static func confirmsWake(_ text: String) -> Bool { wakeWords(text) != nil }

    /// The name anywhere in the text ("Kobi needs your OK"), as Kobi's own lines may say it.
    public static func mentionsWake(_ text: String) -> Bool { text.contains(wakeAnywhere) }

    /// Lowercase letters and digits only, so "Hey, Kobi" and "hey kobi" compare equal.
    static func squash(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
