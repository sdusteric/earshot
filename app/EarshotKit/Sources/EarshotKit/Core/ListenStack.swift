import Foundation
import os

/// Every listening part, wired. The app owns one.
public struct ListenStack: Sendable {
    public let listener: Listener
    public let loop: VoiceLoop
    public let directory: SessionDirectory
    public let models: ListenModels
    /// The `claude` command. The first plugin check looks for it, and later checks
    /// look again until it is found (Claude Code may be installed after launch).
    public let claude: LocatedClaude
    public var claudePath: String? { claude.path }
    let gate: SileroGate
    let spotter: CtcWakeSpotter
    let chimes: SystemChimes

    public static func live(core: EarshotCore, history: HistoryStore? = nil,
                            config: @escaping @Sendable () -> EarshotConfig) async -> ListenStack {
        let gate = SileroGate(), spotter = CtcWakeSpotter(), transcriber = ParakeetTranscriber(), chimes = SystemChimes(output: {
            AudioDevices.chooseOutput(setting: config().outputDevice, devices: AudioDevices.all())
        })
        let listener = Listener(input: MicInput(deviceUID: { config().inputDevice }), gate: gate, spotter: spotter,
                                transcriber: transcriber, chimes: chimes)
        let runner = LocatedClaude()
        let directory = SessionDirectory(runner: runner, store: core.sessions, labeler: Labeler(model: FoundationLabelModel()))
        let speech = core.speech
        let dispatcher = Dispatcher(directory: directory, store: core.sessions, transport: CCSocketTransport(), runner: runner,
                                    approvals: core.approvals,
                                    say: { text in
                                        // Said later, not as a reply (a session didn't pick a prompt up).
                                        await history?.add(HistoryEntry(kind: .said, text: text, lineKind: .confirm))
                                        await speech.enqueue(SpokenLine(text: text, kind: .confirm, session: ""))
                                    })
        let loop = VoiceLoop(followUps: listener, parser: CommandParser(model: FoundationCommandModel()), dispatcher: dispatcher,
                             directory: directory, approvals: core.approvals, speech: speech, chimes: chimes, events: core.events,
                             history: history, canListen: { [availability = core.availability] in availability.canListen })
        await listener.setObserver(loop)
        await loop.start(utterances: listener.utterances)
        return ListenStack(listener: listener, loop: loop, directory: directory, models: ListenModels(),
                           claude: runner, gate: gate, spotter: spotter, chimes: chimes)
    }

    /// The VAD and the spotter, which stay loaded while the wake word may listen.
    /// True when both loaded.
    @discardableResult
    public func loadWakeModels() async -> Bool {
        let log = Logger(subsystem: "com.earshot.app", category: "models")
        var ok = true
        do { try await gate.load() } catch {
            log.error("the VAD didn't load: \(error.localizedDescription, privacy: .public)")
            ok = false
        }
        do { try await spotter.load() } catch {
            log.error("the wake word model didn't load: \(error.localizedDescription, privacy: .public)")
            ok = false
        }
        return ok
    }

    public func play(_ chime: Chime) async { await chimes.play(chime) }

    /// The wake word stayed off or blocked: frees the spotter (and its share of
    /// the CTC model). The VAD stays, for follow-up answers.
    public func unloadWakeModels() async { await spotter.unload() }
}
