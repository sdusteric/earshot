@preconcurrency import FluidAudio
import Foundation
import Testing
@testable import KobiKit

// Kobi wake: part 2 (the spoken wake phrase and the session named earshot)

@Suite struct FluidListeningTests {
    @Test func sensitivityMapsAroundTheDefaultThreshold() {
        #expect(CtcWakeSpotter.threshold(5) == -8)
        #expect(CtcWakeSpotter.threshold(1) == -7)     // stricter
        #expect(CtcWakeSpotter.threshold(10) == -9.25) // looser
        #expect(CtcWakeSpotter.threshold(99) == -9.25)
        #expect(CtcWakeSpotter.threshold(-3) == -7)
        // A wake no recognizer judged needs more than any sensitivity's threshold.
        #expect(CtcWakeSpotter.unconfirmedThreshold == -5)
        #expect((1...10).allSatisfy { CtcWakeSpotter.threshold($0) < CtcWakeSpotter.unconfirmedThreshold })
        // FluidAudio relaxes by 1 per token past 3; that is taken back.
        #expect(CtcWakeSpotter.minScore(5, tokens: 6) == -5)
        #expect(CtcWakeSpotter.minScore(5, tokens: 2) == -8)
        // The model gets a clip padded with zeros to its full 15 s.
        #expect(CtcShared.fullLength([1, 2]).count == 240_000)
        #expect(CtcShared.fullLength([1, 2]).suffix(3) == [0, 0, 0])
        #expect(CtcShared.fullLength([Float](repeating: 1, count: 250_000)).count == 250_000)
    }

    static var modelsOn: Bool { ProcessInfo.processInfo.environment["KOBI_TEST_MODELS"] == "1" }

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

    /// FluidAudio issue #991: the model read a buffer it never cleared, its output stopped
    /// depending on the audio, and every sentence scored the same. This would have failed then.
    @Test(.enabled(if: modelsOn)) func wakeScoresFollowTheAudio() async throws {
        let s = CtcWakeSpotter()
        try await s.load()
        let wake = try #require(await s.wakeScore(try spoken("Hey Earshot, what's everyone doing?")))
        let plain = [
            "Good morning everyone, the build passed.",
            "Please send the report to the whole team.",
            "Hey there, nice shot.",
        ]
        var scores: [Float] = []
        for text in plain { scores.append(try #require(await s.wakeScore(try spoken(text)))) }
        #expect(Set(scores).count == scores.count)   // different sentences, different scores
        #expect(scores.allSatisfy { $0.isFinite })
        #expect(scores.allSatisfy { wake > $0 })
        // Silence says nothing, and scores below the phrase too.
        let silence = try #require(await s.wakeScore([Float](repeating: 0, count: 32_000)))
        #expect(wake > silence)
        // The same audio scores the same.
        #expect(await s.wakeScore(try spoken("Good morning everyone, the build passed.")) == scores[0])
    }

    /// heardWake is wakeScore against the threshold, and agrees with FluidAudio's own filter
    /// given `minScore`: the relaxation per token is taken back in the threshold, not in the score.
    @Test(.enabled(if: modelsOn)) func heardWakeIsTheScoreAgainstTheThreshold() async throws {
        let s = CtcWakeSpotter()
        try await s.load()
        let models = try #require(await CtcShared.shared.loadedModels())
        let tokens = try await CtcShared.shared.tokens(CtcWakeSpotter.phrase)
        let vocab = CustomVocabularyContext(terms: [CustomVocabularyTerm(text: CtcWakeSpotter.phrase, ctcTokenIds: tokens)])
        let fluid = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        for text in ["Hey Earshot, what's everyone doing?", "Hey there, nice shot.", "Run the tests."] {
            let audio = try spoken(text)
            let score = try #require(await s.wakeScore(audio))
            for sensitivity in [1, 5, 10] {
                let theirs = try await fluid.spotKeywordsWithLogProbs(
                    audioSamples: CtcShared.fullLength(audio), customVocabulary: vocab,
                    minScore: CtcWakeSpotter.minScore(sensitivity, tokens: tokens.count))
                #expect(await s.heardWake(audio, sensitivity: sensitivity) == (score >= CtcWakeSpotter.threshold(sensitivity)))
                #expect(!theirs.detections.isEmpty == (score >= CtcWakeSpotter.threshold(sensitivity)), "\(text) at \(sensitivity)")
            }
        }
    }

    @Test(.enabled(if: modelsOn)) func theCtcHeadConfirmerReusesTheSpottersPass() async throws {
        let s = CtcWakeSpotter()
        try await s.load()
        let audio = try spoken("Hey Earshot, what's everyone doing?")
        _ = await s.wakeScore(audio)
        #expect(await CtcShared.shared.recalled(audio) != nil)
        let confirmer = CtcHeadConfirmer()
        let text = try #require(await confirmer.headText(audio))
        // Another clip is run fresh; asking again for the first gives the same words as the kept pass did.
        let other = try #require(await confirmer.headText(try spoken("Good morning everyone.")))
        #expect(await confirmer.headText(audio) == text)
        #expect(other != text)
    }

    @Test func greedyDecodingCollapsesRepeatsAndDropsBlanks() {
        let vocab = [0: "\u{2581}hey", 1: "\u{2581}ear", 2: "shot"]
        let blank = 3
        func frame(_ id: Int) -> [Float] { (0...3).map { $0 == id ? 0 : -9 } }
        let frames = [0, 0, blank, 1, 1, blank, 2, 2, blank, 2].map(frame)
        // A piece with no word mark joins the one before; the blank between the two "shot"s makes them two pieces.
        #expect(CtcGreedy.text(logProbs: frames, vocabulary: vocab, blankId: blank) == "hey earshotshot")
        #expect(CtcGreedy.text(logProbs: [], vocabulary: vocab, blankId: blank) == "")
        #expect(CtcGreedy.text(logProbs: [frame(blank), frame(blank)], vocabulary: vocab, blankId: blank) == "")
    }

    @Test func theLastPassIsFoundByItsSamplesAndTrimmedToTheirFrames() async {
        let shared = CtcShared()
        let a = (0..<32_000).map { Float($0 % 97) / 97 }
        var b = a
        b[16_000] += 0.5
        let frames = [[Float]](repeating: [0, 1], count: 188)
        await shared.remember(a, logProbs: frames, frameDuration: 0.08)
        #expect(await shared.recalled(a)?.count == 25)   // 2 s at 80 ms a frame
        #expect(await shared.recalled(b) == nil)
        #expect(await shared.recalled(Array(a.dropLast())) == nil)
        await shared.remember(b, logProbs: frames, frameDuration: 0.08)
        #expect(await shared.recalled(a) == nil)   // only the last clip is kept
    }

    @Test func confirmersThatAreNotReadyAnswerNilAndLoadNothing() async {
        let head = (0..<32_000).map { Float($0 % 53) / 53 }
        #expect(await CtcHeadConfirmer(shared: CtcShared()).headText(head) == nil)
        let parakeet = ParakeetTranscriber(idle: .seconds(60)) { AsrManager(config: .default) }
        #expect(await ParakeetHeadConfirmer(parakeet).headText(head) == nil)
        #expect(await parakeet.loads == 0)
        #expect(await AppleHeadConfirmer(AppleTranscriber()).headText(head) == nil)
    }

    @Test func parakeetHeadWordsComeFromTheLoadedModelWithNoVocabulary() async throws {
        let seen = Collected<Int>()
        let t = ParakeetTranscriber(idle: .seconds(60), load: { AsrManager(config: .default) }, run: { _, s in
            await seen.add(s.count)
            return ASRResult(text: "hey earshot what is up", confidence: 1, duration: 1, processingTime: 0.1)
        })
        let confirmer = ParakeetHeadConfirmer(t)
        #expect(await confirmer.headText([0.1, 0.1]) == nil)   // not loaded: nil, and still not loaded
        #expect(await t.loads == 0)
        await t.prewarm()
        #expect(await confirmer.headText([Float](repeating: 0.1, count: 32_000)) == "hey earshot what is up")
        #expect(await seen.items == [40_000])
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

    /// Parakeet returns nothing for a clip much under 2 s ("Yes." alone), so short clips are padded.
    @Test func aShortClipIsPaddedOut() async throws {
        let lengths = Collected<Int>()
        let t = ParakeetTranscriber(idle: .seconds(60), load: { AsrManager(config: .default) }, run: { _, s in
            await lengths.add(s.count)
            return ASRResult(text: "yes", confidence: 1, duration: 1, processingTime: 0.1)
        })
        _ = try await t.transcribe([Float](repeating: 0.1, count: 16_000), vocabulary: [])
        _ = try await t.transcribe([Float](repeating: 0.1, count: 64_000), vocabulary: [])
        #expect(await lengths.items == [40_000, 64_000])
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
        #expect(text == "run the tests")   // the model stayed under the transcription
        await unloads.value
        #expect(!(await t.isLoaded))   // and the unload was done as it ended
    }

    /// The idle timer firing during a wake confirm's run is not lost: the model is unloaded
    /// when the run ends, and no later command is needed to unload it.
    @Test func anIdleUnloadDuringAConfirmIsDoneWhenItEnds() async throws {
        let t = ParakeetTranscriber(idle: .milliseconds(40), load: { AsrManager(config: .default) }, run: { _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return ASRResult(text: "hey earshot", confidence: 1, duration: 1, processingTime: 0.1)
        })
        await t.prewarm()   // starts the idle timer, which fires during the run below
        #expect(await t.isLoaded)
        #expect(await t.transcribeIfLoaded([Float](repeating: 0.1, count: 32_000)) == "hey earshot")
        #expect(!(await t.isLoaded))
    }

    /// With one run still going, an unload waits for the last one.
    @Test func aPendingUnloadWaitsForTheLastRun() async throws {
        let t = ParakeetTranscriber(idle: .seconds(60), load: { AsrManager(config: .default) }, run: { _, s in
            try await Task.sleep(for: .milliseconds(s.count > 40_000 ? 300 : 100))
            return ASRResult(text: "hey earshot", confidence: 1, duration: 1, processingTime: 0.1)
        })
        await t.prewarm()
        async let long = t.transcribeIfLoaded([Float](repeating: 0.1, count: 64_000))
        async let short = t.transcribeIfLoaded([Float](repeating: 0.1, count: 16_000))
        try await Task.sleep(for: .milliseconds(30))
        await t.unload()   // as memory pressure would, with both running
        _ = await short
        #expect(await t.isLoaded)   // the long run still holds it
        _ = await long
        #expect(!(await t.isLoaded))
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

@Suite struct BoostFailureTests {
    struct NoBoost: Error {}

    /// The plain transcript was fine: a boost that can't load must not lose the command.
    @Test func aBoostThatFailsToLoadGivesThePlainWords() async throws {
        let timing = TokenTiming(token: "run", tokenId: 1, startTime: 0, endTime: 0.2, confidence: 1)
        let t = ParakeetTranscriber(idle: .seconds(60), load: { AsrManager(config: .default) }, run: { _, _ in
            ASRResult(text: "run the tests", confidence: 1, duration: 1, processingTime: 0.1, tokenTimings: [timing])
        }, boost: { _ in throw NoBoost() })
        let r = try await t.transcribeBoth([0, 0, 0], vocabulary: ["billing service"])
        #expect(r.text == "run the tests")
        #expect(r.plain == nil)
    }
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
