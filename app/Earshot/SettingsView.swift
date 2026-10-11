import EarshotKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }
            AudioTab().tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            DiagnosticsTab().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 480)
        .padding()
    }
}

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Toggle("Open Earshot when you log in",
                   isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Picker("How much Earshot says",
                   selection: Binding(get: { model.config.level }, set: { v in model.save { $0.set("EARSHOT_LEVEL", v) } })) {
                Text("Quiet: when it needs you, is stuck, fails or finishes").tag("quiet")
                Text("Normal: also a progress update every 3 minutes").tag("normal")
                Text("All: also \"On it\" when your prompt arrives").tag("all")
            }
            Picker("Tone of the finished line",
                   selection: Binding(get: { model.config.style }, set: { v in model.save { $0.set("EARSHOT_STYLE", v) } })) {
                Text("Plain").tag("plain")
                Text("Upbeat").tag("upbeat")
                Text("Cheeky").tag("cheeky")
            }
        }
        .onAppear { model.reloadConfig() }
    }
}

private struct VoiceTab: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    static let kokoroVoices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_adam", "am_michael", "bf_emma", "bm_george"]

    var body: some View {
        Form {
            Picker("Voice engine", selection: Binding(get: { model.config.engine },
                                                      set: { e in model.save { $0.set("EARSHOT_ENGINE", e.rawValue) } })) {
                Text("Kokoro, on this Mac").tag(EarshotConfig.Engine.kokoro)
                Text("ElevenLabs").tag(EarshotConfig.Engine.elevenlabs)
                Text("The Mac's own voice").tag(EarshotConfig.Engine.say)
            }
            switch model.config.engine {
            case .kokoro:
                Picker("Voice", selection: Binding(get: { model.config.kokoroVoice },
                                                   set: { v in model.save { $0.set("EARSHOT_KOKORO_VOICE", v) } })) {
                    ForEach(Self.kokoroVoices, id: \.self) { Text($0).tag($0) }
                }
            case .elevenlabs:
                TextField("Voice ID", text: Binding(get: { model.config.elevenLabsVoice ?? "" },
                                                    set: { v in model.save { $0.set("EARSHOT_VOICE", v) } }))
                SecureField(model.config.elevenLabsKey == nil ? "API key" : "API key (saved; type to replace)", text: $key)
                    .onSubmit {
                        let k = key
                        model.save { $0.set("EARSHOT_KEY", k) }
                        key = ""
                    }
            case .say:
                TextField("Voice (empty: the system voice)",
                          text: Binding(get: { model.config.sayVoice ?? "" },
                                        set: { v in model.save { $0.set("EARSHOT_SAY_VOICE", v.isEmpty ? nil : v) } }))
            }
            Button("Play a Test Line") { model.playTestLine() }
        }
        .onAppear { model.reloadConfig() }
    }
}

private struct AudioTab: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Toggle("Lower other apps while Earshot talks",
                   isOn: Binding(get: { model.config.duckEnabled },
                                 set: { on in model.save { $0.set("EARSHOT_DUCK", on ? nil : "off") } }))
            Slider(value: Binding(get: { Double(model.config.duckLevel * 100) },
                                  set: { v in model.save { $0.set("EARSHOT_DUCK_LEVEL", String(Int(v))) } }),
                   in: 10...90, step: 5) {
                Text("Other apps stay at \(Int(model.config.duckLevel * 100))%")
            }
            .disabled(!model.config.duckEnabled)
            Text("macOS asks once for permission to capture system audio. Earshot only plays other apps back quieter; it never records or saves their audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.reloadConfig() }
    }
}

private struct DiagnosticsTab: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading) {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            Button("Copy Diagnostics") { model.copyDiagnostics() }
        }
        .task { text = await model.diagnostics() }
    }
}
