import EarshotKit
import SwiftUI

/// What the Activity window shows: the brief, the day's history, or one session.
enum ActivityPage: Hashable {
    case brief, history
    case session(String)
}

/// The panel under the menu bar icon, on the same dark ground as Activity:
/// what waits on you first, with its answer right there, then the sessions,
/// the last few things said, and quick controls.
struct StatusPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var headerHeight: CGFloat = 60
    @State private var footerHeight: CGFloat = 44
    @State private var contentHeight: CGFloat = 400

    /// The visible height of the screen the panel opens on.
    private var screenHeight: Double { Double(NSScreen.main?.visibleFrame.height ?? 900) }

    private var scrollHeight: CGFloat {
        CGFloat(PanelLayout.scrollHeight(content: Double(contentHeight),
                                         fixed: Double(headerHeight + footerHeight) + 1,
                                         screen: screenHeight))
    }

    var body: some View {
        // The plugin's sessions, plus the ones only `claude agents` lists (all of them without the plugin).
        let ranked = SessionInfo.panelList(known: model.sessions, live: model.liveSessions)
        let layout = PanelLayout(ranked: ranked, approvals: model.approvals,
                                 maxWaiting: Self.shownWaiting, maxSessions: Self.shownSessions)
        VStack(alignment: .leading, spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
            // The middle scrolls when the panel would run off the screen; the
            // header and the bottom bar stay put.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    notices
                    if layout.isWaiting {
                        PanelRule()
                        waitingSection(layout)
                    }
                    if !layout.sessions.isEmpty || !layout.isWaiting {
                        PanelRule()
                        sessionsSection(layout, total: ranked.count)
                    }
                    PanelRule()
                    recentSection(lines: layout.isWaiting ? 2 : 4)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: scrollHeight)
            PanelRule()
            footer
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
        }
        .frame(width: 360)
        .background(ActivityPalette.ground)
        // Always dark, like Activity and the orb (see DESIGN.md, Menu bar panel).
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
            model.refreshPermissions()   // secure input or a permission may have changed
            model.refreshApprovals()
        }
        .task { await model.checkPlugin() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuIcon.image(model.menuIcon))
                .renderingMode(.template)
                .resizable()
                .frame(width: 26, height: 26)
                .foregroundStyle(stateColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Earshot").font(.headline)
                Text(model.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            talkButton
            muteMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The orb's colors: blue listening, violet working, amber speaking or holding lines.
    private var stateColor: Color {
        if model.mutedUntil != nil { return .secondary }
        if let mode = OrbMode(model) {
            let c = mode.rgb(model.config.orbColor)
            return Color(red: c.x, green: c.y, blue: c.z)
        }
        return model.speechState == .holding ? ActivityPalette.voice : .primary
    }

    private var talkButton: some View {
        Button {
            let heard = model.commandBlock == nil
            model.tapToTalk()
            if heard { dismiss() }   // out of the way of the orb
        } label: {
            Image(systemName: "mic")
        }
        .buttonStyle(.borderless)
        .help(model.commandBlock.map { model.blockLine($0) } ?? "Say one command")
        .accessibilityLabel("Talk")
        .accessibilityHint("Listens for one command")
    }

    private var muteMenu: some View {
        Menu {
            if model.mutedUntil != nil {
                Button("Unmute") { model.unmute() }
                Divider()
            }
            Button("Mute for 1 Hour") { model.mute(for: 3600) }
            Button("Mute Until Tomorrow Morning") { model.muteUntilTomorrow() }
            Button("Mute Until I Unmute") { model.muteUntilUnmuted() }
        } label: {
            Image(systemName: model.mutedUntil == nil ? "speaker.wave.2" : "speaker.slash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.mutedUntil == nil ? "Mute Earshot" : "Unmute Earshot")
        .accessibilityLabel(model.mutedUntil == nil ? "Mute" : "Unmute")
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        let needsHotkey = model.config.hotkey != .off && !model.hotkeyAllowed
        let needsMic = !model.micAllowed && (model.config.hotkey != .off || model.config.wakeWord)
        let needsPlugin = model.pluginStatus.action != nil || model.pluginWorking
        let needsModels: Bool = switch model.modelState {
        case .missing, .failed: true
        default: false
        }
        if needsPlugin || needsMic || needsHotkey || needsModels || (model.config.hotkey != .off && model.secureInput) {
            VStack(alignment: .leading, spacing: 8) {
                if needsPlugin {
                    Notice(text: model.pluginWorking ? model.pluginWorkLine : model.pluginStatus.line,
                           action: model.pluginWorking ? nil : model.pluginStatus.action) { model.fixPlugin() }
                }
                if needsModels {
                    if ListenModelFiles.partial {
                        Notice(text: "The speech model download didn't finish, so listening can't start yet.",
                               action: "Finish Download") { model.downloadModels() }
                    } else {
                        Notice(text: "Listening needs about 1 GB of speech models, downloaded once.",
                               action: model.modelState == .failed ? "Try Again" : "Download") { model.downloadModels() }
                    }
                }
                if needsMic {
                    Notice(text: model.micDenied
                           ? "Earshot can't hear you. Turn on the mic for Earshot in System Settings, Privacy & Security, Microphone."
                           : "Allow the mic so Earshot can hear you.",
                           action: AppModel.permissionAction(denied: model.micDenied)) {
                        Task { await model.requestMic() }
                    }
                }
                if needsHotkey {
                    Notice(text: model.hotkeyDenied
                           ? "Turn on Earshot in System Settings, Privacy & Security, Input Monitoring, so it can see the hotkey."
                           : "Allow Input Monitoring so Earshot can see the hotkey.",
                           action: AppModel.permissionAction(denied: model.hotkeyDenied)) {
                        model.requestHotkeyAccess()
                    }
                }
                if model.config.hotkey != .off, model.secureInput {
                    Notice(text: ListenPolicy.secureInputLine, action: nil) {}
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    // MARK: Waiting on you

    /// Waiting cards past this go to Activity, so the panel fits on a laptop screen.
    static let shownWaiting = 3

    private func waitingSection(_ layout: PanelLayout) -> some View {
        let count = layout.approvals.count + layout.questions.count + layout.moreWaiting
        // Return allows the one prompt only when no answer field could be taking it.
        let returnAllows = layout.approvals.count == 1 && layout.questions.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            // The title lines up with the other sections; only the cards are inset.
            SectionTitle(title: "Waiting on You", trailing: "\(count)", trailingColor: .orange)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(layout.approvals) { a in
                    ApprovalCard(approval: a, returnAllows: returnAllows) { show(.session(a.session)) }
                }
                ForEach(layout.questions) { s in
                    QuestionCard(session: s, last: model.lastLine(for: s.id)) { show(.session(s.id)) }
                }
                if layout.moreWaiting > 0 {
                    Button("\(layout.moreWaiting) more waiting in Activity") { show(.brief) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
    }

    // MARK: Sessions

    /// More than this and the panel runs off the screen.
    static let shownSessions = 5

    private func sessionsSection(_ layout: PanelLayout, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Sessions", trailing: total == 0 ? nil : "\(total)")
            if total == 0 {
                EmptyLine(text: model.pluginStatus.isConnected || model.pluginStatus == .checking
                          ? "No Claude Code sessions. Start one and Earshot tells you when it needs you or finishes."
                          : "No Claude Code sessions found. Connect the Earshot plugin so Earshot can tell you when a session needs you or finishes.")
            } else {
                // The list is ranked, so the first few are what needs you and what's working.
                ForEach(layout.sessions) { s in
                    SessionRow(session: s, name: model.displayName(s.id), last: model.lastLine(for: s.id)) {
                        show(.session(s.id))
                    } replay: { entry in
                        model.replay(entry)
                    }
                }
                if layout.moreSessions > 0 {
                    Button("\(layout.moreSessions) more in Activity") { show(.brief) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.top, 2)
                }
                Spacer().frame(height: 6)
            }
        }
    }

    // MARK: Recent

    /// The last few lines, fewer while something waits on you, so the panel fits.
    private func recentSection(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Recent", trailing: nil)
            let recent = Array(model.history.suffix(lines).reversed())
            if model.config.history == .off {
                EmptyLine(text: "History is off. Turn it on in Settings, General.")
            } else if recent.isEmpty {
                EmptyLine(text: "What Earshot says, and what you ask it, shows up here.")
            } else {
                ForEach(recent) { e in
                    HistoryRow(entry: e, compact: true) { model.replay(e) }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Activity") { show(.brief) }
            Button("Settings\u{2026}") {
                NSApp.activate()
                openSettings()
                dismiss()
            }
            .keyboardShortcut(",")
            Spacer()
            Menu {
                if model.updater.canCheck { Button("Check for Updates\u{2026}") { model.updater.check() } }
                Button("Copy Diagnostics") { model.copyDiagnostics() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func show(_ page: ActivityPage) {
        model.activityPage = page
        NSApp.activate()
        openWindow(id: "activity")
        dismiss()
    }
}

/// A 1pt Track rule between the panel's sections.
private struct PanelRule: View {
    var body: some View { Rectangle().fill(ActivityPalette.track).frame(height: 1) }
}

private struct SectionTitle: View {
    let title: String
    let trailing: String?
    var trailingColor: Color = .secondary
    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(trailingColor).monospacedDigit() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct EmptyLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
    }
}

private struct Notice: View {
    let text: String
    let action: String?
    let perform: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action, action: perform).controlSize(.small) }
        }
    }
}

// MARK: Waiting cards

/// Something waiting on you, in the panel: Raised, a 12pt radius and a 1pt
/// orange border, like the waiting cards in Activity. The top line names the
/// session and how long it has waited.
private struct WaitingCard<Content: View>: View {
    let name: String
    let since: Date?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(.orange).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(SessionStyle.title(name)).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if let since, Date().timeIntervalSince(since) >= 60 {
                    Text(ActivityTime.short(since))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Waiting \(ActivityTime.spoken(Date().timeIntervalSince(since)))")
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ActivityPalette.raised, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A permission prompt: what it wants, then Deny and Allow. A click answers it
/// the way a spoken yes or no does.
private struct ApprovalCard: View {
    let approval: OpenApproval
    /// Return allows this prompt: only when it is the one thing waiting.
    let returnAllows: Bool
    let open: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        WaitingCard(name: approval.name, since: approval.opened) {
            Text(approval.what.isEmpty ? "Wants your OK" : "Wants \(approval.what)")
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Session", action: open).buttonStyle(.link).font(.callout)
                Spacer(minLength: 6)
                Button("Deny") { model.answer(approval, allow: false) }
                Button("Allow") { model.answer(approval, allow: true) }
                    .keyboardShortcut(returnAllows ? .defaultAction : nil)
            }
        }
        .accessibilityLabel(approval.line)
    }
}

/// A session waiting on your answer: the question when its transcript has one
/// open, else what Earshot last said, then a one-line answer field. A question
/// with choices lists them and sends you to its window, since a typed prompt
/// cannot pick one there.
private struct QuestionCard: View {
    let session: SessionInfo
    let last: HistoryEntry?
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @State private var asked: AskedQuestion?
    @State private var note: String?
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        let name = model.displayName(session.id)
        WaitingCard(name: name, since: session.since == .distantPast ? session.updated : session.since) {
            if let asked {
                Text(asked.question).font(.callout).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                if !asked.options.isEmpty {
                    Text(asked.options.joined(separator: "  \u{00B7}  "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let last {
                Text(last.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text(SessionStyle.title(SessionStyle.describe(session)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if picker {
                HStack(spacing: 8) {
                    Button("Open Session", action: open).buttonStyle(.link).font(.callout)
                    dismissButton
                    Spacer(minLength: 6)
                    Button("Pick an Answer in \(model.hostName(session.id))") { note = model.openInTerminal(session.id) }
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Answer \(SessionStyle.title(name))", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                }
                HStack(spacing: 12) {
                    Button("Open Session", action: open).buttonStyle(.link).font(.callout)
                    dismissButton
                }
            }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
        }
        .task(id: session.id) { asked = await model.transcript(for: session.id)?.asked }
    }

    private var dismissButton: some View {
        Button("Dismiss") { model.dismiss(session.id) }
            .buttonStyle(.link)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("Take it off Waiting on You until it asks something new. The session keeps running.")
    }

    private var picker: Bool { !(asked?.options.isEmpty ?? true) }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            let line = await model.send(text, toSession: session.id)
            sending = false
            note = line
            if line.hasPrefix("Sent") || line.hasPrefix("Queued") { draft = "" }
        }
    }
}

/// A session: its state, and the last thing Earshot said about it. A click
/// opens its page in Activity.
private struct SessionRow: View {
    let session: SessionInfo
    let name: String
    let last: HistoryEntry?
    let open: () -> Void
    let replay: (HistoryEntry) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(SessionStyle.color(session.state))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(SessionStyle.title(name)).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(SessionStyle.describe(session))
                        .font(.callout)
                        .foregroundStyle(session.state == .needs || session.state == .reply ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                if let last {
                    Text(last.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let last {
                Button { replay(last) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help("Say it again")
                    .accessibilityLabel("Say \(name)'s last line again")
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this session")
        .accessibilityAction(.default, open)
    }
}

enum SessionStyle {
    static func title(_ name: String) -> String { ActivitySessions.title(name) }

    static func color(_ state: SessionState) -> Color {
        switch state {
        case .needs, .reply: .orange
        case .stuck, .failed: .red
        case .working: .blue
        case .done: .green
        case .open, .closed: .secondary
        }
    }

    static func describe(_ s: SessionInfo) -> String {
        switch s.state {
        case .needs: s.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "needs you"
        case .reply: "waiting on your answer"
        case .stuck: "might be stuck"
        case .failed: "hit an error"
        case .working: "working"
        case .done: "finished"
        case .open, .closed: "open"
        }
    }
}

/// One history entry: Earshot's line, or what you said and its reply.
struct HistoryRow: View {
    let entry: HistoryEntry
    var compact = false
    let replay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind == .heard ? "person.wave.2" : "waveform")
                .foregroundStyle(entry.kind == .heard ? AnyShapeStyle(ActivityPalette.you) : entry.asksYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind == .heard ? "\u{201C}\(entry.text)\u{201D}" : entry.text)
                    .font(compact ? .callout : .body)
                    .lineLimit(compact ? 2 : nil)
                    .textSelection(.enabled)
                if let reply = entry.reply {
                    Text(reply)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : nil)
                }
                HStack(spacing: 6) {
                    if let name = entry.sessionName { Text(SessionStyle.title(name)) }
                    Text(entry.date, format: .dateTime.hour().minute())
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: replay) { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .help(entry.kind == .heard ? "Say the reply again" : "Say it again")
                .disabled(entry.kind == .heard && entry.reply == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Say it again", replay)
    }

    private var accessibilityText: String {
        let who = entry.kind == .heard ? "You said: \(entry.text)" : "Earshot said: \(entry.text)"
        let reply = entry.reply.map { ". Earshot answered: \($0)" } ?? ""
        let session = entry.sessionName.map { ". \($0)" } ?? ""
        return who + reply + session
    }
}

extension AppModel {
    /// One line on what Earshot is doing, for the panel and the Activity window.
    var statusLine: String {
        if let error = startError { return error }
        if let until = mutedUntil {
            return until == .distantFuture ? "Muted until you unmute"
                : "Muted until \(until.formatted(date: .omitted, time: .shortened))"
        }
        switch listenPhase {
        case .capturing: return "Listening"
        case .transcribing: return "Working on it"
        default: break
        }
        if speechState == .speaking { return "Speaking" }
        if speechState == .holding { return "Lines are waiting until a call or full screen ends" }
        switch modelState {
        case .downloading(let p): return "Downloading speech models: \(Int(p * 100))%"
        case .missing, .failed: return "Speaking. Listening needs the speech models."
        case .ready: break
        }
        if let b = listenBlock {
            if b == .wakeOff, let key = hotkeyName { return "Hold \(key) to talk" }
            return blockLine(b)
        }
        return "Listening for \u{201C}Hey Earshot\u{201D}"
    }

    var hotkeyName: String? {
        switch config.hotkey {
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .off: nil
        }
    }

}
