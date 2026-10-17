import KobiKit
import SwiftUI

/// First launch: what Kobi is, the Claude Code plugin, how it stays quiet
/// when you're busy, what listening needs, a first command, and Activity.
/// Each permission is asked on the step that needs it, with its reason, and
/// the rows are the same ones Settings shows. Someone who finished an older
/// onboarding sees only the listening steps, once.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("onboardingVersion") private var onboardingVersion = 0
    @State private var plan: [OnboardingStep] = []
    @State private var index = 0
    /// When the Try It step appeared: a command heard after this is the try.
    @State private var tryStart = Date.distantFuture
    /// Kobi has talked during these steps, so macOS has asked about system audio already.
    @State private var spoke = false

    private var steps: [OnboardingStep] { plan.isEmpty ? OnboardingStep.allCases : plan }
    private var step: OnboardingStep { steps[min(index, steps.count - 1)] }
    private var isLast: Bool { index >= steps.count - 1 }
    private var upgrading: Bool { steps.first == .listen }
    private var keyName: String? { model.config.hotkey.keyName }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.horizontal, 40)
                .padding(.bottom, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        // The upgrade's "New" line above the title needs the room, or the listening rows scroll.
        .frame(width: 540, height: upgrading ? 600 : 560)
        .onAppear {
            if plan.isEmpty { plan = Onboarding.steps(onboarded: onboarded, storedVersion: onboardingVersion) }
            #if DEBUG
            // For checking the steps during development: launch with -onboarded NO -onboardingStep N.
            if UserDefaults.standard.object(forKey: "onboardingStep") != nil {
                index = min(max(UserDefaults.standard.integer(forKey: "onboardingStep"), 0), steps.count - 1)
            }
            #endif
        }
        .onChange(of: index) {
            if step == .tryIt { tryStart = Date() }
            // Seen to the end: closing the window now counts as done.
            if isLast { finish() }
        }
        .permissionRefresh(model)
        .task { await model.checkPlugin(force: true) }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            orb
            if upgrading, index == 0 {
                Text("New: Kobi can listen. Set it up in a few steps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(lead)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The product's face, on every step, so it answers when Kobi talks or listens.
    /// On Try It a click on it listens for one command, as in Activity.
    private var orb: some View {
        OrbView(size: 76, restingColor: .white, spinsWhenIdle: true)
            .background(Circle().fill(.black))
            .clipShape(.circle)
            .overlay(Circle().stroke(ActivityPalette.tick, lineWidth: 1))
            .contentShape(.circle)
            .onTapGesture { if step == .tryIt { model.tapToTalk() } }
            .help(step == .tryIt ? "Click and say a command" : "")
            .accessibilityAddTraits(step == .tryIt ? .isButton : [])
            .accessibilityHint(step == .tryIt ? "Listens for one command" : "")
            .padding(.bottom, 6)
    }

    private var title: String {
        switch step {
        case .intro: "Kobi Speaks Up When Claude Code Needs You"
        case .plugin: "Connect Claude Code"
        case .quiet: "Quiet When You're Busy"
        case .listen: "Talk Back"
        case .tryIt: "Try It"
        case .activity: "Catch Up in Activity"
        }
    }

    private var lead: String {
        switch step {
        case .intro:
            "It tells you when a session needs your OK, might be stuck, or finishes. Talk back to answer, send a prompt, or ask what everyone is doing."
        case .plugin:
            "Kobi hears your sessions through a small Claude Code plugin. Sessions that are already open pick it up when they restart."
        case .quiet:
            "During calls and in full screen apps, Kobi holds its lines and catches up after. A session that needs you can show a notification meanwhile."
        case .listen:
            if let key = keyName {
                "Hold \(key), say what you want, and let go. Audio stays in memory on this Mac and is never saved or sent."
            } else {
                "Say \u{201C}Hey Kobi\u{201D}, or click the orb in Activity, and say what you want. Audio stays in memory on this Mac for a few seconds and is never saved or sent."
            }
        case .tryIt:
            if let key = keyName {
                "Hold \(key) and ask: \u{201C}What's everyone doing?\u{201D} Then let go."
            } else if model.config.wakeWord {
                "Say: \u{201C}Hey Kobi, what's everyone doing?\u{201D}"
            } else {
                "Click the orb and ask: \u{201C}What's everyone doing?\u{201D}"
            }
        case .activity:
            "Activity shows what's waiting on you, so you can answer it there, and what each session did while you were away."
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .intro: intro
        case .plugin:
            rows {
                Section { PluginStatusRow() }
            }
        case .quiet:
            rows {
                Section {
                    NotificationsPermissionRow()
                    Toggle(isOn: Binding(get: { model.config.duckEnabled },
                                         set: { on in model.save { $0.set("KOBI_DUCK", on ? nil : "off") } })) {
                        Text("Lower other audio while Kobi talks")
                        Text("Music and videos go down to \(Int(model.config.duckLevel * 100))%. macOS asks once to allow system audio recording; Kobi never records them.")
                    }
                    LaunchAtLoginToggle()
                }
            }
        case .listen:
            rows {
                Section {
                    MicPermissionRow()
                    SpeechModelsRow()
                }
                Section {
                    Picker("Hold to talk", selection: Binding(get: { model.config.hotkey },
                                                              set: { v in model.save { $0.set("KOBI_HOTKEY", v.rawValue) } })) {
                        Text("Right Option").tag(KobiConfig.Hotkey.rightOption)
                        Text("Right Command").tag(KobiConfig.Hotkey.rightCommand)
                        Divider()
                        Text("Off").tag(KobiConfig.Hotkey.off)
                    }
                    if model.config.hotkey != .off { HotkeyPermissionRow() }
                    Toggle(isOn: Binding(get: { model.config.wakeWord },
                                         set: { on in model.save { $0.set("KOBI_WAKE", on ? "on" : "off") } })) {
                        Text("Also listen for \u{201C}Hey Kobi\u{201D}")
                        Text("The mic indicator stays on while Kobi listens for it.")
                    }
                    .disabled(!model.micAllowed)
                }
            }
        case .tryIt: tryIt
        case .activity: activity
        }
    }

    /// Setting rows in the grouped style Settings uses, on the window's own background.
    private func rows<S: View>(@ViewBuilder _ sections: () -> S) -> some View {
        Form { sections() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
    }

    private var intro: some View {
        VStack(spacing: 10) {
            Button("Hear an Example") {
                model.playTestLine("Billing service finished: the migration ran and all tests pass.")
                spoke = true
            }
            .controlSize(.large)
            if model.config.duckEnabled {
                Text("The first time Kobi talks, macOS asks to allow system audio recording. Kobi uses it only to turn other audio down.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("Setup takes about a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
        .padding(.top, 18)
    }

    private var tryIt: some View {
        VStack(spacing: 10) {
            tryStatus
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            VStack(spacing: 4) {
                Text("More to try, with a session's name").font(.headline)
                Text("\u{201C}Tell billing to run the tests\u{201D}")
                Text("\u{201C}Stop billing\u{201D}")
                Text("\u{201C}Yes\u{201D}, when a session asks for permission")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            Text(tryFootnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
        }
        .padding(.top, 18)
    }

    /// What happened to the try: listening, working, Kobi's answer, or why it can't hear you yet.
    @ViewBuilder private var tryStatus: some View {
        if let heard = model.history.last(where: { $0.kind == .heard && $0.date >= tryStart }) {
            VStack(spacing: 6) {
                Label("You said \u{201C}\(heard.text)\u{201D}", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                if let reply = heard.reply { Text(reply).foregroundStyle(.secondary) }
            }
        } else if case .capturing = model.listenPhase {
            Text("Listening\u{2026}").font(.headline)
        } else if model.listenPhase == .transcribing || model.thinking {
            Text("Working on it\u{2026}").font(.headline)
        } else if let b = model.commandBlock {
            Text(model.blockLine(b)).foregroundStyle(.secondary)
        } else {
            Text("Kobi answers out loud.").foregroundStyle(.secondary)
        }
    }

    private var tryFootnote: String {
        if keyName != nil, model.config.wakeWord {
            "You can also say \u{201C}Hey Kobi\u{201D} first, or click the orb."
        } else if keyName != nil {
            "You can also click the orb. With no sessions open, Kobi says so."
        } else {
            "Turn on a hotkey in Settings, Listening, to talk without clicking."
        }
    }

    private var activity: some View {
        VStack(spacing: 10) {
            // Centered like the rest of the step: the icon to look for, then where it lives.
            VStack(spacing: 8) {
                Image(nsImage: MenuIcon.image(.idle))
                    .renderingMode(.template)
                    .accessibilityHidden(true)
                Text("Kobi lives in the menu bar. Click its icon for your sessions, recent lines, and mute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
            Spacer()
        }
        .padding(.top, 18)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(index + 1) of \(steps.count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Step \(index + 1) of \(steps.count)")
            Spacer()
            if index > 0 { Button("Back") { index -= 1 } }
            if isLast {
                Button("Open Activity") {
                    finish()
                    dismissWindow(id: "onboarding")
                    model.activityPage = .brief
                    NSApp.activate()
                    openWindow(id: "activity")
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    // macOS asks for system audio recording the first time Kobi talks: now, with the reason on screen.
                    if step == .quiet, model.config.duckEnabled, !spoke { model.playTestLine(); spoke = true }
                    index += 1
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func finish() {
        onboarded = true
        onboardingVersion = Onboarding.version
    }
}
