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
                model.refreshNotifications()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated { model.refreshPermissions() }
                }
            }
            .onDisappear { timer?.invalidate(); timer = nil }
            // Notifications change in System Settings; read them again on the way back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshNotifications()
            }
    }
}

/// Four pages, by what you want to change, most often first: what Earshot
/// says and when, how it sounds, how you talk to it, and the app itself.
struct SettingsView: View {
    var body: some View {
        TabView {
            SpeakingTab().tabItem { Label("Speaking", systemImage: "text.bubble") }
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }
            ListeningTab().tabItem { Label("Listening", systemImage: "mic") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 540, height: 520)
    }
}

/// A caption under a section, in the grouped form's footer style.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Speaking

private struct SpeakingTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Session updates", selection: Binding(get: { model.config.level },
                                                             set: { v in model.save { $0.set("EARSHOT_LEVEL", v) } })) {
                    Text("Quiet").tag("quiet")
                    Text("Normal").tag("normal")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented)
                Picker(selection: Binding(get: { model.config.style },
                                          set: { v in model.save { $0.set("EARSHOT_STYLE", v) } })) {
                    Text("Plain").tag("plain")
                    Text("Upbeat").tag("upbeat")
                    Text("Cheeky").tag("cheeky")
                } label: {
                    Text("Tone when a session finishes")
                    Text("How Earshot words what a session got done.")
                }
            } header: {
                Text("What Earshot Says")
            } footer: {
                Footnote(levelLine)
            }

            Section {
                Picker("In a full screen app", selection: Binding(get: { model.config.fullScreen },
                                                                  set: { v in model.save { $0.set("EARSHOT_FULLSCREEN", v.rawValue) } })) {
                    Text("Stay silent").tag(EarshotConfig.FullScreen.silent)
                    Text("Answer only when I ask").tag(EarshotConfig.FullScreen.answers)
                    Text("Speak as usual").tag(EarshotConfig.FullScreen.speak)
                }
                Toggle(isOn: Binding(get: { model.config.banner },
                                     set: { on in model.save { $0.set("EARSHOT_BANNER", on ? nil : "off") } })) {
                    Text("Show a notification when Earshot can't speak")
                    Text("While it's muted, in a call, or quiet for a full screen app, a session that needs you shows a notification. Click it to open Activity.")
                }
                if model.config.banner, model.notificationsChecked, !model.notificationsAllowed {
                    NotificationsPermissionRow()
                }
            } header: {
                Text("Calls and Full Screen")
            } footer: {
                Footnote(fullScreenLine + " During a call, Earshot waits, then catches up.")
            }

            Section {
                Toggle("Say a recap when you come back",
                       isOn: Binding(get: { model.config.recap },
                                     set: { on in model.save { $0.set("EARSHOT_RECAP", on ? nil : "off") } }))
            } header: {
                Text("Coming Back")
            } footer: {
                Footnote("After the Mac was locked or asleep for 10 minutes or more, Earshot says in one line which sessions finished, need you, or ran into trouble. Lines it sums up aren't said again.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reloadConfig() }
        .permissionRefresh(model)
    }

    private var levelLine: String {
        switch model.config.level {
        case "quiet": "Quiet: only when a session needs you, might be stuck, hits an error, or finishes."
        case "all": "All: everything in Normal, plus \u{201C}On it\u{201D} when a session gets your prompt."
        default: "Normal: when a session needs you or finishes, plus a progress update every 3 minutes."
        }
    }

    private var fullScreenLine: String {
        switch model.config.fullScreen {
        case .silent: "In a full screen app, a game, or a slideshow, Earshot says nothing, shows no orb, and doesn't listen. Updates play when you leave full screen."
        case .answers: "In a full screen app, updates wait until you leave full screen. The hotkey and the wake word still work, and Earshot answers them."
        case .speak: "Full screen apps change nothing."
        }
    }
}

// MARK: - Voice

private struct VoiceTab: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var outputs: [AudioDevices.Device] = []
    @State private var systemOutputName = "System output"
    @State private var macVoices: [MacVoices.Voice] = []

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
                Picker("Voice engine", selection: Binding(get: { model.config.engine },
                                                          set: { e in model.save { $0.set("EARSHOT_ENGINE", e.rawValue) } })) {
                    Text("Kokoro").tag(EarshotConfig.Engine.kokoro)
                    Text("ElevenLabs").tag(EarshotConfig.Engine.elevenlabs)
                    Text("macOS").tag(EarshotConfig.Engine.say)
                }
            } footer: {
                Footnote(engineLine)
            }

            switch model.config.engine {
            case .kokoro: kokoroSection
            case .elevenlabs: elevenLabsSection
            case .say: macVoiceSection
            }

            Section {
                Picker("Speaker", selection: Binding(get: { model.config.outputDevice ?? "" },
                                                     set: { v in model.save { $0.set("EARSHOT_OUTPUT", v.isEmpty ? nil : v) } })) {
                    Text(systemOutputName).tag("")
                    if let chosen = model.config.outputDevice, !outputs.contains(where: { $0.uid == chosen }) {
                        Text("Not connected").tag(chosen)
                    }
                    Divider()
                    ForEach(outputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                Toggle(isOn: Binding(get: { model.config.duckEnabled },
                                     set: { on in model.save { $0.set("EARSHOT_DUCK", on ? nil : "off") } })) {
                    Text("Lower other audio while Earshot talks or listens")
                    Text("macOS asks once to allow system audio recording. Earshot only plays other apps back quieter and never records them.")
                }
                if model.config.duckEnabled {
                    LabeledContent("Lower it to") {
                        HStack {
                            Slider(value: Binding(get: { Double(model.config.duckLevel * 100) },
                                                  set: { v in model.save { $0.set("EARSHOT_DUCK_LEVEL", String(Int(v))) } }),
                                   in: 10...90, step: 5)
                                .accessibilityLabel("Lower other audio to")
                                .accessibilityValue("\(Int(model.config.duckLevel * 100)) percent")
                            Text("\(Int(model.config.duckLevel * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Button("Play a Test Line") { model.playTestLine() }
            } header: {
                Text("Sound")
            } footer: {
                Footnote("Earshot's voice and chimes play on this speaker. While it isn't connected, they play through the system output.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.reloadConfig()
            refreshDevices()
        }
        .task(id: model.config.engine) {
            if model.config.engine == .say, macVoices.isEmpty { macVoices = await MacVoices.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshDevices() }
    }

    private var kokoroSection: some View {
        Section {
            Picker("Voice", selection: Binding(get: { model.config.kokoroVoice },
                                               set: { v in
                                                   model.save { $0.set("EARSHOT_KOKORO_VOICE", v) }
                                                   model.playTestLine("Hi, I'm \(Self.name(v)). This is how I'll sound.", voice: v)
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
            Text("Kokoro Voice")
        } footer: {
            Footnote("Choose a voice to hear it.")
        }
    }

    private var elevenLabsSection: some View {
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
                     ? "Find both in your ElevenLabs account. Until a key is saved, Earshot uses Kokoro."
                     : "The key is saved. If ElevenLabs fails, Earshot falls back to Kokoro, then to the macOS voice.")
        }
    }

    @ViewBuilder private var macVoiceSection: some View {
        let chosen = model.config.sayVoice ?? ""
        Section {
            if macVoices.isEmpty {
                // The list couldn't be read: type the name instead.
                SavedField(title: "Voice", value: chosen) { v in
                    model.save { $0.set("EARSHOT_SAY_VOICE", v.isEmpty ? nil : v) }
                }
            } else {
                Picker("Voice", selection: Binding(get: { chosen },
                                                   set: { v in
                                                       model.save { $0.set("EARSHOT_SAY_VOICE", v.isEmpty ? nil : v) }
                                                       model.playTestLine()
                                                   })) {
                    Text("System voice").tag("")
                    if !chosen.isEmpty, !macVoices.contains(where: { $0.name == chosen }) {
                        Text(chosen).tag(chosen)
                    }
                    Divider()
                    ForEach(macVoices) { v in Text("\(v.name) (\(v.language))").tag(v.name) }
                }
            }
        } header: {
            Text("macOS Voice")
        } footer: {
            Footnote("The system voice is the one chosen in System Settings, Accessibility, Spoken Content. Add more voices there.")
        }
    }

    private func refreshDevices() {
        outputs = AudioDevices.all().filter(\.hasOutput)
        systemOutputName = AudioDevices.systemDefault(input: false).map { "System output (\($0.name))" } ?? "System output"
    }

    private var engineLine: String {
        switch model.config.engine {
        case .kokoro: "Runs on this Mac. Free, and nothing leaves your computer."
        case .elevenlabs: "Voices from ElevenLabs, online. The text of each line is sent to ElevenLabs."
        case .say: "The voice built into macOS. Nothing to download."
        }
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        model.save { $0.set("EARSHOT_KEY", k) }
        key = ""
    }
}

/// The English voices `say` knows, read from `say -v ?`.
private enum MacVoices {
    struct Voice: Identifiable, Hashable {
        let name: String
        /// "English (United Kingdom)".
        let language: String
        var id: String { name }
    }

    static func load() async -> [Voice] {
        let output = await Task.detached { () -> String in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "?"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        var seen = Set<String>()
        // "Eddy (English (UK)) en_GB    # Hello! My name is Eddy."
        let line = /^(.+?)\s+([a-z]{2,3}_[A-Za-z0-9]+)\s+#/
        return output.split(separator: "\n").compactMap { row -> Voice? in
            guard let m = try? line.firstMatch(in: String(row)) else { return nil }
            let name = String(m.1), code = String(m.2)
            guard code.hasPrefix("en_"), seen.insert(name).inserted else { return nil }
            return Voice(name: name, language: Locale.current.localizedString(forIdentifier: code) ?? code)
        }
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

// MARK: - Listening

private struct ListeningTab: View {
    @Environment(AppModel.self) private var model
    @State private var inputs: [AudioDevices.Device] = []

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: Binding(get: { model.config.hotkey },
                                                    set: { v in model.save { $0.set("EARSHOT_HOTKEY", v.rawValue) } })) {
                    Text("Right Option").tag(EarshotConfig.Hotkey.rightOption)
                    Text("Right Command").tag(EarshotConfig.Hotkey.rightCommand)
                    Divider()
                    Text("Off").tag(EarshotConfig.Hotkey.off)
                }
                if model.config.hotkey != .off, !model.hotkeyAllowed {
                    HotkeyPermissionRow()
                }
                if model.config.hotkey != .off, model.secureInput {
                    Footnote(ListenPolicy.secureInputLine)
                }
            } header: {
                Text("Hold to Talk")
            } footer: {
                if let key = model.config.hotkey.keyName {
                    Footnote("Hold \(key), say a command, and let go. For example: \u{201C}What's everyone doing?\u{201D}, \u{201C}Tell billing to run the tests\u{201D}, or \u{201C}Yes\u{201D} to a permission prompt. A quick tap, or \(key) with another key, does nothing.")
                } else {
                    Footnote("With the hotkey off, talk to Earshot with the wake word or by clicking the orb in Activity.")
                }
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
                        Text("Listen only when plugged in").tag(EarshotConfig.WakeBattery.power)
                    }
                    LabeledContent("Sensitivity") {
                        Slider(value: Binding(get: { Double(model.config.wakeSensitivity) },
                                              set: { v in model.save { $0.set("EARSHOT_WAKE_SENSITIVITY", String(Int(v))) } }),
                               in: 1...10, step: 1) {
                            Text("Sensitivity")
                        } minimumValueLabel: { Text("Fewer false starts") } maximumValueLabel: { Text("Fewer misses") }
                            .labelsHidden()
                            .font(.callout)
                    }
                }
            } header: {
                Text("Wake Word")
            } footer: {
                if model.config.wakeWord, let b = model.listenBlock {
                    Footnote(model.blockLine(b))
                } else if model.config.wakeWord, model.wakeLoadFailed {
                    Footnote("The wake word couldn't start. Earshot tries again every minute.")
                } else {
                    Footnote("Say \u{201C}Hey Earshot\u{201D}, then the command. The mic indicator stays on while Earshot listens for it.")
                }
            }

            Section {
                if !model.micAllowed {
                    MicPermissionRow()
                }
                Picker("Microphone", selection: Binding(get: { model.config.inputDevice ?? "" },
                                                        set: { v in model.save { $0.set("EARSHOT_INPUT", v.isEmpty ? nil : v) } })) {
                    Text("Automatic").tag("")
                    if let chosen = model.config.inputDevice, !inputs.contains(where: { $0.uid == chosen }) {
                        Text("Not connected").tag(chosen)
                    }
                    Divider()
                    ForEach(inputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
            } header: {
                Text("Input")
            } footer: {
                Footnote("Automatic uses the input chosen in System Settings, Sound, except a MacBook's own mic while the lid is closed. A Bluetooth headset drops to call quality while its mic is in use; choose another mic to avoid that. Audio stays in memory on this Mac and is never saved or sent. What you say is kept as text in the history.")
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
                         ? "The orb floats on screen while Earshot listens (blue), works on a command (violet), or talks (amber). Drag it anywhere; double-click it to put it back."
                         : "The orb floats on screen while Earshot listens, works on a command, or talks. Drag it anywhere; double-click it to put it back.")
            }

            Section {
                SpeechModelsRow()
            } footer: {
                Footnote("Listening needs these, downloaded once. Earshot keeps speaking while they download.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.reloadConfig()
            inputs = AudioDevices.all().filter(\.hasInput)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputs = AudioDevices.all().filter(\.hasInput)
        }
        .permissionRefresh(model)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmClear = false
    @State private var confirmOff = false
    @State private var copied = false

    private var historyLine: String {
        switch model.config.history {
        case .day: "What Earshot said and what you said to it, as text, in a file on this Mac that only your account can read. Audio is never kept."
        case .session: "Kept in memory and gone when Earshot quits. Audio is never kept."
        case .off: "Earshot keeps nothing. The menu bar panel and Activity show no history."
        }
    }

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
            }

            Section {
                PluginStatusRow()
            } header: {
                Text("Claude Code")
            } footer: {
                Footnote("The plugin tells Earshot when a session needs you, might be stuck, or finishes, and lets you answer permission prompts by voice. Without it, voice commands still work, but Earshot says nothing about your sessions. Open sessions pick it up when they restart.")
            }
            .task { await model.checkPlugin() }

            Section {
                MicPermissionRow()
                HotkeyPermissionRow()
                NotificationsPermissionRow()
            } header: {
                Text("Permissions")
            } footer: {
                Footnote("System audio recording, for lowering other audio, is asked for the first time Earshot does it.")
            }

            Section {
                Picker("Keep history", selection: Binding(get: { model.config.history }, set: setHistory)) {
                    Text("For 24 hours").tag(HistoryStore.Keep.day)
                    Text("Until Earshot quits").tag(HistoryStore.Keep.session)
                    Divider()
                    Text("Off").tag(HistoryStore.Keep.off)
                }
                Button("Clear History\u{2026}") { confirmClear = true }
                    .disabled(model.history.isEmpty)
            } header: {
                Text("History")
            } footer: {
                Footnote(historyLine)
            }
            .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { model.clearHistory() }
            } message: {
                Text("Everything Earshot said and heard is removed from this Mac.")
            }
            .confirmationDialog("Turn history off?", isPresented: $confirmOff) {
                Button("Turn Off and Clear", role: .destructive) { saveHistory(.off) }
            } message: {
                Text("Everything Earshot said and heard is removed from this Mac, and nothing new is kept.")
            }

            Section {
                LabeledContent("Version", value: Self.version)
                if model.updater.canCheck { Button("Check for Updates\u{2026}") { model.updater.check() } }
                Button("Show the Welcome Steps") {
                    NSApp.activate()
                    openWindow(id: "onboarding")
                }
                Button(copied ? "Copied" : "Copy Diagnostics") {
                    model.copyDiagnostics()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            } footer: {
                Footnote("Diagnostics list settings and recent events, never what you or Earshot said.")
            }
        }
        .formStyle(.grouped)
        .permissionRefresh(model)
    }

    /// Turning history off deletes what is kept, so it asks first when there is something.
    private func setHistory(_ v: HistoryStore.Keep) {
        if v == .off, model.config.history != .off, !model.history.isEmpty {
            confirmOff = true
        } else {
            saveHistory(v)
        }
    }

    private func saveHistory(_ v: HistoryStore.Keep) {
        model.save { $0.set("EARSHOT_HISTORY", v == .day ? nil : v.rawValue) }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - Shared with the welcome steps

extension EarshotConfig.Hotkey {
    /// The key's name in a sentence, or nil when the hotkey is off.
    var keyName: String? {
        switch self {
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .off: nil
        }
    }
}

extension AppModel {
    /// Asked and allowed; false until the first read.
    var notificationsAllowed: Bool { notificationsChecked && !notificationsDenied && !notificationsUndecided }
}

/// One permission: allowed, or a button that asks for it. Once refused, macOS
/// won't ask again, so the line says where to turn it on and the button opens System Settings.
struct PermissionRow: View {
    let title: String
    let allowed: Bool
    /// Asked before and refused.
    let denied: Bool
    /// Why Earshot needs it.
    let why: String
    /// Where to turn it on after a refusal.
    let fix: String
    var checking = false
    let request: () -> Void

    var body: some View {
        LabeledContent {
            if checking {
                ProgressView().controlSize(.small)
            } else if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            } else {
                Button(AppModel.permissionAction(denied: denied), action: request)
            }
        } label: {
            Text(title)
            Text(denied && !allowed ? fix : why)
        }
    }
}

struct MicPermissionRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        PermissionRow(title: "Microphone", allowed: model.micAllowed, denied: model.micDenied,
                      why: "To hear what you say after the hotkey or \u{201C}Hey Earshot\u{201D}.",
                      fix: "Turned off. Turn on Earshot in System Settings, Privacy & Security, Microphone.") {
            Task { await model.requestMic() }
        }
    }
}

struct HotkeyPermissionRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        PermissionRow(title: "Input Monitoring", allowed: model.hotkeyAllowed, denied: model.hotkeyDenied,
                      why: "To notice when you hold the hotkey. Earshot watches only that key.",
                      fix: "Turned off. Turn on Earshot in System Settings, Privacy & Security, Input Monitoring.") {
            model.requestHotkeyAccess()
        }
    }
}

struct NotificationsPermissionRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        PermissionRow(title: "Notifications", allowed: model.notificationsAllowed, denied: model.notificationsDenied,
                      why: "To show a session that needs you while Earshot can't speak.",
                      fix: "Turned off. Turn on Earshot in System Settings, Notifications.",
                      checking: !model.notificationsChecked) {
            model.allowNotifications()
        }
    }
}

/// The speech models listening needs: ready, downloading, or a button to get them.
struct SpeechModelsRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        LabeledContent {
            switch model.modelState {
            case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            case .downloading(let p):
                HStack(spacing: 8) {
                    ProgressView(value: p).frame(width: 120)
                    Text(model.modelState.percent ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
            case .missing:
                Button(ListenModelFiles.partial ? "Finish Download" : "Download") { model.downloadModels() }
            case .failed: Button("Try Again") { model.downloadModels() }
            }
        } label: {
            Text("Speech models")
            Text(modelLine)
        }
    }

    private var modelLine: String {
        switch model.modelState {
        case .ready: "On this Mac. Speech is turned into text here."
        case .downloading: "Downloading. Earshot keeps speaking meanwhile."
        case .missing: ListenModelFiles.partial ? "The download didn't finish." : "About 1 GB, downloaded once."
        case .failed: "The download failed. Check the connection and try again."
        }
    }
}

/// Open at login, with what macOS still needs when it holds the login item for your OK.
/// Used in Settings and the welcome steps.
struct LaunchAtLoginToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Toggle("Open Earshot when you log in",
               isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        if model.launchAtLoginNeedsApproval {
            LabeledContent {
                Button("Open System Settings") { model.openLoginItems() }
            } label: {
                Text("Waiting for your OK")
                Text("Allow Earshot in System Settings, General, Login Items.")
            }
        } else if let error = model.launchAtLoginError {
            Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The plugin's state, with the button that fixes it. Used in Settings and the welcome steps.
struct PluginStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent {
            if model.pluginWorking {
                ProgressView().controlSize(.small)
            } else if model.pluginStatus.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else if let action = model.pluginStatus.action {
                Button(action) { model.fixPlugin() }
            }
        } label: {
            Text("Earshot plugin")
            Text(line)
        }
    }

    private var line: String {
        if model.pluginWorking { return model.pluginWorkLine }
        // "Connected" already shows at the right.
        if case .connected(let v) = model.pluginStatus { return "Version \(v), in Claude Code." }
        return model.pluginStatus.line
    }
}
