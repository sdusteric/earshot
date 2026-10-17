import AVFoundation
import Foundation
import os
import Speech

/// Apple's on-device SpeechTranscriber (macOS 26), the second hearing. It
/// mishears differently from Parakeet, so a command Parakeet garbles is often
/// whole here. Session names go in as contextual strings. Nothing leaves the Mac.
public actor AppleTranscriber: SecondHearing {
    private let locale = Locale(identifier: "en-US")
    private let log = Logger(subsystem: "com.kobi.app", category: "listen")
    private enum State { case unknown, preparing, ready, unavailable }
    private var state = State.unknown

    public init() {}

    /// The model is installed and the transcriber can run (see prepare).
    public var isReady: Bool { state == .ready }

    public func prepare() async {
        guard state == .unknown else { return }
        state = .preparing
        guard SpeechTranscriber.isAvailable else {
            state = .unavailable
            log.info("second hearing: not available on this Mac")
            return
        }
        do {
            let tr = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) {
                log.info("second hearing: installing Apple's speech model")
                try await req.downloadAndInstall()
            }
            state = .ready
            log.info("second hearing: ready")
        } catch {
            // Tried again on the next prepare (the next time the mic opens).
            state = .unknown
            log.error("second hearing: not ready: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func hear(_ samples: [Float], names: [String]) async -> String? {
        guard state == .ready, !samples.isEmpty else { return nil }
        do {
            let text = try await transcribe(samples, names: names)
            return text.isEmpty ? nil : text
        } catch {
            log.error("second hearing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The clip as text. Throws when the model can't run.
    public func transcribe(_ samples: [Float], names: [String]) async throws -> String {
        let tr = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [tr])
        if !names.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = names
            try await analyzer.setContext(ctx)
        }
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let want = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [tr]) ?? src
        let buffer = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let input = try Self.convert(buffer, to: want)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        cont.yield(AnalyzerInput(buffer: input))
        cont.finish()
        let collect = Task { var s = ""; for try await r in tr.results where r.isFinal { s += String(r.text.characters) }; return s }
        if let last = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func convert(_ b: AVAudioPCMBuffer, to f: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if b.format == f { return b }
        guard let c = AVAudioConverter(from: b.format, to: f) else { throw CocoaError(.featureUnsupported) }
        let cap = AVAudioFrameCount(Double(b.frameLength) * f.sampleRate / b.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: cap) else { throw CocoaError(.featureUnsupported) }
        var fed = false
        var err: NSError?
        c.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return b
        }
        if let err { throw err }
        return out
    }
}

/// The head's words from Apple's SpeechTranscriber, with the wake phrase as context.
/// The context changed none of 2250 heads on the wake bench (Apple writes "Kobe" for
/// most "Kobi"s either way; Listener.nameSpellings takes both). Nil when the transcriber is not ready
/// (not available on this Mac, or its model not installed): a confirm never installs it.
public struct AppleHeadConfirmer: WakeConfirmer {
    private let transcriber: AppleTranscriber

    /// Share the app's transcriber, or make one (then call `prepare` before the first confirm).
    public init(_ transcriber: AppleTranscriber = AppleTranscriber()) { self.transcriber = transcriber }

    public func prepare() async { await transcriber.prepare() }

    public func headText(_ head: [Float]) async -> String? {
        guard !head.isEmpty, await transcriber.isReady else { return nil }
        return try? await transcriber.transcribe(head, names: ["Hey Kobi", "Kobi"])
    }
}
