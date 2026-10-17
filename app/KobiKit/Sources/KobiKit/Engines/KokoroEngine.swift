@preconcurrency import FluidAudio
import Foundation
import os

/// One Kokoro voice. Every voice shares one loaded model (`KokoroModel`): a
/// voice is only a small pack, loaded on first use, so a preview in another
/// voice doesn't throw the model away.
public struct KokoroEngine: SpeechEngine {
    public let voice: String
    let model: KokoroModel

    public init(voice: String, model: KokoroModel = KokoroModel()) {
        self.voice = voice
        self.model = model
    }

    public var name: String { "kokoro" }
    public var fileExtension: String { "wav" }
    public func cacheKey(_ text: String) -> String { "kokoro \(voice) \(text)" }

    /// FluidAudio keeps its models in ~/.cache/fluidaudio/Models.
    public static var modelsPresent: Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/fluidaudio/Models")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.lowercased().contains("kokoro") }
    }

    public func render(_ text: String, to url: URL) async throws {
        try await model.synthesize(text, voice: voice).write(to: url, options: .atomic)
    }

    /// Loads the model and warms it up with a long line, so the first real
    /// line is fast. Safe to call more than once.
    public func prepare() async { await model.prepare(voice: voice) }

    public func unload() async { await model.unload() }

    /// How many times the model was loaded, for tests.
    var loads: Int { get async { await model.loads } }
}

/// Kokoro on this Mac, kept loaded while in use. v3 throws on a few inputs, so
/// those get a second try on the legacy runtime, which loads only then.
/// Unloads after 10 idle minutes, unless a session is working (`keepLoaded`),
/// and whenever macOS is short on memory.
public actor KokoroModel {
    private var v3: KokoroAneManager?
    private var loading: Task<KokoroAneManager, Error>?
    private var legacy: KokoroAneManager?
    private var legacyFailed = false
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var held = false
    private let log = Logger(subsystem: "com.kobi.app", category: "kokoro")
    static let idle: Duration = .seconds(600)

    public init() {}

    func synthesize(_ text: String, voice: String) async throws -> Data {
        defer { scheduleUnload() }
        do {
            return try await loaded(voice: voice).synthesize(text: text, voice: voice)
        } catch {
            guard !legacyFailed else { throw error }
            if legacy == nil {
                do {
                    let m = KokoroAneManager(version: .legacy)
                    try await m.initialize(preloadVoices: [voice])
                    legacy = m
                } catch {
                    legacyFailed = true
                    throw error
                }
            }
            guard let legacy else { throw error }
            return try await legacy.synthesize(text: text, voice: voice)
        }
    }

    func prepare(voice: String) async {
        _ = try? await loaded(voice: voice).synthesize(
            text: "Still on the billing service, about six minutes in. Latest step: run the invoice tests again.", voice: voice)
        scheduleUnload()
    }

    /// While a session is working, its next line is coming: the model is loaded
    /// now and stays loaded, so the line after a long turn doesn't wait for a cold
    /// load. Memory pressure still unloads it. Off, the idle countdown starts.
    public func keepLoaded(_ on: Bool, voice: String) async {
        guard on != held else { return }
        held = on
        if on {
            idleTask?.cancel()
            idleTask = nil
            _ = try? await loaded(voice: voice)
        } else {
            scheduleUnload()
        }
    }

    public func unload() {
        if v3 != nil || legacy != nil { log.info("unloaded Kokoro") }
        v3 = nil
        legacy = nil
        legacyFailed = false
        idleTask?.cancel()
        idleTask = nil
    }

    /// How many times the model was loaded, for tests.
    private(set) var loads = 0

    /// The model, loading it once: callers that arrive during a load wait for
    /// that load instead of starting another (the launch warm-up and the first
    /// line often overlap).
    private func loaded(voice: String) async throws -> KokoroAneManager {
        if let v3 { return v3 }
        if let loading { return try await loading.value }
        let task = Task<KokoroAneManager, Error> {
            let m = KokoroAneManager(version: .v3)
            try await m.initialize(preloadVoices: [voice])
            return m
        }
        loading = task
        loads += 1
        defer { loading = nil }
        let m = try await task.value
        v3 = m
        watchMemory()
        log.info("loaded Kokoro")
        return m
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = nil
        guard !held else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: KokoroModel.idle)
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
