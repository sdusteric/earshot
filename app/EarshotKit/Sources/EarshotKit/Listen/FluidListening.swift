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
    private let log = Logger(subsystem: "com.earshot.app", category: "models")

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
    private let log = Logger(subsystem: "com.earshot.app", category: "vad")

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

/// The CTC model is shared: the wake word spotter and the vocabulary boost use it.
actor CtcShared {
    static let shared = CtcShared()
    private let flight = SingleFlight<CtcModels> { try await CtcModels.downloadAndLoad(variant: .ctc110m) }
    private var phraseTokens: [String: [Int]] = [:]

    func models() async throws -> CtcModels { try await flight.get() }

    func tokens(_ text: String) async throws -> [Int] {
        if let t = phraseTokens[text] { return t }
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let t = tokenizer.encode(text)
        phraseTokens[text] = t
        return t
    }
}

/// Stage 3: "Hey Earshot" in the first 2 s of a speech segment.
public actor CtcWakeSpotter: WakeSpotter {
    public static let phrase = "hey earshot"
    private let flight = SingleFlight<(spotter: CtcKeywordSpotter, vocab: CustomVocabularyContext)> {
        let models = try await CtcShared.shared.models()
        let tokens = try await CtcShared.shared.tokens(CtcWakeSpotter.phrase)
        return (CtcKeywordSpotter(models: models, blankId: models.vocabulary.count),
                CustomVocabularyContext(terms: [CustomVocabularyTerm(text: CtcWakeSpotter.phrase, ctcTokenIds: tokens)]))
    }
    private var failures = FailureLog()
    private let log = Logger(subsystem: "com.earshot.app", category: "wake")

    public init() {}

    public func load() async throws { _ = try await flight.get() }

    /// Sensitivity 5 is FluidAudio's default spotter threshold (-15). Each
    /// step moves it by 1: higher wakes more easily.
    public static func threshold(_ sensitivity: Int) -> Float { -10 - Float(min(max(sensitivity, 1), 10)) }

    public func heardWake(_ samples: [Float], sensitivity: Int) async -> Bool {
        guard await flight.isLoaded, let (spotter, vocab) = try? await flight.get() else { return false }
        do {
            // `minScore` is the base threshold: FluidAudio relaxes it for each
            // token a phrase has beyond its baseline, and returns only the
            // detections that pass the relaxed threshold. Any detection is a wake.
            let r = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocab,
                                                               minScore: Self.threshold(sensitivity))
            if !r.detections.isEmpty { log.info("wake") }
            return !r.detections.isEmpty
        } catch {
            if failures.shouldLog() { log.error("the wake spotter failed: \(error.localizedDescription, privacy: .public)") }
            return false
        }
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
    /// Transcriptions in progress: the model is not unloaded under them.
    private var busy = 0
    private let log = Logger(subsystem: "com.earshot.app", category: "transcriber")

    public init() { self.init(idle: .seconds(600), load: ParakeetTranscriber.loadModels, run: ParakeetTranscriber.recognize) }

    init(idle: Duration, load: @escaping @Sendable () async throws -> AsrManager,
         run: @escaping @Sendable (AsrManager, [Float]) async throws -> ASRResult = ParakeetTranscriber.recognize) {
        self.idle = idle
        self.run = run
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

    var isLoaded: Bool { asr != nil }
    var loads: Int { get async { await flight.loads } }

    public func prewarm() async {
        idleTask?.cancel()
        guard (try? await loaded()) != nil else { return }
        scheduleUnload()   // a prewarm that no transcribe follows must not keep the model
    }

    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        idleTask?.cancel()
        busy += 1
        defer { busy -= 1; scheduleUnload() }
        let asr = try await loaded()
        let result = try await run(asr, samples)
        guard !vocabulary.isEmpty, !result.text.isEmpty, let timings = result.tokenTimings else { return result.text }
        let session = try await boostingSession(vocabulary)
        return await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)?.text ?? result.text
    }

    public func unload() async {
        guard busy == 0 else { return }   // the idle timer or memory pressure came during a transcription
        idleTask?.cancel()
        idleTask = nil
        boosting = nil
        guard let old = asr else { return }
        log.info("unloaded the transcriber")
        asr = nil
        await flight.clear()
        await old.cleanup()   // releases FluidAudio's shared cache too
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
        let terms = names.map { CustomVocabularyTerm(text: $0) }
        let s = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms),
                                                    ctcModels: try await CtcShared.shared.models())
        boosting = (names, s)
        return s
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
