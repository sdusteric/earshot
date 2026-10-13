import EarshotKit
import SwiftUI

/// The day around the orb: a 24-hour dial on the left, and on the right the
/// recap of what needs you, Earshot's newest line, and the lines for the
/// stretch of the day you pick. Clicking the orb listens for a command.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("activityLastSeen") private var lastSeenStamp: Double = 0
    @State private var since: Date?
    @State private var selection: ClosedRange<Date>?
    @State private var search = ""
    @State private var confirmClear = false
    @Environment(\.controlActiveState) private var controlActiveState

    /// The stretch to shade: since you last looked away, or on a first open
    /// (nothing stored yet), since the start of today's history, which may
    /// load after the window appears.
    private var shadeFrom: Date? {
        since ?? (lastSeenStamp == 0 ? model.history.first?.date : nil)
    }

    /// When you last looked away from this window; the first time, the start of today's history.
    private var lastLooked: Date? {
        lastSeenStamp > 0 ? Date(timeIntervalSince1970: lastSeenStamp) : model.history.first?.date
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            content(now: t.date)
        }
        .background(DialPalette.ground)
        .preferredColorScheme(.dark)
        .searchable(text: $search, placement: .toolbar, prompt: "Search what was said")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Show", selection: Binding(get: { model.activityFilter }, set: { model.activityFilter = $0 })) {
                        Text("Everything").tag(ActivityFilter.all)
                        Text("What you said").tag(ActivityFilter.you)
                        Text("What Earshot said").tag(ActivityFilter.earshot)
                        if !roster.ordered.isEmpty {
                            Divider()
                            ForEach(roster.ordered, id: \.id) { s in Text(SessionStyle.title(s.name)).tag(ActivityFilter.session(s.id)) }
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Show", systemImage: model.activityFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Show")
            }
            ToolbarItem {
                Button("Clear History", systemImage: "trash") { confirmClear = true }
                    .disabled(model.history.isEmpty)
                    .help("Clear History")
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory(); selection = nil }
        } message: {
            Text("Everything Earshot said and heard is removed from this Mac.")
        }
        .navigationTitle("Activity")
        .frame(minWidth: 980, minHeight: 640)
        .onAppear { since = lastLooked }
        .onDisappear { lastSeenStamp = Date().timeIntervalSince1970 }
        .onChange(of: controlActiveState) { old, state in
            // Looking away marks the moment; coming back shades what came since.
            if state == .key { since = lastLooked } else if old == .key { lastSeenStamp = Date().timeIntervalSince1970 }
        }
    }

    private func content(now: Date) -> some View {
        GeometryReader { geo in
            let dialSize = min(geo.size.height - 32, geo.size.width * 0.56)
            let layout = DialLayout(size: dialSize, now: now, sessions: lanes)
            HStack(alignment: .top, spacing: 0) {
                DayDial(entries: dayEntries(now), layout: layout, since: shadeFrom, selection: selection,
                        highlighted: searchMatches, focusLane: focusLane) { picked in
                    pick(picked)
                }
                .padding(16)
                .frame(width: dialSize + 32)
                Divider().overlay(DialPalette.track)
                detail(now: now)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Right side

    private func detail(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(recap).font(.system(size: 24, weight: .semibold)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Say the Recap") { model.playTestLine(recap) }
                        .disabled(model.sessions.isEmpty && model.liveSessions.isEmpty)
                    Button("Talk") { model.tapToTalk() }
                }
                .controlSize(.regular)
                NowStrip(entry: model.history.last).padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            HStack(alignment: .firstTextBaseline) {
                Text(listTitle).font(.headline)
                if selection == nil, let since = shadeFrom, since < now, now.timeIntervalSince(since) > 120 {
                    Text("Shaded on the dial: since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selection != nil {
                    Button("Show the Whole Day") { selection = nil }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
            Divider().overlay(DialPalette.track)
            list(now: now)
        }
    }

    @ViewBuilder private func list(now: Date) -> some View {
        let items = visible(now)
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
                    Label(selection == nil ? "Nothing yet today" : "Nothing in this stretch", systemImage: "waveform")
                } description: {
                    Text(selection == nil
                         ? "What Earshot says, and what you ask it, goes around the dial and shows up here. Click the orb to talk."
                         : "Click another part of the dial, or show the whole day.")
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { e in
                        HistoryRow(entry: e) { model.replay(e) }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Data

    /// The sessions as this window speaks of them: the recap, the order of
    /// the rings and the Show menu, and one name per session.
    private var roster: ActivitySessions {
        ActivitySessions(known: model.sessions.map(ActivitySessions.Known.init),
                         live: model.liveSessions.map(ActivitySessions.Live.init),
                         history: model.history)
    }

    /// At most five session rings; older sessions' dots stay off the dial but in the list.
    private var lanes: [(id: String, name: String, color: Color, active: Bool)] {
        let roster = self.roster
        return roster.ordered.prefix(5).map { s in
            let info = model.sessions.first { $0.id == s.id }
            let live = model.liveSessions.first { $0.id == s.id }
            let color = info.map { SessionStyle.color($0.state) } ?? live.map { $0.waiting ? .orange : ($0.busy ? .blue : .secondary) } ?? .secondary
            return (s.id, s.name, color, roster.isActive(s.id))
        }
    }

    private var focusLane: String? {
        switch model.activityFilter {
        case .session(let id): id
        case .you: DialLayout.youLane
        default: nil
        }
    }

    private func dayEntries(_ now: Date) -> [HistoryEntry] {
        model.history.filter { now.timeIntervalSince($0.date) < DialLayout.day }
    }

    private var searchMatches: Set<UUID> {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Set(model.history.filter { matches($0, q) }.map(\.id))
    }

    private func matches(_ e: HistoryEntry, _ q: String) -> Bool {
        e.text.localizedCaseInsensitiveContains(q)
            || (e.reply?.localizedCaseInsensitiveContains(q) ?? false)
            || (e.sessionName?.localizedCaseInsensitiveContains(q) ?? false)
    }

    private func visible(_ now: Date) -> [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let typing = NowStrip.isFresh(model.history.last, now: Date()) ? model.history.last?.id : nil
        return dayEntries(now).reversed().filter { e in
            if e.id == typing { return false }   // it is typing in above the list
            let byFilter: Bool = switch model.activityFilter {
            case .all: true
            case .you: e.kind == .heard
            case .earshot: e.kind == .said
            case .session(let id): e.session == id
            }
            guard byFilter else { return false }
            if let selection, !selection.contains(e.date) { return false }
            return q.isEmpty || matches(e, q)
        }
    }

    /// A click on the dial picks the hour around it; a click inside the picked hour clears it.
    private func pick(_ t: Date?) {
        guard let t else { selection = nil; return }
        if let s = selection, s.contains(t) { selection = nil } else { selection = t.addingTimeInterval(-1800)...t.addingTimeInterval(1800) }
    }

    // MARK: Words

    private var recap: String { roster.recap }

    private var listTitle: String {
        if let selection {
            let f = Date.FormatStyle().hour().minute()
            return "\(selection.lowerBound.formatted(f)) to \(selection.upperBound.formatted(f))"
        }
        return "Today"
    }
}
