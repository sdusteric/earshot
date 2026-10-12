import EarshotKit
import SwiftUI

extension View {
    /// Re-reads the permissions every 2 s while this view is on screen.
    func permissionRefresh(_ model: AppModel) -> some View { modifier(PermissionRefresh(model: model)) }
}

private struct PermissionRefresh: ViewModifier {
    let model: AppModel
    @State private var timer: Timer?
    func body(content: Content) -> some View {
        content
            .onAppear {
                model.refreshPermissions()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated { model.refreshPermissions() }
                }
            }
            .onDisappear { timer?.invalidate(); timer = nil }
    }
}

/// Four pages, by what you want to change: what Earshot says and when, how
/// it sounds, how you talk to it, and the app itself.
struct SettingsView: View {
    var body: some View {
        TabView {
            SpeakingTab().tabItem { Label("Speaking", systemImage: "text.bubble") }
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }
            ListeningTab().tabItem { Label("Listening", systemImage: "mic") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 500)
    }
}

/// A caption under a setting, in the grouped form's footer style.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

private struct SpeakingTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Updates", selection: Binding(get: { model.config.level },
                                                     set: { v in model.save { $0.set("EARSHOT_LEVEL", v) } })) {
                    Text("Quiet").tag("quiet")
                    Text("Normal").tag("normal")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented)
                Picker("Finished lines sound", selection: Binding(get: { model.config.style },
                                                                  set: { v in model.save { $0.set("EARSHOT_STYLE", v) } })) {
                    Text("Plain").tag("plain")
                    Text("Upbeat").tag("upbeat")
                    Text("Cheeky").tag("cheeky")
                }
            } header: {
                Text("What Earshot says")
            } footer: {
                Footnote(levelLine)
            }

            Section {
                Toggle("Lower other apps while Earshot talks",
                       isOn: Binding(get: { model.config.duckEnabled },
                                     set: { on in model.save { $0.set("EARSHOT_DUCK", on ? nil : "off") } }))
                if model.config.duckEnabled {
                    LabeledContent("Lower them to") {
                        HStack {
                            Slider(value: Binding(get: { Double(model.config.duckLevel * 100) },
                                                  set: { v in model.save { $0.set("EARSHOT_DUCK_LEVEL", String(Int(v))) } }),
                                   in: 10...90, step: 5)
                            Text("\(Int(model.config.duckLevel * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Other apps")
            } footer: {
                Footnote("Music and videos are turned down only while Earshot's voice plays. macOS asks once to let Earshot capture system audio; it plays other apps back quieter and never records them.")
            }

            Section {
                Picker("When an app is full screen", selection: Binding(get: { model.config.fullScreen },
                                                                       set: { v in model.save { $0.set("EARSHOT_FULLSCREEN", v.rawValue) } })) {
                    Text("Stay silent").tag(EarshotConfig.FullScreen.silent)
                    Text("Answer only when I ask").tag(EarshotConfig.FullScreen.answers)
                    Text("Speak as usual").tag(EarshotConfig.FullScreen.speak)
                }
            } header: {
                Text("Interruptions")
            } footer: {
                Footnote(fullScreenLine + " During a call, Earshot also waits, then catches up.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reloadConfig() }
    }

    private var levelLine: String {
        switch model.config.level {
        case "quiet": "Only when a session needs you, might be stuck, hits an error, or finishes."
        case "all": "Everything in Normal, plus \u{201C}On it\u{201D} when a session gets your prompt."
        default: "When a session needs you or finishes, plus a progress update every 3 minutes."
        }
    }

    private var fullScreenLine: String {
        switch model.config.fullScreen {
        case .silent: "In a full screen app, a game, or a slideshow, Earshot says nothing, shows no orb and doesn't listen. Session updates play when you leave full screen."
        case .answers: "In a full screen app, session updates wait until you leave full screen. The hotkey and the wake word still work, and Earshot answers them."
        case .speak: "Full screen apps change nothing."
        }
    }
}

private struct VoiceTab: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""

    /// Kokoro's voices: the first letter is the accent, the second the voice.
    static let kokoroVoices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_adam", "am_michael", "bf_emma", "bm_george"]

    static func name(_ id: String) -> String {
        let n = id.split(separator: "_").last.map(String.init) ?? id
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    static func detail(_ id: String) -> String {
        let accent = id.hasPrefix("b") ? "British" : "American"
        let kind = id.dropFirst().first == "m" ? "male" : "female"
        return "\(accent), \(kind)"
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: Binding(get: { model.config.engine },
                                                    set: { e in model.save { $0.set("EARSHOT_ENGINE", e.rawValue) } })) {
                    Text("Kokoro").tag(EarshotConfig.Engine.kokoro)
                    Text("ElevenLabs").tag(EarshotConfig.Engine.elevenlabs)
                    Text("The Mac's voice").tag(EarshotConfig.Engine.say)
                }
            } footer: {
                Footnote(engineLine)
            }

            switch model.config.engine {
            case .kokoro:
                Section {
                    Picker("Voice", selection: Binding(get: { model.config.kokoroVoice },
                                                       set: { v in
                                                           model.save { $0.set("EARSHOT_KOKORO_VOICE", v) }
                                                           model.playTestLine("Hi, I'm \(Self.name(v)). This is how I'll sound.")
                                                       })) {
                        ForEach(Self.kokoroVoices, id: \.self) { v in
                            HStack {
                                Text(Self.name(v))
                                Spacer()
                                Text(Self.detail(v)).foregroundStyle(.secondary)
                            }
                            .tag(v)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Voice")
                } footer: {
                    Footnote("Choose a voice to hear it.")
                }
            case .elevenlabs:
                Section {
                    SavedField(title: "Voice ID", value: model.config.elevenLabsVoice ?? "") { v in
                        model.save { $0.set("EARSHOT_VOICE", v.isEmpty ? nil : v) }
                    }
                    LabeledContent("API key") {
                        HStack {
                            SecureField(model.config.elevenLabsKey == nil ? "Paste your key" : "Saved. Paste a new one to replace it",
                                        text: $key)
                                .labelsHidden()
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } header: {
                    Text("ElevenLabs")
                } footer: {
                    Footnote(model.config.elevenLabsKey == nil
                             ? "Find both in your ElevenLabs account. Until the key is saved, Earshot uses Kokoro."
                             : "If ElevenLabs fails, Earshot falls back to Kokoro, then to the Mac's voice.")
                }
            case .say:
                Section {
                    SavedField(title: "Voice", value: model.config.sayVoice ?? "") { v in
                        model.save { $0.set("EARSHOT_SAY_VOICE", v.isEmpty ? nil : v) }
                    }
                } footer: {
                    Footnote("Leave it empty for the system voice. Voices come from System Settings, Accessibility, Spoken Content.")
                }
            }

            Section {
                Button("Play a Test Line") { model.playTestLine() }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reloadConfig() }
    }

    private var engineLine: String {
        switch model.config.engine {
        case .kokoro: "Runs on this Mac. Free, and nothing leaves your computer."
        case .elevenlabs: "Cloud voices. Each line's text is sent to ElevenLabs."
        case .say: "The voice built into macOS. Works with nothing to download."
        }
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        model.save { $0.set("EARSHOT_KEY", k) }
        key = ""
    }
}

/// A text setting saved when you press Return or leave the field, not on
/// every keystroke: the plugin reads the config file at every hook, and a
/// half-typed voice name would make its lines fail.
private struct SavedField: View {
    let title: String
    let value: String
    let save: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onDisappear { commit() }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != value { save(trimmed) }
    }
}

private struct ListeningTab: View {
    @Environment(AppModel.self) private var model
    @State private var inputs: [AudioDevices.Device] = []

    var body: some View {
        Form {
            Section {
                Picker("Hold to talk", selection: Binding(get: { model.config.hotkey },
                                                          set: { v in model.save { $0.set("EARSHOT_HOTKEY", v.rawValue) } })) {
                    Text("Right Option").tag(EarshotConfig.Hotkey.rightOption)
                    Text("Right Command").tag(EarshotConfig.Hotkey.rightCommand)
                    Text("Off").tag(EarshotConfig.Hotkey.off)
                }
                if model.config.hotkey != .off, !model.hotkeyAllowed {
                    PermissionRow(title: "Input Monitoring", allowed: false,
                                  why: "So Earshot can see the hotkey. It watches only that key.") { model.requestHotkeyAccess() }
                }
                if model.config.hotkey != .off, model.secureInput {
                    Footnote(ListenPolicy.secureInputLine)
                }
            } header: {
                Text("Hotkey")
            } footer: {
                Footnote("Hold the key, say a command, and let go. A quick tap, or the key with another key, does nothing.")
            }

            Section {
                Toggle("Listen for \u{201C}Hey Earshot\u{201D}",
                       isOn: Binding(get: { model.config.wakeWord },
                                     set: { on in model.save { $0.set("EARSHOT_WAKE", on ? "on" : "off") } }))
                if model.config.wakeWord {
                    Picker("On battery", selection: Binding(get: { model.config.wakeOnBattery },
                                                            set: { v in model.save { $0.set("EARSHOT_WAKE_BATTERY", v.rawValue) } })) {
                        Text("Listen, except in Low Power Mode").tag(EarshotConfig.WakeBattery.lowpower)
                        Text("Always listen").tag(EarshotConfig.WakeBattery.always)
                        Text("Only listen on power").tag(EarshotConfig.WakeBattery.power)
                    }
                    LabeledContent("Sensitivity") {
                        Slider(value: Binding(get: { Double(model.config.wakeSensitivity) },
                                              set: { v in model.save { $0.set("EARSHOT_WAKE_SENSITIVITY", String(Int(v))) } }),
                               in: 1...10, step: 1) {
                            Text("Sensitivity")
                        } minimumValueLabel: { Text("Fewer false starts") } maximumValueLabel: { Text("Fewer misses") }
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Wake word")
            } footer: {
                if model.config.wakeWord, let b = model.listenBlock {
                    Footnote(ListenPolicy.menuLine(b))
                } else if model.config.wakeWord, model.wakeLoadFailed {
                    Footnote("The wake word couldn't start. Earshot retries every minute.")
                } else {
                    Footnote("While it listens for the wake word, the mic indicator stays on.")
                }
            }

            Section {
                Picker("Microphone", selection: Binding(get: { model.config.inputDevice ?? "" },
                                                        set: { v in model.save { $0.set("EARSHOT_INPUT", v.isEmpty ? nil : v) } })) {
                    Text("Automatic").tag("")
                    ForEach(inputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
            } footer: {
                Footnote("Automatic avoids a Bluetooth headset's mic, so the headset keeps its full sound. Audio stays on this Mac: Earshot keeps the last few seconds in memory to hear a command, and never saves or sends it.")
            }

            Section {
                Toggle("Show the orb", isOn: Binding(get: { model.config.showOrb },
                                                     set: { on in model.save { $0.set("EARSHOT_ORB", on ? nil : "off") } }))
                if model.config.showOrb {
                    Picker("Color", selection: Binding(get: { model.config.orbColor },
                                                       set: { v in model.save { $0.set("EARSHOT_ORB_COLOR", v == .state ? nil : v.rawValue) } })) {
                        Text("Changes with what Earshot is doing").tag(EarshotConfig.OrbColor.state)
                        Divider()
                        Text("Blue").tag(EarshotConfig.OrbColor.blue)
                        Text("Purple").tag(EarshotConfig.OrbColor.purple)
                        Text("Orange").tag(EarshotConfig.OrbColor.orange)
                        Text("Green").tag(EarshotConfig.OrbColor.green)
                        Text("Pink").tag(EarshotConfig.OrbColor.pink)
                        Text("White").tag(EarshotConfig.OrbColor.white)
                    }
                    Button("Move the Orb Back to the Top") { OrbPanel.forgetPosition() }
                }
            } header: {
                Text("Orb")
            } footer: {
                Footnote(model.config.orbColor == .state
                         ? "Blue while Earshot listens, violet while it works on a command, amber while it talks. Drag the orb anywhere; double-click it to put it back."
                         : "The orb shows while Earshot listens, works on a command, or talks. Drag it anywhere; double-click it to put it back.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.reloadConfig()
            inputs = AudioDevices.all().filter(\.hasInput)
        }
        .permissionRefresh(model)
    }
}

/// One permission: allowed, or a button that asks for it.
private struct PermissionRow: View {
    let title: String
    let allowed: Bool
    let why: String
    let request: () -> Void

    var body: some View {
        LabeledContent {
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow\u{2026}", action: request)
            }
        } label: {
            Text(title)
            Text(why)
        }
    }
}

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Open Earshot when you log in",
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }

            Section {
                PermissionRow(title: "Microphone", allowed: model.micAllowed,
                              why: "To hear the hotkey, the wake word, and yes or no.") { Task { await model.requestMic() } }
                PermissionRow(title: "Input Monitoring", allowed: model.hotkeyAllowed,
                              why: "To see the hold-to-talk key.") { model.requestHotkeyAccess() }
            } header: {
                Text("Permissions")
            } footer: {
                Footnote("System audio capture, for lowering other apps, is asked for the first time Earshot does it.")
            }

            Section {
                LabeledContent("Speech models") {
                    switch model.modelState {
                    case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    case .downloading(let p): ProgressView(value: p).frame(width: 140)
                    case .missing: Button("Download (about 1 GB)") { model.downloadModels() }
                    case .failed: Button("Try Again") { model.downloadModels() }
                    }
                }
            } footer: {
                Footnote("Listening needs these, downloaded once. Earshot keeps speaking while they download.")
            }

            Section {
                LabeledContent("Version", value: Self.version)
                if model.updater.canCheck { Button("Check for Updates\u{2026}") { model.updater.check() } }
                Button("Show the Welcome Steps") {
                    NSApp.activate()
                    openWindow(id: "onboarding")
                }
                Button("Copy Diagnostics") { model.copyDiagnostics() }
            } footer: {
                Footnote("Diagnostics list settings and recent events, never what you or Earshot said.")
            }
        }
        .formStyle(.grouped)
        .permissionRefresh(model)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
