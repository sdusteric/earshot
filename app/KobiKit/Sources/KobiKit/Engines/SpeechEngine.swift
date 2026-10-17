import CryptoKit
import Foundation
import os

public protocol SpeechEngine: Sendable {
    var name: String { get }
    var fileExtension: String { get }
    /// The text speak.sh hashes for its cache file name, so both share a cache.
    func cacheKey(_ text: String) -> String
    func render(_ text: String, to url: URL) async throws
}

extension URL {
    /// speak.sh's CACHE: $(getconf DARWIN_USER_CACHE_DIR)kobi
    public static var kobiCache: URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        let base = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appending(path: "kobi")
    }
}

/// Tries each engine in turn; the first that makes the line wins. Made lines
/// are cached, so a repeated line costs nothing.
public struct EngineChain: Synthesizer {
    public let engines: [any SpeechEngine]
    let cacheDir: URL
    private let log = Logger(subsystem: "com.kobi.app", category: "engines")

    public init(engines: [any SpeechEngine], cacheDir: URL = .kobiCache) {
        self.engines = engines
        self.cacheDir = cacheDir
    }

    /// The configured engine first, then the ones that need no setup.
    /// ElevenLabs without a key or voice is skipped. Kokoro joins as a fallback
    /// only when its models are already on this Mac, so a fallback never downloads.
    public static func make(config: KobiConfig, kokoro: KokoroEngine?,
                            kokoroReady: Bool = KokoroEngine.modelsPresent) -> EngineChain {
        var list: [any SpeechEngine] = []
        switch config.engine {
        case .elevenlabs:
            if let key = config.elevenLabsKey, let voice = config.elevenLabsVoice {
                list.append(ElevenLabsEngine(key: key, voice: voice, model: config.elevenLabsModel))
            }
            if let kokoro, kokoroReady { list.append(kokoro) }
        case .kokoro:
            if let kokoro { list.append(kokoro) }
        case .say:
            break
        }
        list.append(SayEngine(voice: config.sayVoice))
        return EngineChain(engines: list)
    }

    static func cacheName(key: String, ext: String) -> String {
        Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + "." + ext
    }

    public func audio(for line: SpokenLine) async -> URL? {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        for engine in engines {
            let file = cacheDir.appending(path: Self.cacheName(key: engine.cacheKey(line.text), ext: engine.fileExtension))
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 0 {
                return file
            }
            // A unique file per attempt, so two lines never write the same file.
            let tmp = cacheDir.appending(path: "dl-\(UUID().uuidString).\(engine.fileExtension)")
            do {
                try await engine.render(line.text, to: tmp)
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: tmp, to: file)
                return file
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                log.error("\(engine.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
}
