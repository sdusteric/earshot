import KobiKit
import SwiftUI

/// Activity: an inbox for your sessions. The sidebar has the brief ("Since
/// you left"), the day's history, and every session grouped by what it needs;
/// the detail is the brief, the history, or one session's view.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("activityLastSeen") private var lastSeenStamp: Double = 0
    @State private var since: Date?
    @State private var search = ""
    @State private var confirmClear = false
    @State private var switching = false
    @FocusState private var searchFocused: Bool
    /// The Open group is long and rarely needed: collapsed until you open it.
    @AppStorage("activityOpenExpanded") private var openExpanded = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When you last looked away from this window; the first time, the start of today's history.
    private var lastLooked: Date? {
        lastSeenStamp > 0 ? Date(timeIntervalSince1970: lastSeenStamp) : model.history.first?.date
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            TimelineView(.periodic(from: .now, by: 30)) { t in
                detail(now: t.date)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(ActivityPalette.ground)
            }
        }
        .preferredColorScheme(.dark)
        .searchable(text: $search, placement: .sidebar, prompt: "Search what was said")
        .searchFocused($searchFocused)
        .sheet(isPresented: $switching) {
            QuickSwitcher(sessions: ActivityNavigation.sidebarOrder(sessions),
                          name: { SessionStyle.title(model.displayName($0)) },
                          other: { s in [s.title, s.project, model.liveSession(s.id)?.cwd].compactMap { $0 } }) { id in
                go(.session(id))
            }
        }
        .focusedSceneValue(\.activityNav, nav)
        .toolbar {
            if model.activityPage == .history {
                ToolbarItem {
                    Button("Clear History", systemImage: "trash") { confirmClear = true }
                        .disabled(model.history.isEmpty)
                        .help("Clear History")
                }
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Everything Kobi said and heard is removed from this Mac.")
        }
        .toolbarBackground(ActivityPalette.ground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .navigationTitle("Activity")
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { since = lastLooked; revealSelection() }
        .onChange(of: model.activityPage) { revealSelection() }
        // The session list can arrive after the window opens.
        .onChange(of: sessions.map(\.id)) { revealSelection() }
        .onDisappear { lastSeenStamp = Date().timeIntervalSince1970 }
        .onChange(of: controlActiveState) { old, state in
            // Looking away marks the moment; coming back, the brief covers what came since.
            if state == .key { since = lastLooked } else if old == .key { lastSeenStamp = Date().timeIntervalSince1970 }
        }
    }

    // MARK: Sidebar

    private var sessions: [SessionInfo] { SessionInfo.panelList(known: model.sessions, live: model.liveSessions) }

    private var sidebar: some View {
        let groups = SessionGroup.split(sessions)
        return List(selection: Binding<ActivityPage?>(get: { model.activityPage }, set: { if let p = $0 { model.activityPage = p } })) {
            Section {
                Label {
                    HStack {
                        Text("Since You Left")
                        Spacer()
                        let waiting = groups.first { $0.kind == .needsYou }?.sessions.count ?? 0
                        if waiting > 0 { Text("\(waiting)").font(.callout.monospacedDigit()).foregroundStyle(.orange) }
                    }
                } icon: {
                    Image(systemName: "tray.full")
                }
                .tag(ActivityPage.brief)
                Label("Today's History", systemImage: "clock").tag(ActivityPage.history)
            }
            if sessions.isEmpty {
                Section("Sessions") {
                    Text("No Claude Code sessions are open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            let names = Dictionary(grouping: sessions, by: { NameMatch.normalize(model.displayName($0.id)) })
            ForEach(groups) { g in
                let rows = ForEach(g.sessions) { s in
                    SessionSidebarRow(session: s, name: model.displayName(s.id), last: model.lastLine(for: s.id),
                                      started: (names[NameMatch.normalize(model.displayName(s.id))]?.count ?? 0) > 1
                                          ? model.liveSession(s.id)?.started : nil)
                        .tag(ActivityPage.session(s.id))
                }
                if g.kind == .open {
                    Section(isExpanded: $openExpanded) { rows } header: {
                        Text("\(g.kind.title) \u{00B7} \(g.sessions.count)")
                    }
                } else {
                    Section(g.kind.title) { rows }
                }
            }
        }
        .listStyle(.sidebar)
        // A session that changes groups (Working to Needs You) moves there rather than jumping.
        .animation(ActivityMotion.sidebar(reduceMotion), value: ActivityNavigation.layoutKey(sessions))
    }

    // MARK: Keyboard

    /// The Go menu's actions, while this window is key.
    private var nav: ActivityNav {
        ActivityNav(numbered: ActivityNavigation.numbered(sessions).map { .init(id: $0.id, name: SessionStyle.title(model.displayName($0.id))) },
                    go: { go($0) },
                    openSwitcher: { switching = true },
                    focusSearch: { searchFocused = true })
    }

    /// Opens a page; a search in progress would hide it, so it ends.
    private func go(_ page: ActivityPage) {
        search = ""
        model.activityPage = page
    }

    /// A session picked from the menu bar may sit in the collapsed Open group: open it, so the selection shows.
    private func revealSelection() {
        guard case .session(let id) = model.activityPage, let s = sessions.first(where: { $0.id == id }),
              SessionGroup.kind(s.state) == .open else { return }
        openExpanded = true
    }

    // MARK: Detail

    @ViewBuilder private func detail(now: Date) -> some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            HistoryPage(search: search, now: now) { search = "" }
        } else {
            switch model.activityPage {
            case .brief:
                BriefView(sessions: sessions, since: since ?? lastLooked, now: now)
            case .history:
                HistoryPage(search: "", now: now)
            case .session(let id):
                if let s = sessions.first(where: { $0.id == id }) {
                    SessionView(session: s).id(id)
                } else {
                    ContentUnavailableView {
                        Label("This session has closed", systemImage: "rectangle.on.rectangle.slash")
                    } description: {
                        Text("Claude Code doesn't list it any more. Its lines stay in today's history.")
                    } actions: {
                        Button("Show the Brief") { model.activityPage = .brief }
                    }
                }
            }
        }
    }

}

/// The sidebar's groups, in the order you'd act on them (see ActivityGroup).
struct SessionGroup: Identifiable {
    typealias Kind = ActivityGroup

    let kind: Kind
    let sessions: [SessionInfo]
    var id: Int { kind.rawValue }

    static func kind(_ state: SessionState) -> Kind { ActivityGroup(state) }

    static func split(_ sessions: [SessionInfo]) -> [SessionGroup] {
        Kind.allCases.compactMap { k in
            let these = sessions.filter { kind($0.state) == k }
            return these.isEmpty ? nil : SessionGroup(kind: k, sessions: these)
        }
    }
}

/// A session in the sidebar: its state dot, its name, and the last thing
/// Kobi said about it (or what Claude Code calls the session).
private struct SessionSidebarRow: View {
    let session: SessionInfo
    let name: String
    let last: HistoryEntry?
    /// When another session has the same name: when this one started, to tell them apart.
    var started: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(SessionStyle.color(session.state)).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(SessionStyle.title(name)).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    if let when {
                        Text(ActivityTime.short(when)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let second {
                    Text(second).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SessionStyle.title(name)), \(SessionStyle.describe(session))")
    }

    /// The last line about it, else Claude Code's title when it says more than the name.
    private var second: String? {
        let start = started.map { "Started \($0.formatted(date: .omitted, time: .shortened))" }
        if let start { return [start, last?.text].compactMap { $0 }.joined(separator: " \u{00B7} ") }
        if let last { return last.text }
        guard let t = session.title, !t.isEmpty, NameMatch.normalize(t) != NameMatch.normalize(name) else { return nil }
        return t
    }

    /// When it last spoke or changed state; nothing for a quiet open session.
    private var when: Date? {
        if let last { return last.date }
        return session.since == .distantPast ? nil : session.since
    }
}

enum ActivityTime {
    /// "now", "4m", "2h", "3d": how long ago, for tight spaces.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// "42 minutes", "3 hours": a stretch of time in words.
    static func spoken(_ interval: TimeInterval) -> String {
        let m = Int(interval / 60)
        if m < 60 { return m == 1 ? "a minute" : "\(m) minutes" }
        let h = m / 60
        if h < 24 { return h == 1 ? "an hour" : "\(h) hours" }
        let d = h / 24
        return d == 1 ? "a day" : "\(d) days"
    }
}
