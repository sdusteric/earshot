import Foundation
import Testing
@testable import EarshotKit

actor Counter { var n = 0; func bump() { n += 1 } }

struct FakeEngine: SpeechEngine {
    let name: String
    var fails = false
    let calls = Counter()
    var fileExtension: String { "wav" }
    func cacheKey(_ text: String) -> String { "\(name) \(text)" }
    func render(_ text: String, to url: URL) async throws {
        await calls.bump()
        if fails { throw URLError(.badServerResponse) }
        try Data("\(name):\(text)".utf8).write(to: url)
    }
}

@Suite struct EngineTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "ek-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func line(_ t: String) -> SpokenLine { SpokenLine(text: t, kind: .done, session: "s") }

    @Test func usesTheFirstEngineThatWorks() async throws {
        let a = FakeEngine(name: "a", fails: true), b = FakeEngine(name: "b")
        let url = try #require(await EngineChain(engines: [a, b], cacheDir: tempDir()).audio(for: line("hi")))
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "b:hi")
    }

    @Test func cachedLinesAreNotMadeAgain() async {
        let a = FakeEngine(name: "a")
        let chain = EngineChain(engines: [a], cacheDir: tempDir())
        _ = await chain.audio(for: line("hi"))
        _ = await chain.audio(for: line("hi"))
        #expect(await a.calls.n == 1)
    }

    @Test func allFailingGivesNil() async {
        let chain = EngineChain(engines: [FakeEngine(name: "a", fails: true)], cacheDir: tempDir())
        #expect(await chain.audio(for: line("hi")) == nil)
    }

    @Test func cacheNamesMatchSpeakSh() throws {
        // speak.sh: md5 of "kokoro $KOKORO_VOICE $line" plus .wav
        let k = EngineChain.cacheName(key: "kokoro af_heart Fixed it.", ext: "wav")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "printf %s 'kokoro af_heart Fixed it.' | md5 -q"]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let md5 = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(k == "\(md5).wav")
    }

    @Test func chainOrderFollowsTheEngine() {
        func names(_ text: String) -> [String] {
            EngineChain.make(config: EarshotConfig(text: text), kokoro: KokoroEngine(voice: "af_heart"), kokoroReady: true)
                .engines.map { $0.name }
        }
        #expect(names("EARSHOT_ENGINE=elevenlabs\nEARSHOT_KEY=k\nEARSHOT_VOICE=v") == ["elevenlabs", "kokoro", "say"])
        #expect(names("") == ["kokoro", "say"])
        #expect(names("EARSHOT_ENGINE=say") == ["say"])
        #expect(names("EARSHOT_ENGINE=elevenlabs") == ["kokoro", "say"])   // no key: skip ElevenLabs
    }

    /// Loads the real Kokoro model (about 2 s), so it runs only with EARSHOT_TEST_KOKORO=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_KOKORO"] == "1"))
    func kokoroRendersAWav() async throws {
        let url = tempDir().appending(path: "k.wav")
        let engine = KokoroEngine(voice: "af_heart")
        try await engine.render("Fixed the rounding bug.", to: url)
        let data = try Data(contentsOf: url)
        #expect(data.count > 10_000)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        await engine.unload()
    }

    /// The launch warm-up and the first line can ask for Kokoro at the same
    /// time; it loads once. Real model, so EARSHOT_TEST_KOKORO=1 only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_KOKORO"] == "1"))
    func kokoroLoadsOnceWhenAskedTwiceAtOnce() async throws {
        let engine = KokoroEngine(voice: "af_heart")
        let url = tempDir().appending(path: "k2.wav")
        async let warm: Void = engine.prepare()
        async let line: Void = engine.render("First line.", to: url)
        _ = try await (warm, line)
        #expect(await engine.loads == 1)
        await engine.unload()
    }

    @Test func sayRendersAFile() async throws {
        let url = tempDir().appending(path: "t.aiff")
        try await SayEngine(voice: nil).render("Test.", to: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 1000)
    }

    /// A voice preview is said, and cached, in the voice it is for, not the one picked since.
    @Test func aPreviewKeepsItsOwnVoice() {
        let c = EarshotConfig(text: "EARSHOT_KOKORO_VOICE=af_nicole\n")
        let preview = SpokenLine(text: "Hi, I'm Bella. This is how I'll sound.", kind: .roll, session: "", voice: "af_bella")
        #expect(LiveSynth.kokoroVoice(for: preview, config: c) == "af_bella")
        #expect(LiveSynth.kokoroVoice(for: SpokenLine(text: "Hi.", kind: .roll, session: ""), config: c) == "af_nicole")
        #expect(KokoroEngine(voice: "af_bella").cacheKey(preview.text) != KokoroEngine(voice: "af_nicole").cacheKey(preview.text))
    }
}
