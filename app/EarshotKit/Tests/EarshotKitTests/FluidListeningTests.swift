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

    // MARK: - Loading (no models needed)

    struct LoadFailed: Error {}

    @Test func concurrentCallersShareOneLoad() async throws {
        let flight = SingleFlight<Int> { try await Task.sleep(for: .milliseconds(50)); return 7 }
        async let a = flight.get(), b = flight.get(), c = flight.get()
        #expect(try await [a, b, c] == [7, 7, 7])
        #expect(await flight.loads == 1)
        _ = try await flight.get()
        #expect(await flight.loads == 1)
    }

    @Test func aFailedLoadIsTriedAgain() async throws {
        let n = LoadCounter()
        let flight = SingleFlight<Int> { if await n.next() == 1 { throw LoadFailed() }; return 1 }
        await #expect(throws: LoadFailed.self) { try await flight.get() }
        #expect(try await flight.get() == 1)
        #expect(await flight.loads == 2)
    }

    /// The CTC model is kept while the spotter or the boost holds it, and freed when neither does.
    @Test func aSharedModelIsFreedWhenTheLastHolderLetsGo() async throws {
        let shared = SharedLoad<Int> { 7 }
        #expect(try await shared.acquire("spotter") == 7)
        #expect(try await shared.acquire("boosting") == 7)
        #expect(await shared.loads == 1)
        await shared.release("spotter")
        #expect(await shared.isLoaded)   // the boost still holds it
        await shared.release("spotter")  // twice is once
        #expect(await shared.isLoaded)
        await shared.release("boosting")
        #expect(!(await shared.isLoaded))
        _ = try await shared.acquire("boosting")
        #expect(await shared.loads == 2)
    }

    @Test func aSharedModelReleasedDuringItsLoadIsNotKept() async throws {
        let shared = SharedLoad<Int> { try await Task.sleep(for: .milliseconds(50)); return 7 }
        async let got = shared.acquire("spotter")
        try await Task.sleep(for: .milliseconds(10))
        await shared.release("spotter")
        #expect(try await got == 7)
        #expect(!(await shared.isLoaded))
    }

    @Test func aFailedSharedLoadHoldsNothing() async throws {
        let n = LoadCounter()
        let shared = SharedLoad<Int> { if await n.next() == 1 { throw LoadFailed() }; return 1 }
        await #expect(throws: LoadFailed.self) { try await shared.acquire("spotter") }
        _ = try await shared.acquire("boosting")
        await shared.release("boosting")
        #expect(!(await shared.isLoaded))   // the failed spotter left no hold behind
    }

    @Test func prewarmAndTranscribeLoadTheTranscriberOnce() async throws {
        let t = ParakeetTranscriber(idle: .seconds(60)) {
            try await Task.sleep(for: .milliseconds(50))
            return AsrManager(config: .default)
        }
        async let p: Void = t.prewarm()
        async let x = t.transcribe([0, 0, 0], vocabulary: [])   // the manager has no models, so this throws
        await p
        _ = try? await x
        #expect(await t.loads == 1)
    }

    @Test func aPrewarmThatNothingFollowsUnloadsAfterTheIdleTime() async {
        let t = ParakeetTranscriber(idle: .milliseconds(80)) { AsrManager(config: .default) }
        await t.prewarm()
        #expect(await t.isLoaded)
        #expect(await eventually { !(await t.isLoaded) })
    }

    @Test func aThrowingTranscribeDoesNotKeepTheModel() async {
        let t = ParakeetTranscriber(idle: .milliseconds(80)) { AsrManager(config: .default) }
        _ = try? await t.transcribe([0, 0, 0], vocabulary: [])
        #expect(await eventually { !(await t.isLoaded) })
    }

    @Test func anUnloadDuringATranscriptionWaitsForIt() async throws {
        let t = ParakeetTranscriber(idle: .milliseconds(30), load: { AsrManager(config: .default) }, run: { _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return ASRResult(text: "run the tests", confidence: 1, duration: 1, processingTime: 0.1)
        })
        let unloads = Task {
            try? await Task.sleep(for: .milliseconds(60))
            await t.unload()   // as the idle timer or memory pressure would
        }
        let text = try await t.transcribe([0, 0, 0], vocabulary: [])
        #expect(text == "run the tests")
        #expect(await t.isLoaded)   // still there right after: the unload was skipped
        await unloads.value
        #expect(await eventually { !(await t.isLoaded) })   // and the idle timer unloads it after
    }

    @Test func theGateLoadsItselfOnTheFirstChunkAndDoesNotRetryAtOnce() async {
        let n = LoadCounter()
        let g = SileroGate(retryAfter: .seconds(60)) { _ = await n.next(); throw LoadFailed() }
        for _ in 0..<5 { #expect(await g.feed([Float](repeating: 0, count: 4096)) == nil) }
        #expect(await n.value == 1)   // loaded on the first chunk, not again for 60 s
    }

    @Test func theGateRetriesAfterTheWait() async {
        let n = LoadCounter()
        let g = SileroGate(retryAfter: .milliseconds(30)) { _ = await n.next(); throw LoadFailed() }
        _ = await g.feed([0])
        try? await Task.sleep(for: .milliseconds(60))
        _ = await g.feed([0])
        #expect(await n.value == 2)
    }

    @Test func failuresAreLoggedOnceAMinute() {
        var f = FailureLog()
        let t0 = ContinuousClock.now
        let first = f.shouldLog(now: t0)
        let soon = f.shouldLog(now: t0 + .seconds(30))
        let later = f.shouldLog(now: t0 + .seconds(61))
        #expect(first && !soon && later)
    }
}

actor LoadCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

@Suite struct NameBoostTests {
    let names = ["earshot", "your home folder", "finebrief", "reflow", "release 1012"]

    @Test func aBoostThatSwallowsASentenceIsIgnored() {
        #expect(!ParakeetTranscriber.keepsBoost(plain: "Hey, how are you doing?", boosted: "Earshot doing?", vocabulary: names))
    }

    @Test func aBoostThatOnlyDropsWordsIsIgnored() {
        #expect(!ParakeetTranscriber.keepsBoost(plain: "Tell your home folder I'm here", boosted: "Tell your home folder here",
                                               vocabulary: names))
    }

    @Test func aBoostThatFixesAMisheardNameIsKept() {
        #expect(ParakeetTranscriber.keepsBoost(plain: "Tell fine brief to run the tests", boosted: "Tell finebrief to run the tests",
                                              vocabulary: names))
        #expect(ParakeetTranscriber.keepsBoost(plain: "how's release ten twelve", boosted: "how's release 1012", vocabulary: names))
        #expect(ParakeetTranscriber.keepsBoost(plain: "in re flow, run lint", boosted: "in reflow, run lint", vocabulary: names))
    }

    @Test func aBoostThatAddsOtherWordsIsIgnored() {
        #expect(!ParakeetTranscriber.keepsBoost(plain: "stop it", boosted: "stop earshot now", vocabulary: names))
    }
}
