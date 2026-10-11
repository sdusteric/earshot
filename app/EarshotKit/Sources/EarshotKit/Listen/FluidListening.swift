@preconcurrency import FluidAudio
import Foundation
import os

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

/// Stage 2: Silero VAD, 4096-sample chunks, speech ends after 600 ms of silence.
public actor SileroGate: SpeechGate {
    private var vad: VadManager?
    private var state = VadStreamState.initial()
    private let config = VadSegmentationConfig(minSilenceDuration: 0.6)

    public init() {}

    public func load() async throws {
        guard vad == nil else { return }
        vad = try await VadManager()
    }

    public func reset() async { state = VadStreamState.initial() }

    public func feed(_ chunk: [Float]) async -> SpeechEdge? {
        guard let vad, let r = try? await vad.processStreamingChunk(chunk, state: state, config: config) else { return nil }
        state = r.state
        switch r.event?.kind {
        case .speechStart: return .start
        case .speechEnd: return .end
        default: return nil
        }
    }
}

/// The CTC model is shared: the wake word spotter and the vocabulary boost use it.
actor CtcShared {
    static let shared = CtcShared()
    private var models: CtcModels?
    private var phraseTokens: [String: [Int]] = [:]

    func models() async throws -> CtcModels {
        if let models { return models }
        let m = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        models = m
        return m
    }

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
    private var spotter: CtcKeywordSpotter?
    private var vocab: CustomVocabularyContext?
    private let log = Logger(subsystem: "com.earshot.app", category: "wake")

    public init() {}

    public func load() async throws {
        guard spotter == nil else { return }
        let models = try await CtcShared.shared.models()
        let tokens = try await CtcShared.shared.tokens(Self.phrase)
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        vocab = CustomVocabularyContext(terms: [CustomVocabularyTerm(text: Self.phrase, ctcTokenIds: tokens)])
    }

    /// Sensitivity 5 is FluidAudio's default spotter threshold (-15). Each
    /// step moves it by 1: higher wakes more easily.
    public static func threshold(_ sensitivity: Int) -> Float { -10 - Float(min(max(sensitivity, 1), 10)) }

    public func heardWake(_ samples: [Float], sensitivity: Int) async -> Bool {
        guard let spotter, let vocab else { return false }
        let threshold = Self.threshold(sensitivity)
        guard let r = try? await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocab,
                                                                    minScore: threshold) else { return false }
        let hit = r.detections.contains { $0.score >= threshold }
        if hit { log.info("wake") }
        return hit
    }
}

/// Stage 4: Parakeet TDT v2 (English) on the whole clip, then the session
/// names boosted. Loaded on first use, unloaded after 10 idle minutes and
/// when macOS is short on memory.
public actor ParakeetTranscriber: Transcriber {
    private var asr: AsrManager?
    private var boosting: (names: [String], session: VocabularyBoostingSession)?
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private let log = Logger(subsystem: "com.earshot.app", category: "transcriber")
    static let idle: Duration = .seconds(600)

    public init() {}

    public func prewarm() async { _ = try? await loaded() }

    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        let asr = try await loaded()
        var decoder = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &decoder)
        scheduleUnload()
        guard !vocabulary.isEmpty, !result.text.isEmpty, let timings = result.tokenTimings else { return result.text }
        let session = try await boostingSession(vocabulary)
        return await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)?.text ?? result.text
    }

    public func unload() {
        if asr != nil { log.info("unloaded the transcriber") }
        asr = nil
        boosting = nil
        idleTask?.cancel()
        idleTask = nil
    }

    private func loaded() async throws -> AsrManager {
        if let asr { return asr }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        asr = m
        watchMemory()
        log.info("loaded the transcriber")
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
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: ParakeetTranscriber.idle)
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
