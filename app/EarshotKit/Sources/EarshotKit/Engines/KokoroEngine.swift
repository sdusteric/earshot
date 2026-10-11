@preconcurrency import FluidAudio
import Foundation
import os

/// Kokoro on this Mac, kept loaded while in use. v3 throws on a few inputs, so
/// those get a second try on the legacy runtime, which loads only then.
/// Unloads after 10 idle minutes and when macOS is short on memory.
public actor KokoroEngine: SpeechEngine {
    public nonisolated let voice: String
    private var v3: KokoroAneManager?
    private var legacy: KokoroAneManager?
    private var legacyFailed = false
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private let log = Logger(subsystem: "com.earshot.app", category: "kokoro")
    static let idle: Duration = .seconds(600)

    public init(voice: String) { self.voice = voice }

    public nonisolated var name: String { "kokoro" }
    public nonisolated var fileExtension: String { "wav" }
    public nonisolated func cacheKey(_ text: String) -> String { "kokoro \(voice) \(text)" }

    /// FluidAudio keeps its models in ~/.cache/fluidaudio/Models.
    public static var modelsPresent: Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/fluidaudio/Models")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.lowercased().contains("kokoro") }
    }

    public func render(_ text: String, to url: URL) async throws {
        let wav: Data
        do {
            wav = try await loaded().synthesize(text: text, voice: voice)
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
            wav = try await legacy.synthesize(text: text, voice: voice)
        }
        try wav.write(to: url, options: .atomic)
        scheduleUnload()
    }

    /// Loads the model and warms it up with a long line, so the first real
    /// line is fast. Safe to call more than once.
    public func prepare() async {
        _ = try? await loaded().synthesize(
            text: "Still on the billing service, about six minutes in. Latest step: run the invoice tests again.", voice: voice)
        scheduleUnload()
    }

    public func unload() {
        if v3 != nil || legacy != nil { log.info("unloaded Kokoro") }
        v3 = nil
        legacy = nil
        legacyFailed = false
        idleTask?.cancel()
        idleTask = nil
    }

    private func loaded() async throws -> KokoroAneManager {
        if let v3 { return v3 }
        let m = KokoroAneManager(version: .v3)
        try await m.initialize(preloadVoices: [voice])
        v3 = m
        watchMemory()
        log.info("loaded Kokoro")
        return m
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: KokoroEngine.idle)
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
