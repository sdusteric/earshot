import EarshotKit
import SwiftUI

/// First launch, in the spec's order: what Earshot does, the voice, the
/// mic and the wake word, the hotkey, the speech models, lowering other
/// audio, and a first command.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("onboarded") private var onboarded = false
    @State private var step = 0
    static let last = 6

    private var keyName: String? {
        switch model.config.hotkey {
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .off: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0:
                Text("Earshot reads Claude Code updates aloud, and takes commands by voice").font(.title2.bold())
                Text("It tells you when a session needs your OK, might be stuck, or finishes. Say \u{201C}Hey Earshot\u{201D} or hold a key to send a session a prompt, ask what everyone is doing, stop a session, start one, or answer a permission prompt with yes or no.")
            case 1:
                Text("Voice").font(.title2.bold())
                Text("Earshot uses the voice you set up with the plugin: \(model.config.engine.rawValue). You can change it in Settings.")
                Button("Play a Test Line") { model.playTestLine() }
            case 2:
                Text("Microphone and wake word").font(.title2.bold())
                Text("Earshot hears you on this Mac only. Audio is kept in memory for a few seconds and never saved or sent.")
                if model.micAllowed {
                    Label("The microphone is allowed.", systemImage: "checkmark.circle")
                } else {
                    Button("Allow the Microphone") { Task { await model.requestMic() } }
                }
                Toggle("Listen for \u{201C}Hey Earshot\u{201D} (the mic indicator stays on while it listens)",
                       isOn: Binding(get: { model.config.wakeWord },
                                     set: { on in model.save { $0.set("EARSHOT_WAKE", on ? "on" : "off") } }))
                    .disabled(!model.micAllowed)
            case 3:
                Text("Hold to talk").font(.title2.bold())
                if let key = keyName {
                    Text("Hold \(key), say the command, and let go. A quick tap or \(key) with another key does nothing. macOS asks to allow Input Monitoring so Earshot can see that key.")
                    if model.hotkeyAllowed {
                        Label("The hotkey is allowed.", systemImage: "checkmark.circle")
                    } else {
                        Button("Allow the Hotkey") { model.requestHotkeyAccess() }
                    }
                } else {
                    Text("The hold-to-talk hotkey is off. You can turn it on in Settings, under Listening.")
                }
            case 4:
                Text("Speech models").font(.title2.bold())
                Text("Listening needs about 1 GB of speech models, downloaded once. Earshot keeps speaking while they download.")
                switch model.modelState {
                case .ready: Label("The models are ready.", systemImage: "checkmark.circle")
                case .downloading(let p): ProgressView(value: p) { Text("Downloading") }
                case .missing: Button("Download") { model.downloadModels() }
                case .failed: Button("Try Again") { model.downloadModels() }
                }
            case 5:
                Text("Lower other audio").font(.title2.bold())
                Text("While Earshot talks or listens, it can turn music and videos down to \(Int(model.config.duckLevel * 100))%. macOS will ask for permission to capture system audio. Earshot only plays other apps back quieter; it never records or saves their audio.")
                Toggle("Lower other apps while Earshot talks",
                       isOn: Binding(get: { model.config.duckEnabled },
                                     set: { on in model.save { $0.set("EARSHOT_DUCK", on ? nil : "off") } }))
                Toggle("Open Earshot when you log in",
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            default:
                Text("Try it").font(.title2.bold())
                if model.config.wakeWord {
                    Text("Say: \u{201C}Hey Earshot, what's everyone doing?\u{201D}")
                } else if let key = keyName {
                    Text("Hold \(key) and say: \u{201C}What's everyone doing?\u{201D}")
                } else {
                    Text("Turn on the wake word or the hotkey in Settings, under Listening, to give Earshot a command.")
                }
                if let b = model.listenBlock, model.config.wakeWord { Text(ListenPolicy.menuLine(b)).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step < Self.last ? "Continue" : "Done") {
                    if step < Self.last {
                        if step == 5, model.config.duckEnabled { model.playTestLine() }   // the first tap: macOS asks now
                        step += 1
                    } else {
                        onboarded = true
                        dismissWindow(id: "onboarding")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 320)
        .permissionRefresh(model)
    }
}
