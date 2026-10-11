import EarshotKit
import SwiftUI

/// First launch: what Earshot does, the voice, and lowering other audio.
/// Listening steps arrive with plan 2.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("onboarded") private var onboarded = false
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0:
                Text("Earshot reads Claude Code updates aloud").font(.title2.bold())
                Text("It tells you when a session needs your OK, might be stuck, or finishes. It stays quiet while you're on a call and tells you what you missed afterwards.")
            case 1:
                Text("Voice").font(.title2.bold())
                Text("Earshot uses the voice you set up with the plugin: \(model.config.engine.rawValue). You can change it in Settings.")
                Button("Play a Test Line") { model.playTestLine() }
            default:
                Text("Lower other audio").font(.title2.bold())
                Text("While Earshot talks, it can turn music and videos down to \(Int(model.config.duckLevel * 100))%. macOS will ask for permission to capture system audio. Earshot only plays other apps back quieter; it never records or saves their audio.")
                Toggle("Lower other apps while Earshot talks",
                       isOn: Binding(get: { model.config.duckEnabled },
                                     set: { on in model.save { $0.set("EARSHOT_DUCK", on ? nil : "off") } }))
                Toggle("Open Earshot when you log in",
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Spacer()
            HStack {
                Spacer()
                Button(step < 2 ? "Continue" : "Done") {
                    if step < 2 {
                        step += 1
                    } else {
                        onboarded = true
                        if model.config.duckEnabled { model.playTestLine() }   // the first tap: macOS asks now
                        dismissWindow(id: "onboarding")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 280)
    }
}
