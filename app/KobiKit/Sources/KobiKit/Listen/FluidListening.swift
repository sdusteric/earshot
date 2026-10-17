@preconcurrency import FluidAudio
import Foundation
import os

/// Loads a value once: callers that arrive during a load wait for that load
/// instead of starting another. A failed load is not kept, so the next call tries again.
actor SingleFlight<T: Sendable> {
    private let load: @Sendable () async throws -> T
    private var value: T?
    private var task: Task<T, Error>?
    private(set) var loads = 0

    init(_ load: @escaping @Sendable () async throws -> T) { self.load = load }

    var isLoaded: Bool { value != nil }

    /// The value if it is loaded now. Never starts a load.
    var current: T? { value }

    func get() async throws -> T {
        if let value { return value }
        if let task { return try await task.value }
        let t = Task { try await load() }
        task = t
        loads += 1
        defer { if task == t { task = nil } }
        let v = try await t.value
        value = v
        return v
    }

    func clear() { value = nil; task = nil }
}

/// A model several parts use: loaded while any holder needs it, and let go
/// when the last holder releases it, so its memory is freed.
actor SharedLoad<T: Sendable> {
    private let flight: SingleFlight<T>
    private var holders: Set<String> = []

    init(_ load: @escaping @Sendable () async throws -> T) { flight = SingleFlight(load) }

    var isLoaded: Bool { get async { await flight.isLoaded } }
    var loads: Int { get async { await flight.loads } }

    /// The value if it is loaded now, for a reader that must not wait for a load and
    /// does not hold the model: it may be freed the moment after.
    func current() async -> T? { await flight.current }

    func acquire(_ holder: String) async throws -> T {
        holders.insert(holder)
        do {
            let v = try await flight.get()
            // Everyone let go during the load: do not keep it.
            if holders.isEmpty { await flight.clear() }
            return v
        } catch {
            holders.remove(holder)
            throw error
        }
    }

    func release(_ holder: String) async {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        await flight.clear()
    }
}

/// Lets a repeated failure into the log once, then at most once a minute.
struct FailureLog {
    private var last: ContinuousClock.Instant?
    var every: Duration = .seconds(60)

    mutating func shouldLog(now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < every { return false }
        last = now
        return true
    }
}

/// Where FluidAudio keeps the listening models:
/// ~/Library/Application Support/FluidAudio/Models.
public enum ListenModelFiles {
    static var vadDir: URL { MLModelConfigurationUtils.defaultModelsDirectory().appending(path: "silero-vad") }
    static var ctcDir: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }
    static var asrDir: URL { AsrModels.defaultCacheDirectory(for: .v2) }

    /// Some model files are on disk but not all: a download was cut off.
    public static var partial: Bool {
        guard !present else { return false }
        return [vadDir, ctcDir, asrDir].contains { dir in
            !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
        }
    }

    public static var present: Bool {
        let vad = (try? FileManager.default.contentsOfDirectory(atPath: vadDir.path))?.contains { $0.hasSuffix(".mlmodelc") } ?? false
        return vad && CtcModels.modelsExist(at: ctcDir) && AsrModels.modelsExist(at: asrDir, version: .v2)
    }
}

/// Downloads the three listening models once. Speaking works meanwhile.
public actor ListenModels {
    public enum State: Sendable, Equatable { case missing, downloading(Double), ready, failed }

    public private(set) var state: State {
        didSet { if state != oldValue { conts.values.forEach { $0.yield(state) } } }
    }
    private var conts: [UUID: AsyncStream<State>.Continuation] = [:]
    private let log = Logger(subsystem: "com.kobi.app", category: "models")

    public init() { state = ListenModelFiles.present ? .ready : .missing }

    public func download() async {
        if case .downloading = state { return }
        guard state != .ready else { return }
        state = .downloading(0)
        do {
            _ = try await VadManager()   // small; fetched when missing
            state = .downloading(0.05)
            try await CtcModels.download(variant: .ctc110m)
            state = .downloading(0.3)
            try await AsrModels.download(version: .v2, progressHandler: { p in
                Task { await self.progress(0.3 + 0.7 * p.fractionCompleted) }
            })
            state = ListenModelFiles.present ? .ready : .failed
        } catch {
            log.error("model download failed: \(error.localizedDescription, privacy: .public)")
            state = .failed
        }
    }

    private func progress(_ p: Double) {
        if case .downloading = state { state = .downloading(min(p, 0.99)) }
    }

    public func changes() -> AsyncStream<State> {
        let (stream, cont) = AsyncStream<State>.makeStream()
        let id = UUID()
        conts[id] = cont
        cont.yield(state)
        cont.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { conts[id] = nil }
}

/// Stage 2: Silero VAD, 4096-sample chunks. FluidAudio ends speech on the
/// first silent chunk plus `minSilenceDuration` more, so 0.4 s means 3 silent
/// chunks: speech ends after about 770 ms of silence. (0.6 s would be 4
/// chunks, 1 s; 0.2 s would cut people off at natural pauses.)
/// It loads itself on the first chunk, so follow-up answers work without the wake word.
public actor SileroGate: SpeechGate {
    private let flight: SingleFlight<VadManager>
    private var state = VadStreamState.initial()
    private let config = VadSegmentationConfig(minSilenceDuration: 0.4)
    private var failedAt: ContinuousClock.Instant?
    private var failures = FailureLog()
    private let retryAfter: Duration
    private let log = Logger(subsystem: "com.kobi.app", category: "vad")

    public init() { self.init(retryAfter: .seconds(30), load: { try await VadManager() }) }

    init(retryAfter: Duration, load: @escaping @Sendable () async throws -> VadManager) {
        self.retryAfter = retryAfter
        flight = SingleFlight(load)
    }

    var loads: Int { get async { await flight.loads } }

    public func load() async throws { _ = try await flight.get() }

    public func reset() async { state = VadStreamState.initial() }

    public func feed(_ chunk: [Float]) async -> SpeechEdge? {
        // A failed load is not retried on every chunk.
        if !(await flight.isLoaded), let failedAt, ContinuousClock.now - failedAt < retryAfter { return nil }
        let vad: VadManager
        do {
            vad = try await flight.get()
            failedAt = nil
        } catch {
            failedAt = .now
            if failures.shouldLog() { log.error("the VAD can't load: \(error.localizedDescription, privacy: .public)") }
            return nil
        }
        do {
            let r = try await vad.processStreamingChunk(chunk, state: state, config: config)
            state = r.state
            switch r.event?.kind {
            case .speechStart: return .start
            case .speechEnd: return .end
            default: return nil
            }
        } catch {
            if failures.shouldLog() { log.error("the VAD failed on a chunk: \(error.localizedDescription, privacy: .public)") }
            return nil
        }
    }
}

/// What the CTC model made of one clip, kept so a second reader of the same
/// clip (the wake confirmer) does not run the model again.
struct CtcPass: Sendable {
    /// The clip's length and a few of its values: the same clip gives the same key,
    /// and two different clips do not in practice (the model's input is not hashed whole).
    struct Key: Hashable, Sendable {
        let count: Int
        let probes: [UInt32]

        init(_ samples: [Float]) {
            count = samples.count
            let n = samples.count
            probes = n == 0 ? [] : (0..<8).map { samples[min(n - 1, $0 * n / 8)].bitPattern }
        }
    }

    let key: Key
    /// Only the frames that cover the clip: the rest is the zeros it was padded with.
    let logProbs: [[Float]]
}

/// The CTC model is shared: the wake word spotter and the vocabulary boost use it.
/// It is freed when neither holds it.
actor CtcShared {
    enum Holder: String { case spotter, boosting }
    static let shared = CtcShared()
    private let model = SharedLoad<CtcModels> { try await CtcModels.downloadAndLoad(variant: .ctc110m) }
    private var phraseTokens: [String: [Int]] = [:]
    private var lastPass: CtcPass?

    func models(for holder: Holder) async throws -> CtcModels { try await model.acquire(holder.rawValue) }

    func release(_ holder: Holder) async {
        await model.release(holder.rawValue)
        if !(await model.isLoaded) { lastPass = nil }
    }

    /// The model if some holder has it loaded now, else nil. A reader that is not a
    /// holder (the wake confirmer) uses this so it never waits for a load or keeps the model alive.
    func loadedModels() async -> CtcModels? { await model.current() }

    /// The clip with zeros out to the model's full input (15 s). FluidAudio 0.17.7 copies a
    /// shorter clip into a buffer it never clears, so the rest was whatever memory held,
    /// often NaN, and the model's output stopped depending on the audio: every sentence
    /// scored the same and woke Kobi (FluidAudio issue #991).
    /// FluidAudio's fix (PR #1003, merge e05ab923) is not in a tagged release yet. An A/B of
    /// 0.17.7 against e05ab923 was identical on the tests, the parser eval, the hearing bench
    /// and the spotter's scores. The padding stays with the fix too, for score parity:
    /// without it the scores move (309 of 1738 rows), and the thresholds were tuned with it.
    static func fullLength(_ samples: [Float]) -> [Float] {
        let n = ASRConstants.maxModelSamples
        return samples.count >= n ? samples : samples + [Float](repeating: 0, count: n - samples.count)
    }

    func tokens(_ text: String) async throws -> [Int] {
        if let t = phraseTokens[text] { return t }
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let t = tokenizer.encode(text)
        phraseTokens[text] = t
        return t
    }

    /// Keeps the model's output for the clip it was run on (only the last clip is kept).
    func remember(_ samples: [Float], logProbs: [[Float]], frameDuration: Double) {
        guard frameDuration > 0, !samples.isEmpty else { return }
        let frames = Int((Double(samples.count) / Double(ASRConstants.sampleRate) / frameDuration).rounded(.up))
        lastPass = CtcPass(key: CtcPass.Key(samples), logProbs: Array(logProbs.prefix(frames)))
    }

    /// The model's output for this clip, if the last clip run was this one.
    func recalled(_ samples: [Float]) -> [[Float]]? {
        guard let p = lastPass, p.key == CtcPass.Key(samples) else { return nil }
        return p.logProbs
    }
}

/// Reads text off the CTC model's output by taking the likeliest token at each frame.
enum CtcGreedy {
    /// Repeats collapsed, blanks dropped, SentencePiece word marks (the lower one-eighth
    /// block) turned into spaces. `blankId` is the id one past the vocabulary.
    static func text(logProbs: [[Float]], vocabulary: [Int: String], blankId: Int) -> String {
        var out = ""
        var previous = -1
        for row in logProbs {
            var best = -1
            var top = -Float.infinity
            for (i, v) in row.enumerated() where v > top { top = v; best = i }
            defer { previous = best }
            guard best >= 0, best != previous, best != blankId, let piece = vocabulary[best] else { continue }
            out += piece.replacingOccurrences(of: "\u{2581}", with: " ")
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Stage 3: "Hey Earshot" in the first 1.5 s of a speech segment (the
/// listener spots when the segment reaches 1.5 s, or when it ends sooner).
public actor CtcWakeSpotter: WakeSpotter {
    public static let phrase = "hey earshot"   // Kobi wake: part 2
    /// The phrase without its greeting, scored on the same pass for the wake bench
    /// (wakeScores): a noise gate that cuts the start of a segment can leave only "Earshot".
    /// The listener does not use it (tests/app-e2e.md, the wake section, has the measurement).
    public static let barePhrase = "earshot"   // Kobi wake: part 2
    private let flight = SingleFlight<(spotter: CtcKeywordSpotter, vocab: CustomVocabularyContext, bare: CustomVocabularyContext)> {
        let models = try await CtcShared.shared.models(for: .spotter)
        let tokens = try await CtcShared.shared.tokens(CtcWakeSpotter.phrase)
        let bareTokens = try await CtcShared.shared.tokens(CtcWakeSpotter.barePhrase)
        return (CtcKeywordSpotter(models: models, blankId: models.vocabulary.count),
                CustomVocabularyContext(terms: [CustomVocabularyTerm(text: CtcWakeSpotter.phrase, ctcTokenIds: tokens)]),
                CustomVocabularyContext(terms: [CustomVocabularyTerm(text: CtcWakeSpotter.barePhrase, ctcTokenIds: bareTokens)]))
    }
    private var failures = FailureLog()
    private let log = Logger(subsystem: "com.kobi.app", category: "wake")

    private var generation = 0

    public init() {}

    public func load() async throws {
        let g = generation
        do { _ = try await flight.get() } catch {
            await CtcShared.shared.release(.spotter)
            throw error
        }
        // Unloaded while it loaded: do not keep it.
        if g != generation { await unload() }
    }

    /// Frees the spotter and its hold on the CTC model (the wake word is off or blocked for a while).
    public func unload() async {
        generation += 1
        await flight.clear()
        await CtcShared.shared.release(.spotter)
        log.info("unloaded the wake word model")
    }

    /// The lowest score that fires the spotter. Sensitivity 5 is -8.0; each step moves it
    /// by 0.25, higher waking more easily (-7.0 at 1, -9.25 at 10).
    /// A fire is not a wake yet: Apple's recognizer reads the window's words, and the wake
    /// passes only when they start with the wake phrase (Listener.wakeWords), written as
    /// such or only sounding like it; only a greeting and the phrase written as such ever
    /// send the words after them. So the
    /// threshold can sit low, where the spotter alone would chime about 140 times an hour
    /// of speech. Measured on the wake bench (tests/wake/README.md, kobi-probe
    /// wake-rescore, 19950 synthetic clips over 30 voices and 5 mic conditions, a third of the
    /// voices held out, and 5.4 h of LibriSpeech), at -8.0 with Apple's confirm: positives woken
    /// (tune, holdout) clean 87%, 81%; quiet 50%, 38%; noise gate 0.2 38%, 34%; gate 0.4 4%, 6%;
    /// gate 0.6 0%, 1%. Dispatch false wakes: near-misses 0 of 12900, mentions 0 of 2250.
    /// Window false wakes: near-misses 405 of 12900 (3.1%), mentions 8 of 2250 (0.4 and 0.6 gates).
    /// LibriSpeech: the spotter fires 142.6 times an hour, 0.00 an hour dispatch, 0.00 a window. The confirm
    /// takes 51 ms at the median and 59 ms at the 95th percentile.
    /// The spotter alone at the old -6.0 woke on 73% of clean positives and 17% of quiet
    /// ones, with 505/4800 near-miss false wakes.
    public static func threshold(_ sensitivity: Int) -> Float { -8.0 - 0.25 * Float(min(max(sensitivity, 1), 10) - 5) }

    /// The lowest score that wakes when no recognizer could judge the window (Apple's has
    /// no answer and Parakeet is not loaded, or the confirm ran past its limit). Spotter
    /// alone at -5.0 on the wake bench: clean positives 52%, near-miss false wakes 3%,
    /// LibriSpeech 0 audible an hour. The same at any sensitivity.
    public static let unconfirmedThreshold: Float = -5.0

    /// FluidAudio lowers the score a phrase needs by 1 for each token past 3 ("hey
    /// earshot" has 6), so the threshold is raised by as much to mean what it says.
    /// This is what FluidAudio's own filter is given for a sensitivity: it keeps the
    /// detections whose score reaches `threshold(sensitivity)`.
    static func minScore(_ sensitivity: Int, tokens: Int) -> Float {
        let extra = max(0, tokens - ContextBiasingConstants.baselineTokenCountForThreshold)
        return threshold(sensitivity) + Float(extra) * ContextBiasingConstants.thresholdRelaxationPerToken
    }

    /// Asked for so low that FluidAudio's own filter keeps every detection, so the
    /// best score comes back whatever it is.
    private static let keepAll: Float = -1000

    /// How well the audio says the wake phrase: the best detection's score, in the
    /// space `threshold` is in (a wake is a score at or above it), or nil when the
    /// spotter is not loaded or failed. The score is per token, so it does not depend
    /// on the phrase's length. The model's output is kept in CtcShared for the head
    /// confirmer, which reads the same clip.
    public func wakeScore(_ samples: [Float]) async -> Float? {
        await wakeScores(samples, bare: false)?.phrase
    }

    /// wakeScore, and with `bare` also the score of barePhrase alone, read off the same
    /// pass of the model (no second run). The bare score is -infinity when not asked for.
    public func wakeScores(_ samples: [Float], bare: Bool = true) async -> (phrase: Float, bare: Float)? {
        guard await flight.isLoaded, let (spotter, vocab, bareVocab) = try? await flight.get() else { return nil }
        do {
            let r = try await spotter.spotKeywordsWithLogProbs(audioSamples: CtcShared.fullLength(samples), customVocabulary: vocab,
                                                               minScore: Self.keepAll)
            await CtcShared.shared.remember(samples, logProbs: r.logProbs, frameDuration: r.frameDuration)
            // No detection at all means the clip had fewer frames than the phrase has tokens.
            let phrase = r.detections.map(\.score).max() ?? -.infinity
            guard bare, !r.logProbs.isEmpty else { return (phrase, -.infinity) }
            let b = spotter.spotKeywordsFromLogProbs(logProbs: r.logProbs, frameDuration: r.frameDuration,
                                                     customVocabulary: bareVocab, minScore: Self.keepAll)
            return (phrase, b.detections.map(\.score).max() ?? -.infinity)
        } catch {
            if failures.shouldLog() { log.error("the wake spotter failed: \(error.localizedDescription, privacy: .public)") }
            return nil
        }
    }

    /// The spotter fired: wakeScore against the threshold, with no confirm (for the probe).
    public func heardWake(_ samples: [Float], sensitivity: Int) async -> Bool {
        guard let score = await wakeScore(samples) else { return false }
        return score >= Self.threshold(sensitivity)
    }
}

/// A look at the words of the first moments of a segment by the CTC model that
/// already heard it for the spotter: greedy decoding of its output, no second run.
/// The model is small and was trained to score keywords, so its words are rough.
/// Nil when the model is not loaded (never loads it) or the pass fails.
public struct CtcHeadConfirmer: WakeConfirmer {
    private let shared: CtcShared

    public init() { self.init(shared: .shared) }
    init(shared: CtcShared) { self.shared = shared }

    public func headText(_ head: [Float]) async -> String? {
        guard !head.isEmpty, let models = await shared.loadedModels() else { return nil }
        let logProbs: [[Float]]
        if let kept = await shared.recalled(head) {
            logProbs = kept
        } else {
            // The spotter did not just hear this clip: run the model, with no phrase to look for.
            let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            guard let r = try? await spotter.spotKeywordsWithLogProbs(audioSamples: CtcShared.fullLength(head),
                                                                      customVocabulary: CustomVocabularyContext(terms: [])),
                  r.frameDuration > 0 else { return nil }
            await shared.remember(head, logProbs: r.logProbs, frameDuration: r.frameDuration)
            logProbs = await shared.recalled(head) ?? []
        }
        return CtcGreedy.text(logProbs: logProbs, vocabulary: models.vocabulary, blankId: models.vocabulary.count)
    }
}

/// The head's words from Parakeet, when it is loaded already. Nil when it is not:
/// a confirm never waits for a model to load, and does not load one.
public struct ParakeetHeadConfirmer: WakeConfirmer {
    private let transcriber: ParakeetTranscriber

    public init(_ transcriber: ParakeetTranscriber) { self.transcriber = transcriber }

    public func headText(_ head: [Float]) async -> String? {
        guard !head.isEmpty else { return nil }
        return await transcriber.transcribeIfLoaded(head)
    }
}

/// Stage 4: Parakeet TDT v2 (English) on the whole clip, then the session
/// names boosted. Loaded on first use, unloaded after 10 idle minutes and
/// when macOS is short on memory.
public actor ParakeetTranscriber: Transcriber {
    private let flight: SingleFlight<AsrManager>
    private var asr: AsrManager?
    private var boosting: (names: [String], session: VocabularyBoostingSession)?
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private let idle: Duration
    private let run: @Sendable (AsrManager, [Float]) async throws -> ASRResult
    private let makeBoost: @Sendable ([String]) async throws -> VocabularyBoostingSession
    /// Transcriptions in progress: the model is not unloaded under them.
    private var busy = 0
    /// An unload (the idle timer, memory pressure) came while busy: it is done when the
    /// last transcription in progress ends (see done(reschedule:)).
    private var unloadPending = false
    private let log = Logger(subsystem: "com.kobi.app", category: "transcriber")

    public init() { self.init(idle: .seconds(600), load: ParakeetTranscriber.loadModels, run: ParakeetTranscriber.recognize) }

    init(idle: Duration, load: @escaping @Sendable () async throws -> AsrManager,
         run: @escaping @Sendable (AsrManager, [Float]) async throws -> ASRResult = ParakeetTranscriber.recognize,
         boost: @escaping @Sendable ([String]) async throws -> VocabularyBoostingSession = ParakeetTranscriber.loadBoost) {
        self.idle = idle
        self.run = run
        makeBoost = boost
        flight = SingleFlight(load)
    }

    @Sendable static func recognize(_ asr: AsrManager, _ samples: [Float]) async throws -> ASRResult {
        var decoder = TdtDecoderState.make()
        return try await asr.transcribe(samples, decoderState: &decoder)
    }

    @Sendable static func loadModels() async throws -> AsrManager {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        return m
    }

    public var isLoaded: Bool { asr != nil }
    var loads: Int { get async { await flight.loads } }

    public func prewarm() async {
        idleTask?.cancel()
        guard (try? await loaded()) != nil else { return }
        scheduleUnload()   // a prewarm that no transcribe follows must not keep the model
    }

    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        try await transcribeBoth(samples, vocabulary: vocabulary).text
    }

    /// The words in the clip, with no vocabulary, only when the model is loaded now; nil
    /// when it is not (this never starts a load) or the run failed. It leaves the idle timer
    /// alone, so a wake confirm never keeps the model resident: it unloads when the commands
    /// that loaded it have been idle for the usual time, confirms or not. An unload that
    /// comes during the run is done when it ends.
    public func transcribeIfLoaded(_ clip: [Float]) async -> String? {
        // The check and the start of the run share one stretch of this actor, so an unload
        // can't come between them: the model is marked busy before the first wait.
        guard let asr else { return nil }
        busy += 1
        let text = try? await run(asr, ClipLevel.padded(clip)).text
        await done(reschedule: false)
        return text
    }

    public func transcribeBoth(_ clip: [Float], vocabulary: [String]) async throws -> (text: String, plain: String?) {
        // A short clip ("Yes.") comes back empty unless it is padded out.
        let samples = ClipLevel.padded(clip)
        idleTask?.cancel()
        busy += 1
        do {
            let r = try await transcribeBusy(samples, vocabulary: vocabulary)
            await done(reschedule: true)
            return r
        } catch {
            await done(reschedule: true)
            throw error
        }
    }

    /// One transcription in progress (counted in `busy`), boosted with the vocabulary.
    private func transcribeBusy(_ samples: [Float], vocabulary: [String]) async throws -> (text: String, plain: String?) {
        let asr = try await loaded()
        let result = try await run(asr, samples)
        guard !vocabulary.isEmpty, !result.text.isEmpty, let timings = result.tokenTimings else { return (result.text, nil) }
        // Without the boost (its model is missing or memory is short) the plain words still make the command.
        guard let session = try? await boostingSession(vocabulary) else {
            log.error("the name boost didn't load; using the words as heard")
            return (result.text, nil)
        }
        guard let boosted = await session.rescore(text: result.text, tokenTimings: timings,
                                                  audioSamples: CtcShared.fullLength(samples))?.text,
              boosted != result.text,
              Self.keepsBoost(plain: result.text, boosted: boosted, vocabulary: vocabulary) else { return (result.text, nil) }
        return (boosted, result.text)
    }

    /// The name boost may only swap a few misheard words for a name. Left
    /// alone it rewrote "Hey, how are you doing?" as "Earshot doing?" and
    /// dropped words from plain sentences, so a boost that adds no name, adds
    /// other words, or drops more than two words per name word is ignored.
    static func keepsBoost(plain: String, boosted: String, vocabulary: [String]) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }
        func minus(_ a: [String], _ b: [String]) -> [String] {
            var rest = b, out: [String] = []
            for w in a { if let i = rest.firstIndex(of: w) { rest.remove(at: i) } else { out.append(w) } }
            return out
        }
        let p = words(plain), b = words(boosted)
        let names = Set(vocabulary.flatMap(words))
        let added = minus(b, p), dropped = minus(p, b)
        guard !added.isEmpty, added.allSatisfy(names.contains) else { return false }
        return dropped.count <= max(2, added.count * 2)
    }

    /// A transcription ended. With none left in progress, an unload that came during them is
    /// done now; otherwise, with `reschedule`, the idle timer starts again (a command used the model).
    private func done(reschedule: Bool) async {
        busy -= 1
        if busy == 0, unloadPending {
            await unload()
        } else if reschedule {
            scheduleUnload()
        }
    }

    public func unload() async {
        // The idle timer or memory pressure came during a transcription: done when it ends.
        guard busy == 0 else { unloadPending = true; return }
        unloadPending = false
        idleTask?.cancel()
        idleTask = nil
        boosting = nil
        if let old = asr {
            log.info("unloaded the transcriber")
            asr = nil
            await flight.clear()
            await old.cleanup()   // releases FluidAudio's shared cache too
        }
        // The CTC model is freed unless the wake word spotter holds it, or a command since made a new boost.
        if boosting == nil { await CtcShared.shared.release(.boosting) }
    }

    private func loaded() async throws -> AsrManager {
        let m = try await flight.get()
        if asr == nil {
            asr = m
            watchMemory()
            log.info("loaded the transcriber")
        }
        return m
    }

    private func boostingSession(_ names: [String]) async throws -> VocabularyBoostingSession {
        if let b = boosting, b.names == names { return b.session }
        let s = try await makeBoost(names)
        boosting = (names, s)
        return s
    }

    @Sendable static func loadBoost(_ names: [String]) async throws -> VocabularyBoostingSession {
        let terms = names.map { CustomVocabularyTerm(text: $0) }
        return try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms),
                                                   ctcModels: try await CtcShared.shared.models(for: .boosting))
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idle] in
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func watchMemory() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in Task { await self?.unload() } }
        source.resume()
        pressure = source
    }
}
