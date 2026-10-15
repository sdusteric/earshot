import EarshotKit
import SwiftUI

/// "Since you left": who waits on you, with the question and the answer right
/// there; one line per session that changed while you were away; and the day
/// as a timeline along the bottom.
struct BriefView: View {
    let sessions: [SessionInfo]
    /// When you last looked; what came after is "while you were away".
    let since: Date?
    let now: Date
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What is waiting and what changed, in order: when it changes, the brief moves.
    private var layoutKey: [String] {
        model.approvals.map { "a:\($0.id)" } + waiting.map { "w:\($0.id)" } + changed.map { "c:\($0.id)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                masthead
                waitingSection
                awaySection
                askedSection
            }
            // One move when a session changes hands: its card arrives (or leaves,
            // answered) and the rows below settle, in the same beat.
            .animation(ActivityMotion.move(reduceMotion), value: layoutKey)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DayTimeline(entries: dayEntries, since: since, now: now) { e in
                if let id = e.session { model.activityPage = .session(id) } else { model.activityPage = .history }
            }
            .padding(.horizontal, 36)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(ActivityPalette.ground)
            .overlay(alignment: .top) { Rectangle().fill(ActivityPalette.track).frame(height: 1) }
        }
    }

    // MARK: Masthead

    private var roster: ActivitySessions {
        ActivitySessions(known: model.sessions.map(ActivitySessions.Known.init),
                         live: model.liveSessions.map(ActivitySessions.Live.init), history: model.history)
    }

    private var masthead: some View {
        let roster = self.roster
        let recap = roster.recap
        return HStack(alignment: .center, spacing: 22) {
            OrbView(size: 96, restingColor: .white, spinsWhenIdle: true)
                .background(Circle().fill(.black))
                .clipShape(.circle)
                .overlay(Circle().stroke(ActivityPalette.tick, lineWidth: 1))
                .contentShape(.circle)
                .onTapGesture { model.tapToTalk() }
                .help("Click and say a command")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Talk")
                .accessibilityHint("Listens for one command")
            VStack(alignment: .leading, spacing: 8) {
                Text(recap)
                    .font(.system(size: 24, weight: .semibold))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subline).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Talk") { model.tapToTalk() }
                    Button("Say the Recap") { model.playTestLine(roster.spokenRecap) }
                        .disabled(sessions.isEmpty)
                    if let b = model.commandBlock {
                        // Talk can't be heard now: say why next to it, not only with the closed chime.
                        Text(model.blockLine(b)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var subline: String {
        let working = sessions.filter { $0.state == .working }.count
        let busy = working == 0 ? "" : working == 1 ? " One session is still working." : " \(working) sessions are still working."
        if let since, now.timeIntervalSince(since) > 120 {
            return "You were away \(ActivityTime.spoken(now.timeIntervalSince(since)))." + busy
        }
        return model.statusLine + "." + busy
    }

    // MARK: Waiting on you

    private var waiting: [SessionInfo] { sessions.filter { SessionGroup.kind($0.state) == .needsYou } }

    @ViewBuilder private var waitingSection: some View {
        let approvals = model.approvals
        let others = waiting.filter { s in !approvals.contains { $0.session == s.id } }
        if !approvals.isEmpty || !others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Waiting on You").font(.headline)
                ForEach(approvals) { a in
                    WaitingCard(name: a.name, state: "wants to \(a.what)", since: a.opened, session: a.session) {
                        HStack(spacing: 8) {
                            Button("Deny") { model.answer(a, allow: false) }
                            Button("Allow") { model.answer(a, allow: true) }
                                .keyboardShortcut(approvals.count == 1 ? .defaultAction : nil)
                        }
                    }
                    .transition(ActivityMotion.card(reduceMotion))
                }
                ForEach(others) { s in
                    QuestionCard(session: s, last: model.lastLine(for: s.id))
                        .transition(ActivityMotion.card(reduceMotion))
                }
            }
            .transition(.opacity)
        } else if !sessions.isEmpty {
            Label("Nothing is waiting on you.", systemImage: "checkmark.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    // MARK: While you were away

    /// Sessions that changed since you looked, not counting the ones above.
    private var changed: [SessionInfo] {
        let cut = since ?? .distantPast
        return sessions.filter { s in
            SessionGroup.kind(s.state) != .needsYou && s.state != .open && s.state != .closed
                && (s.updated > cut || s.since > cut || s.state == .working)
        }
    }

    @ViewBuilder private var awaySection: some View {
        if !changed.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(since.map { now.timeIntervalSince($0) > 120 ? "While You Were Away" : "Right Now" } ?? "Today")
                    .font(.headline)
                    .padding(.bottom, 8)
                ForEach(changed) { s in
                    VStack(spacing: 2) {
                        AwayRow(session: s, name: model.displayName(s.id), last: model.lastLine(for: s.id)) { model.activityPage = .session(s.id) }
                        if s.id != changed.last?.id { Divider().overlay(ActivityPalette.track) }
                    }
                    .transition(ActivityMotion.row(reduceMotion))
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: What you asked

    @ViewBuilder private var askedSection: some View {
        let cut = since ?? .distantPast
        let asked = model.history.filter { $0.kind == .heard && $0.date > cut }.suffix(3).reversed()
        if !asked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("What You Asked").font(.headline)
                ForEach(Array(asked)) { e in
                    HistoryRow(entry: e) { model.replay(e) }
                }
            }
        }
    }

    private var dayEntries: [HistoryEntry] {
        model.history.filter { now.timeIntervalSince($0.date) < 24 * 3600 }
    }
}

/// One thing waiting on you: who, what it wants, how long, then its content and controls.
private struct WaitingCard<Actions: View>: View {
    let name: String
    let state: String
    let since: Date?
    let session: String
    @ViewBuilder let actions: () -> Actions
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(.orange).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(SessionStyle.title(name)).font(.title3.weight(.semibold))
                Text(state).foregroundStyle(.orange).lineLimit(2)
                Spacer(minLength: 8)
                if let since, Date().timeIntervalSince(since) >= 60 { Text("waiting \(ActivityTime.spoken(Date().timeIntervalSince(since)))").font(.callout).foregroundStyle(.secondary) }
                Button("Open Session") { model.activityPage = .session(session) }
                    .buttonStyle(.link)
                    .padding(.leading, 6)
            }
            actions()
        }
        .padding(16)
        .background(ActivityPalette.raised, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A session waiting on a question: the question itself when its transcript
/// has one open, else what Earshot last said about it.
private struct QuestionCard: View {
    let session: SessionInfo
    let last: HistoryEntry?
    @Environment(AppModel.self) private var model
    @State private var asked: AskedQuestion?
    @State private var note: String?
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        WaitingCard(name: model.displayName(session.id), state: SessionStyle.describe(session),
                    since: session.since == .distantPast ? session.updated : session.since, session: session.id) {
            VStack(alignment: .leading, spacing: 10) {
                if let asked {
                    Text(asked.question).font(.body).fixedSize(horizontal: false, vertical: true)
                    if !asked.options.isEmpty {
                        Text("Options: " + asked.options.joined(separator: "  ·  ")).font(.callout).foregroundStyle(.secondary)
                    }
                } else if let last {
                    Text(last.text).font(.body).foregroundStyle(.secondary)
                }
                if picker {
                    // A question with choices waits on a picker in the session's own window;
                    // typed words would queue behind it rather than answer it.
                    HStack(spacing: 8) {
                        Button("Pick an Answer in \(model.hostName(session.id))") { note = model.openInTerminal(session.id) }
                        if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("Answer \(SessionStyle.title(model.displayName(session.id)))", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(send)
                        Button("Send", action: send)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                        Button("Open in \(model.hostName(session.id))") { note = model.openInTerminal(session.id) }
                    }
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: session.id) { asked = await model.transcript(for: session.id)?.asked }
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

/// A session that changed while you were away, in one line.
private struct AwayRow: View {
    let session: SessionInfo
    let name: String
    let last: HistoryEntry?
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var latest: SessionTurn?
    /// Your last prompt to it: a working session has worked since then.
    @State private var asked: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(SessionStyle.color(session.state)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(SessionStyle.title(name)).fontWeight(.semibold).frame(width: 150, alignment: .leading).lineLimit(1)
            (Text(lead).foregroundStyle(.primary) + Text(detail.map { " " + $0 } ?? "").foregroundStyle(.secondary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(when.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this session")
        .task(id: session.id) {
            let turns = await model.transcript(for: session.id)?.turns ?? []
            latest = turns.last { $0.role != .you }
            // An old prompt says nothing about the work now (another prompt may have come by voice).
            asked = turns.last { $0.role == .you }?.at.flatMap { Date().timeIntervalSince($0) < 6 * 3600 ? $0 : nil }
        }
    }

    /// The newer of Earshot's last line about it and the session's own last turn.
    private var detail: String? {
        if let latest, let at = latest.at, at > (last?.date ?? .distantPast) {
            return latest.text.split(separator: "\n").first.map(String.init)
        }
        return last?.text
    }

    private var when: Date {
        max(last?.date ?? session.updated, latest?.at ?? .distantPast)
    }

    private var lead: String {
        // The plugin's account of when it started working, else your last prompt to it.
        let started = session.since == .distantPast ? asked : session.since
        return switch session.state {
        case .done: "Finished."
        case .working: started.map { "Working, \(ActivityTime.spoken(Date().timeIntervalSince($0))) in." } ?? "Working."
        case .stuck: "Might be stuck."
        case .failed: "Hit an error."
        default: ""
        }
    }
}
