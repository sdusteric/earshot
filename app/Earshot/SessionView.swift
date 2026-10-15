import EarshotKit
import SwiftUI

/// One session: its last turns from its own transcript (what you typed, what
/// Claude said, the work between) with Earshot's lines about it in place, what
/// it waits on you for, and a field to reply. Open in Terminal brings its own
/// window forward for anything more.
struct SessionView: View {
    let session: SessionInfo
    @Environment(AppModel.self) private var model
    @State private var recent: SessionTranscript.Recent?
    @State private var loaded = false
    @State private var draft = ""
    @State private var sending = false
    @State private var outcome: String?
    @State private var terminalNote: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(ActivityPalette.track).frame(height: 1)
            conversation
            Rectangle().fill(ActivityPalette.track).frame(height: 1)
            composer
        }
        .task(id: session.id) {
            // The transcript grows while the session works; read its tail again every few seconds.
            while !Task.isCancelled {
                let r = await model.transcript(for: session.id)
                if r != recent { recent = r }
                loaded = true
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(SessionStyle.color(session.state)).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(SessionStyle.title(model.displayName(session.id))).font(.title2.weight(.semibold)).lineLimit(1)
            Text(SessionStyle.describe(session))
                .foregroundStyle(SessionGroup.kind(session.state) == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            if let folder {
                Text(folder).font(.callout).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 12)
            if let terminalNote { Text(terminalNote).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Button(isBackground ? "Open in Terminal" : "Show in \(hostName)", systemImage: "macwindow") {
                terminalNote = model.openInTerminal(session.id)
            }
            .help(isBackground ? "Attaches to this background session in Terminal" : "Brings this session's window forward")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var live: LiveSession? { model.liveSession(session.id) }
    private var isBackground: Bool { live?.isBackground ?? false }
    private var hostName: String {
        live?.pid.flatMap { TerminalHost.hostApp(of: $0)?.localizedName } ?? "Terminal"
    }
    private var folder: String? {
        guard let cwd = live?.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Conversation

    /// A transcript turn, or one of Earshot's lines about this session, in time order.
    private enum Item: Identifiable {
        case turn(SessionTurn)
        case earshot(HistoryEntry)
        var id: String {
            switch self {
            case .turn(let t): t.id
            case .earshot(let e): e.id.uuidString
            }
        }
        var date: Date {
            switch self {
            case .turn(let t): t.at ?? .distantPast
            case .earshot(let e): e.date
            }
        }
    }

    private var items: [Item] {
        let turns = recent?.turns ?? []
        let start = turns.first?.at ?? .distantPast
        let lines = model.history.filter { $0.kind == .said && $0.session == session.id && $0.date >= start }
        return (turns.map(Item.turn) + lines.map(Item.earshot)).sorted { $0.date < $1.date }
    }

    @ViewBuilder private var conversation: some View {
        let items = self.items
        if loaded, items.isEmpty, waitingApprovals.isEmpty {
            ContentUnavailableView {
                Label("Nothing to show yet", systemImage: "text.bubble")
            } description: {
                Text(recent == nil
                     ? "Earshot couldn't read this session's conversation. Its own window has everything."
                     : "This session hasn't said anything yet. Send it a prompt below.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(items) { item in row(item) }
                        pending.id("end")
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: items.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case .turn(let t):
            switch t.role {
            case .you:
                Turn(who: "You", color: ActivityPalette.you, text: t.text, at: t.at)
            case .claude:
                Turn(who: "Claude", color: .secondary, text: t.text, at: t.at)
            case .note:
                Turn(who: "Status", color: .secondary, text: t.text, at: t.at)
            case .work:
                Label(t.text, systemImage: "hammer")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        case .earshot(let e):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(ActivityPalette.color(e)).accessibilityHidden(true)
                Text(e.text).font(.callout).foregroundStyle(ActivityPalette.color(e))
                Button { model.replay(e) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help("Say it again")
                    .accessibilityLabel("Say it again")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Earshot said: \(e.text)")
        }
    }

    // MARK: Waiting on you

    private var waitingApprovals: [OpenApproval] { model.approvals.filter { $0.session == session.id } }

    @ViewBuilder private var pending: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(waitingApprovals) { a in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(SessionStyle.title(a.name)) wants to \(a.what).").fontWeight(.medium)
                    HStack(spacing: 8) {
                        Button("Deny") { model.answer(a, allow: false) }
                        Button("Allow") { model.answer(a, allow: true) }.keyboardShortcut(.defaultAction)
                    }
                }
                .modifier(PendingBox())
            }
            if let asked = recent?.asked {
                VStack(alignment: .leading, spacing: 8) {
                    Text(asked.question).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    if !asked.options.isEmpty {
                        Text(asked.options.joined(separator: "  ·  ")).font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Answer in \(isBackground ? "Terminal" : hostName)") { terminalNote = model.openInTerminal(session.id) }
                }
                .modifier(PendingBox())
            }
        }
    }

    // MARK: Reply

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(SessionStyle.title(model.displayName(session.id)))", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ActivityPalette.raised, in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(typing ? Color.accentColor.opacity(0.6) : ActivityPalette.track, lineWidth: 1))
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Text(outcome ?? hint).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var hint: String {
        let key = model.hotkeyName.map { "or hold \($0) and say it" } ?? "or click the orb and say it"
        return "Return sends it to this session, \(key)."
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            let line = await model.send(text, toSession: session.id)
            sending = false
            outcome = line
            if line.hasPrefix("Sent") || line.hasPrefix("Queued") { draft = "" }
        }
    }
}

/// A turn of the conversation: who, when, and the words.
private struct Turn: View {
    let who: String
    let color: Color
    let text: String
    let at: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(who).font(.caption.weight(.semibold)).foregroundStyle(color)
                if let at { Text(at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.tertiary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let h):
                        Text(Self.styled(h)).font(.headline).padding(.top, 4)
                    case .code(let c):
                        Text(c)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ActivityPalette.raised, in: .rect(cornerRadius: 8))
                    case .text(let t):
                        Text(Self.styled(t)).font(.body).lineSpacing(2)
                    }
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    enum Block: Equatable {
        case heading(String)
        /// Fenced code and tables: kept as typed, in a fixed-width face.
        case code(String)
        case text(String)
    }

    /// Claude's message in blocks: "## Heading" lines, fenced code and tables
    /// kept fixed-width, and the paragraphs between them.
    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = [], code: [String] = []
        var fenced = false
        func flushPara() { if !para.isEmpty { out.append(.text(para.joined(separator: "\n"))); para = [] } }
        func flushCode() { if !code.isEmpty { out.append(.code(code.joined(separator: "\n"))); code = [] } }
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if fenced { flushCode() } else { flushPara() }
                fenced.toggle()
                continue
            }
            if fenced { code.append(line); continue }
            if t.hasPrefix("|") {
                flushPara()
                // The |---|---| rule under a table's header says nothing on its own.
                if !t.allSatisfy({ "|-: ".contains($0) }) { code.append(t) }
                continue
            }
            flushCode()
            if t.hasPrefix("#"), let space = t.firstIndex(of: " "), t[..<space].allSatisfy({ $0 == "#" }) {
                flushPara()
                out.append(.heading(String(t[space...]).trimmingCharacters(in: .whitespaces)))
            } else if t.isEmpty {
                flushPara()
            } else {
                para.append(line)
            }
        }
        flushCode(); flushPara()
        return out
    }

    /// Inline markdown (bold, code, links) as Claude writes it; plain text if it doesn't parse.
    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// A box for what waits on you inside the conversation.
private struct PendingBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ActivityPalette.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }
}

/// Today's history: what Earshot said and what you asked, newest first, searchable.
struct HistoryPage: View {
    let search: String
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = visible
        if model.config.history == .off {
            ContentUnavailableView {
                Label("History is off", systemImage: "clock.badge.xmark")
            } description: {
                Text("Earshot isn't keeping what it says or hears. Turn history on in Settings, General.")
            }
        } else if items.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ContentUnavailableView {
                    Label("Nothing yet today", systemImage: "waveform")
                } description: {
                    Text("What Earshot says, and what you ask it, shows up here.")
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { e in
                        HistoryRow(entry: e) { model.replay(e) }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 9)
                        Divider().overlay(ActivityPalette.track).padding(.leading, 28)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visible: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return model.history.filter { now.timeIntervalSince($0.date) < 24 * 3600 }.reversed().filter { e in
            q.isEmpty || e.text.localizedCaseInsensitiveContains(q)
                || (e.reply?.localizedCaseInsensitiveContains(q) ?? false)
                || (e.sessionName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}
