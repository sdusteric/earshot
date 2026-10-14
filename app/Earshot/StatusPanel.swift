import EarshotKit
import SwiftUI

/// What the Activity window shows.
enum ActivityFilter: Hashable {
    case all, you, earshot
    case session(String)
}

/// The panel under the menu bar icon: what Earshot is doing, the sessions
/// with whoever needs you first, the last few things said, and quick controls.
struct StatusPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.approvals.isEmpty {
                ApprovalRows()
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            notices
            Divider()
            sessionsSection
            Divider()
            recentSection
            Divider()
            footer
        }
        .frame(width: 360)
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
            Spacer(minLength: 8)
            muteMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var stateColor: Color {
        switch model.menuIcon {
        case .muted: .secondary
        case .active: .accentColor
        case .holding: .orange
        case .idle, .ready: .primary
        }
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

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Sessions", trailing: model.sessions.isEmpty ? nil : "\(model.sessions.count)")
            if model.sessions.isEmpty {
                Text("No Claude Code sessions. Start one and Earshot tells you when it needs you or finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                ForEach(model.sessions) { s in
                    SessionRow(session: s, last: model.lastLine(for: s.id)) {
                        show(.session(s.id))
                    } replay: { entry in
                        model.replay(entry)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Recent", trailing: nil)
            let recent = Array(model.history.suffix(4).reversed())
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
            Button("Activity") { show(.all) }
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

    private func show(_ filter: ActivityFilter) {
        model.activityFilter = filter
        NSApp.activate()
        openWindow(id: "activity")
        dismiss()
    }
}

private struct SectionTitle: View {
    let title: String
    let trailing: String?
    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.tertiary).monospacedDigit() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
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

/// Permission prompts waiting on you, each with Allow and Deny. A click answers
/// it the way a spoken yes or no does. With one prompt, Return allows it.
struct ApprovalRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let open = model.approvals
        VStack(alignment: .leading, spacing: 8) {
            ForEach(open) { a in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(a.line).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Deny") { model.answer(a, allow: false) }
                    Button("Allow") { model.answer(a, allow: true) }
                        .keyboardShortcut(open.count == 1 ? .defaultAction : nil)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(a.line)
            }
        }
    }
}

/// A session: its state, and the last thing Earshot said about it.
private struct SessionRow: View {
    let session: SessionInfo
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
                    Text(SessionStyle.title(session.name)).font(.body.weight(.medium)).lineLimit(1)
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
                    .accessibilityLabel("Say \(session.name)'s last line again")
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows this session's activity")
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
                .foregroundStyle(entry.kind == .heard ? AnyShapeStyle(.tint) : entry.asksYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
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
                .font(.caption)
                .foregroundStyle(.tertiary)
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
            return ListenPolicy.menuLine(b)
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
