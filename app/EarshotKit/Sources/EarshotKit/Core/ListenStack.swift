import Foundation

/// Every listening part, wired. The app owns one.
public struct ListenStack: Sendable {
    public let listener: Listener
    public let loop: VoiceLoop
    public let directory: SessionDirectory
    public let models: ListenModels
    public let claudePath: String?
    let gate: SileroGate
    let spotter: CtcWakeSpotter

    public static func live(core: EarshotCore, config: @escaping @Sendable () -> EarshotConfig) async -> ListenStack {
        let gate = SileroGate(), spotter = CtcWakeSpotter(), transcriber = ParakeetTranscriber(), chimes = SystemChimes()
        let listener = Listener(input: MicInput(deviceUID: { config().inputDevice }), gate: gate, spotter: spotter,
                                transcriber: transcriber, chimes: chimes)
        let claudePath = await Task.detached { ClaudeCLI.locate() }.value
        let runner = ClaudeCLI(path: claudePath ?? "/nonexistent/claude")
        let directory = SessionDirectory(runner: runner, store: core.sessions, labeler: Labeler(model: FoundationLabelModel()))
        let speech = core.speech
        let dispatcher = Dispatcher(directory: directory, store: core.sessions, transport: CCSocketTransport(), runner: runner,
                                    approvals: core.approvals,
                                    say: { text in await speech.enqueue(SpokenLine(text: text, kind: .confirm, session: "")) })
        let loop = VoiceLoop(followUps: listener, parser: CommandParser(model: FoundationCommandModel()), dispatcher: dispatcher,
                             directory: directory, approvals: core.approvals, speech: speech, chimes: chimes, events: core.events)
        await listener.setObserver(loop)
        await loop.start(utterances: listener.utterances)
        return ListenStack(listener: listener, loop: loop, directory: directory, models: ListenModels(),
                           claudePath: claudePath, gate: gate, spotter: spotter)
    }

    /// The VAD and the spotter, which stay loaded while the wake word may listen.
    public func loadWakeModels() async {
        try? await gate.load()
        try? await spotter.load()
    }
}
