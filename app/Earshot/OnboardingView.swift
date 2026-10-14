import EarshotKit
import SwiftUI

/// First launch, in the spec's order: what Earshot does, the voice, the
/// mic and the wake word, the hotkey, the speech models, lowering other
/// audio, and a first command. Someone who finished an older onboarding
/// sees only the listening steps, once.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("onboardingVersion") private var onboardingVersion = 0
    @State private var plan: [OnboardingStep] = []
    @State private var index = 0

    private var steps: [OnboardingStep] { plan.isEmpty ? OnboardingStep.allCases : plan }
    private var step: OnboardingStep { steps[min(index, steps.count - 1)] }
    private var isLast: Bool { index >= steps.count - 1 }
    private var upgrading: Bool { steps.first == .mic }

    private var keyName: String? {
        switch model.config.hotkey {
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .off: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if upgrading, index == 0 {
                Text("New: Earshot can listen. Set it up in a few steps.").foregroundStyle(.secondary)
            }
            switch step {
            case .intro:
                Text("Earshot reads Claude Code updates aloud, and takes commands by voice").font(.title2.bold())
                Text("It tells you when a session needs your OK, might be stuck, or finishes. Say \u{201C}Hey Earshot\u{201D} or hold a key to send a session a prompt, ask what everyone is doing, stop a session, start one, or answer a permission prompt with yes or no.")
            case .plugin:
                Text("Connect to Claude Code").font(.title2.bold())
                Text("Earshot hears about your sessions through a small Claude Code plugin. It tells Earshot when a session needs you, might be stuck, or finishes, and lets you answer permission prompts by voice.")
                PluginStatusRow()
            case .voice:
                Text("Voice").font(.title2.bold())
                Text("Earshot speaks with \(model.config.engine == .kokoro ? "Kokoro, on this Mac" : model.config.engine == .elevenlabs ? "ElevenLabs" : "the Mac's own voice"). You can change it in Settings.")
                Button("Play a Test Line") { model.playTestLine() }
            case .mic:
                Text("Microphone and wake word").font(.title2.bold())
                Text("Earshot hears you on this Mac only. Audio is kept in memory for a few seconds and never saved or sent.")
                if model.micAllowed {
                    Label("The microphone is allowed.", systemImage: "checkmark.circle")
                } else {
                    if model.micDenied {
                        Text("Earshot isn't allowed to use the mic. Turn it on in System Settings, Privacy & Security, Microphone.")
                            .foregroundStyle(.secondary)
                    }
                    Button(AppModel.permissionAction(denied: model.micDenied, ask: "Allow the Microphone")) {
                        Task { await model.requestMic() }
                    }
                }
                Toggle("Listen for \u{201C}Hey Earshot\u{201D} (the mic indicator stays on while it listens)",
                       isOn: Binding(get: { model.config.wakeWord },
                                     set: { on in model.save { $0.set("EARSHOT_WAKE", on ? "on" : "off") } }))
                    .disabled(!model.micAllowed)
            case .hotkey:
                Text("Hold to talk").font(.title2.bold())
                if let key = keyName {
                    Text("Hold \(key), say the command, and let go. A quick tap or \(key) with another key does nothing. macOS asks to allow Input Monitoring so Earshot can see that key.")
                    if model.hotkeyAllowed {
                        Label("The hotkey is allowed.", systemImage: "checkmark.circle")
                    } else {
                        if model.hotkeyDenied {
                            Text("Earshot isn't allowed to see the key. Turn it on in System Settings, Privacy & Security, Input Monitoring.")
                                .foregroundStyle(.secondary)
                        }
                        Button(AppModel.permissionAction(denied: model.hotkeyDenied, ask: "Allow the Hotkey")) {
                            model.requestHotkeyAccess()
                        }
                    }
                } else {
                    Text("The hold-to-talk hotkey is off. You can turn it on in Settings, under Listening.")
                }
            case .models:
                Text("Speech models").font(.title2.bold())
                Text("Listening needs about 1 GB of speech models, downloaded once. Earshot keeps speaking while they download.")
                switch model.modelState {
                case .ready: Label("The models are ready.", systemImage: "checkmark.circle")
                case .downloading(let p): ProgressView(value: p) { Text("Downloading") }
                case .missing: Button("Download") { model.downloadModels() }
                case .failed: Button("Try Again") { model.downloadModels() }
                }
            case .ducking:
                Text("Lower other audio").font(.title2.bold())
                Text("While Earshot talks or listens, it can turn music and videos down to \(Int(model.config.duckLevel * 100))%. macOS will ask for permission to capture system audio. Earshot only plays other apps back quieter; it never records or saves their audio.")
                Toggle("Lower other apps while Earshot talks",
                       isOn: Binding(get: { model.config.duckEnabled },
                                     set: { on in model.save { $0.set("EARSHOT_DUCK", on ? nil : "off") } }))
                Toggle("Open Earshot when you log in",
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            case .tryIt:
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
                if index > 0 { Button("Back") { index -= 1 } }
                Spacer()
                Button(isLast ? "Done" : "Continue") {
                    if !isLast {
                        if step == .ducking, model.config.duckEnabled { model.playTestLine() }   // the first tap: macOS asks now
                        index += 1
                    } else {
                        onboarded = true
                        onboardingVersion = Onboarding.version
                        dismissWindow(id: "onboarding")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 320)
        .onAppear {
            if plan.isEmpty { plan = Onboarding.steps(onboarded: onboarded, storedVersion: onboardingVersion) }
        }
        .permissionRefresh(model)
        .task { await model.checkPlugin(force: true) }
    }
}
