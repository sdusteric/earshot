@preconcurrency import FluidAudio
import Foundation
import Testing
@testable import EarshotKit

@Suite struct FluidListeningTests {
    @Test func sensitivityMapsAroundTheDefaultThreshold() {
        #expect(CtcWakeSpotter.threshold(5) == -15)
        #expect(CtcWakeSpotter.threshold(1) == -11)    // stricter
        #expect(CtcWakeSpotter.threshold(10) == -20)   // looser
        #expect(CtcWakeSpotter.threshold(99) == -20)
    }

    static var modelsOn: Bool { ProcessInfo.processInfo.environment["EARSHOT_TEST_MODELS"] == "1" }

    /// 16 kHz mono samples of the Mac's voice saying it.
    func spoken(_ text: String) throws -> [Float] {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ek-say-\(UUID().uuidString.prefix(6)).aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, text]
        try p.run()
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }
        return try AudioConverter().resampleAudioFile(url)
    }

    @Test(.enabled(if: modelsOn)) func modelsArePresent() {
        #expect(ListenModelFiles.present)
    }

    @Test(.enabled(if: modelsOn)) func transcribesACommand() async throws {
        let t = ParakeetTranscriber()
        let text = try await t.transcribe(try spoken("Hey Earshot, what's everyone doing?"), vocabulary: [])
        #expect(text.lowercased().contains("everyone"))
    }

    @Test(.enabled(if: modelsOn)) func vocabularyHelpsASessionName() async throws {
        let t = ParakeetTranscriber()
        let text = try await t.transcribe(try spoken("Tell finebrief to run the tests."), vocabulary: ["finebrief", "billing service"])
        #expect(text.lowercased().contains("finebrief"))
    }

    @Test(.enabled(if: modelsOn)) func spotsTheWakePhraseOnly() async throws {
        let s = CtcWakeSpotter()
        try await s.load()
        #expect(await s.heardWake(try spoken("Hey Earshot, what's everyone doing?"), sensitivity: 5))
        #expect(!(await s.heardWake(try spoken("Good morning everyone, the build passed."), sensitivity: 5)))
    }

    @Test(.enabled(if: modelsOn)) func theGateFindsSpeechAndItsEnd() async throws {
        let g = SileroGate()
        try await g.load()
        let audio = [Float](repeating: 0, count: 8192) + (try spoken("Run the tests.")) + [Float](repeating: 0, count: 32_768)
        var chunker = Chunker()
        var edges: [SpeechEdge] = []
        for c in chunker.push(audio) { if let e = await g.feed(c) { edges.append(e) } }
        #expect(edges == [.start, .end])
    }
}
