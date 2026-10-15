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
    /// The first read fills the page at once; only lines that come after it move in.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var sending = false
    @State private var outcome: String?
    @State private var sentAt: Date?
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
        .task(id: loaded) {
            guard loaded, !settled else { return }
            try? await Task.sleep(for: .milliseconds(300))
            settled = true
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
                Text(folder).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
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
    private var hostName: String { model.hostName(session.id) }
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
            Group {
                if recent == nil {
                    ContentUnavailableView {
                        Label("Can't read this conversation", systemImage: "doc.questionmark")
                    } description: {
                        Text("Earshot found no transcript for this session. Its own window has everything.")
                    } actions: {
                        Button(isBackground ? "Open in Terminal" : "Show in \(hostName)") { terminalNote = model.openInTerminal(session.id) }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Nothing to show yet", systemImage: "text.bubble")
                    } description: {
                        Text("This session hasn't said anything yet. Send it a prompt below.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // At most 30 turns: a plain stack, so rows that hold grids and code measure right.
                    VStack(alignment: .leading, spacing: 14) {
                        if loaded, recent == nil, !items.isEmpty {
                            Label("Earshot can't read this session's transcript, so only what Earshot said shows here.",
                                  systemImage: "doc.questionmark")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            if item.id == firstNote {
                                Text("Progress Notes").font(.headline).padding(.bottom, -4)
                            }
                            row(item)
                                .transition(ActivityMotion.line(reduceMotion))
                        }
                        pending.id("end")
                    }
                    .animation(settled ? ActivityMotion.move(reduceMotion) : nil, value: conversationKey)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: items.count) {
                    withAnimation(settled ? ActivityMotion.move(reduceMotion) : nil) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }

    /// What the conversation holds, in order: a new line, prompt or question changes it.
    private var conversationKey: [String] {
        items.map(\.id) + waitingApprovals.map { "a:\($0.id)" } + [recent?.asked?.question ?? ""]
    }

    /// A background job's notes read as one log under one heading.
    private var firstNote: String? {
        recent?.turns.first { $0.role == .note }?.id
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
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(t.at.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(t.text).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: Turn.measure, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, -4)
            case .work:
                Label(t.text, systemImage: "hammer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                        Button("Allow") { model.answer(a, allow: true) }
                            // Return allows only when it can mean one prompt.
                            .keyboardShortcut(waitingApprovals.count == 1 ? .defaultAction : nil)
                    }
                }
                .modifier(PendingBox())
                .transition(ActivityMotion.card(reduceMotion))
            }
            if let asked = recent?.asked {
                VStack(alignment: .leading, spacing: 8) {
                    Text(asked.question).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    if asked.options.isEmpty {
                        Text("Type your answer below and Earshot sends it to \(SessionStyle.title(model.displayName(session.id))).")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        // Choices wait on a picker in the session's own window; typed words would queue behind it.
                        Text("Options: " + asked.options.joined(separator: "  ·  ")).font(.callout).foregroundStyle(.secondary)
                        Button("Pick an Answer in \(hostName)") { terminalNote = model.openInTerminal(session.id) }
                    }
                }
                .modifier(PendingBox())
                .transition(ActivityMotion.card(reduceMotion))
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
            Text(receipt ?? outcome ?? hint).font(.caption).foregroundStyle(.secondary)
                .onChange(of: receipt) { _, line in
                    if let line { AccessibilityNotification.Announcement(line).post() }
                }
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
        sentAt = Date()
        Task {
            let line = await model.send(text, toSession: session.id)
            sending = false
            outcome = line
            if line.hasPrefix("Sent") || line.hasPrefix("Queued") { draft = "" }
        }
    }

    /// What became of the last send, once Earshot knows ("Blog started working.").
    private var receipt: String? { model.receiptLine(for: session.id, since: sentAt) }
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
                if let at { Text(at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary) }
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
                    case .table(let rows):
                        TableBlock(rows: rows)
                    case .text(let t):
                        Text(Self.styled(t)).font(.body).lineSpacing(2)
                    }
                }
            }
            .frame(maxWidth: Self.measure, alignment: .leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// About 75 characters of body text: past this, long lines get hard to read.
    static let measure: CGFloat = 520

    enum Block: Equatable {
        case heading(String)
        /// Fenced code: kept as typed, in a fixed-width face.
        case code(String)
        /// A markdown table: its rows of cells, the header first.
        case table([[String]])
        case text(String)
    }

    /// Claude's message in blocks: "## Heading" lines, fenced code and tables
    /// kept fixed-width, and the paragraphs between them.
    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = [], code: [String] = [], table: [[String]] = []
        var fenced = false
        func flushPara() { if !para.isEmpty { out.append(.text(para.joined(separator: "\n"))); para = [] } }
        func flushCode() { if !code.isEmpty { out.append(.code(code.joined(separator: "\n"))); code = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }
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
                if !t.allSatisfy({ "|-: ".contains($0) }) {
                    var cells = t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    table.append(cells)
                }
                continue
            }
            flushTable()
            if t.hasPrefix("#"), let space = t.firstIndex(of: " "), t[..<space].allSatisfy({ $0 == "#" }) {
                flushPara()
                out.append(.heading(String(t[space...]).trimmingCharacters(in: .whitespaces)))
            } else if t.isEmpty {
                flushPara()
            } else {
                para.append(line)
            }
        }
        flushTable(); flushCode(); flushPara()
        return out
    }

    /// Inline markdown (bold, code, links) as Claude writes it; plain text if it doesn't parse.
    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// A markdown table as a grid: the header row in semibold, cells with their inline markdown.
private struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow {
                    ForEach(0..<width, id: \.self) { c in
                        Text(Turn.styled(c < row.count ? row[c] : ""))
                            .font(i == 0 ? .callout.weight(.semibold) : .callout)
                            .foregroundStyle(i == 0 ? .primary : .secondary)
                    }
                }
                if i == 0 { Divider().overlay(ActivityPalette.track) }
            }
        }
        .padding(12)
        .background(ActivityPalette.raised, in: .rect(cornerRadius: 8))
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
    /// Ends the search, when this page shows one.
    var clearSearch: (() -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = visible
        if model.config.history == .off {
            ContentUnavailableView {
                Label("History is off", systemImage: "clock.badge.xmark")
            } description: {
                Text("Earshot isn't keeping what it says or hears, so there is nothing to show or search.")
            } actions: {
                Button("Turn On History") { model.turnOnHistory() }
            }
        } else if items.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView {
                    Label("No results for \u{201C}\(search.trimmingCharacters(in: .whitespaces))\u{201D}", systemImage: "magnifyingglass")
                } description: {
                    Text("Search looks through today's lines and what you asked. Try a session's name or another word.")
                } actions: {
                    if let clearSearch { Button("Clear Search", action: clearSearch) }
                }
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

extension AppModel {
    /// History back on, kept for 24 hours: the default, as Settings, General sets it.
    func turnOnHistory() {
        save { $0.set("EARSHOT_HISTORY", nil) }
    }
}
