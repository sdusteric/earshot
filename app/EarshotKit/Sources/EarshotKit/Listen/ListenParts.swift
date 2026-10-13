/// The mic, as 16 kHz mono samples.
public protocol AudioInput: Sendable {
    /// Opens the mic. Chunks can be any length.
    func start() async throws -> AsyncStream<[Float]>
    /// Closes it and finishes the stream.
    func stop() async
}

public enum SpeechEdge: Sendable, Equatable { case start, end }

/// Stage 2: voice activity detection.
public protocol SpeechGate: Sendable {
    func reset() async
    /// One 4096-sample chunk. `end` comes after about 600 ms of silence.
    func feed(_ chunk: [Float]) async -> SpeechEdge?
}

/// Stage 3: "Hey Earshot" in the first seconds of a speech segment.
public protocol WakeSpotter: Sendable {
    /// sensitivity 1 (fewer false wakes) to 10 (fewer misses).
    func heardWake(_ samples: [Float], sensitivity: Int) async -> Bool
}

/// Stage 4: the command as text.
public protocol Transcriber: Sendable {
    /// The clip as text, with these names boosted. Throws when the model can't run.
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String
    /// The same, plus what was heard without the names boosted when that differs.
    func transcribeBoth(_ samples: [Float], vocabulary: [String]) async throws -> (text: String, plain: String?)
    /// Loads the model, so the next command is not slow.
    func prewarm() async
}

extension Transcriber {
    public func transcribeBoth(_ samples: [Float], vocabulary: [String]) async throws -> (text: String, plain: String?) {
        (try await transcribe(samples, vocabulary: vocabulary), nil)
    }
}

public enum Chime: Sendable, Equatable { case listening, closed, confirm }

public protocol Chimes: Sendable {
    func play(_ chime: Chime) async
}

/// Told when Earshot starts and stops hearing a command, so the speaker can
/// stop talking and lower other audio meanwhile.
public protocol ListenObserver: Sendable {
    func captureBegan(_ trigger: Listener.Trigger) async
    /// heard: an utterance follows on `utterances`, so keep other audio low
    /// until its answer has been said.
    func captureEnded(heard: Bool) async
}
