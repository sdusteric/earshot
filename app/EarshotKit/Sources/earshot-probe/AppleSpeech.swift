import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechTranscriber (macOS 26), for comparing with Parakeet in the bench.
/// Session names go in as contextual strings.
actor AppleSpeech {
    private let locale = Locale(identifier: "en-US")
    private var ready = false

    func transcribe(_ samples: [Float], names: [String]) async throws -> String {
        let tr = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if !ready {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) { try await req.downloadAndInstall() }
            ready = true
        }
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
        let input = try convert(buffer, to: want)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        cont.yield(AnalyzerInput(buffer: input))
        cont.finish()
        let collect = Task { var s = ""; for try await r in tr.results where r.isFinal { s += String(r.text.characters) }; return s }
        if let last = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespaces)
    }

    private func convert(_ b: AVAudioPCMBuffer, to f: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if b.format == f { return b }
        let c = AVAudioConverter(from: b.format, to: f)!
        let cap = AVAudioFrameCount(Double(b.frameLength) * f.sampleRate / b.format.sampleRate) + 64
        let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: cap)!
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
