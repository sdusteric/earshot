import EarshotKit
import SwiftUI

/// Everything Earshot said and heard in the last day: by session, by who
/// spoke, searchable, with each line one click from being said again.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.activityFilter }, set: { if let f = $0 { model.activityFilter = f } })) {
                Label("All", systemImage: "tray.full").tag(ActivityFilter.all)
                Label("You said", systemImage: "person.wave.2").tag(ActivityFilter.you)
                Label("Earshot said", systemImage: "waveform").tag(ActivityFilter.earshot)
                if !sessionNames.isEmpty {
                    Section("Sessions") {
                        ForEach(sessionNames, id: \.id) { s in
                            Label {
                                Text(SessionStyle.title(s.name))
                            } icon: {
                                Circle().fill(color(for: s.id)).frame(width: 8, height: 8)
                            }
                            .tag(ActivityFilter.session(s.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail
                .navigationTitle(title)
                .searchable(text: $search, placement: .toolbar, prompt: "Search what was said")
                .toolbar {
                    ToolbarItem {
                        Button("Clear History", systemImage: "trash") { confirmClear = true }
                            .disabled(model.history.isEmpty)
                            .help("Clear History")
                    }
                }
                .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
                    Button("Clear History", role: .destructive) { model.clearHistory() }
                } message: {
                    Text("Everything Earshot said and heard is removed from this Mac.")
                }
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    @ViewBuilder private var detail: some View {
        let items = filtered
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
                    Label(emptyTitle, systemImage: "waveform")
                } description: {
                    Text(emptyText)
                }
            }
        } else {
            List {
                ForEach(groups(items), id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.items) { e in
                            HistoryRow(entry: e) { model.replay(e) }
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    // MARK: -

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return model.history.reversed().filter { e in
            let matchesFilter: Bool = switch model.activityFilter {
            case .all: true
            case .you: e.kind == .heard
            case .earshot: e.kind == .said
            case .session(let id): e.session == id
            }
            guard matchesFilter else { return false }
            guard !q.isEmpty else { return true }
            return e.text.localizedCaseInsensitiveContains(q)
                || (e.reply?.localizedCaseInsensitiveContains(q) ?? false)
                || (e.sessionName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private struct Group { let title: String; let items: [HistoryEntry] }

    /// Today and Yesterday: history keeps one day, so there are at most two.
    private func groups(_ items: [HistoryEntry]) -> [Group] {
        let cal = Calendar.current
        let today = items.filter { cal.isDateInToday($0.date) }
        let earlier = items.filter { !cal.isDateInToday($0.date) }
        var out: [Group] = []
        if !today.isEmpty { out.append(Group(title: "Today", items: today)) }
        if !earlier.isEmpty { out.append(Group(title: "Yesterday", items: earlier)) }
        return out
    }

    /// Sessions that appear in the history or are open now, newest first.
    private var sessionNames: [(id: String, name: String)] {
        var seen: [String: String] = [:]
        var order: [String] = []
        for s in model.sessions where seen[s.id] == nil { seen[s.id] = s.name; order.append(s.id) }
        for e in model.history.reversed() {
            guard let id = e.session, seen[id] == nil, let name = e.sessionName else { continue }
            seen[id] = name
            order.append(id)
        }
        return order.map { ($0, seen[$0] ?? $0) }
    }

    private func color(for id: String) -> Color {
        model.sessions.first { $0.id == id }.map { SessionStyle.color($0.state) } ?? .secondary
    }

    private var title: String {
        switch model.activityFilter {
        case .all: "Activity"
        case .you: "You said"
        case .earshot: "Earshot said"
        case .session(let id): sessionNames.first { $0.id == id }.map { SessionStyle.title($0.name) } ?? "Session"
        }
    }

    private var emptyTitle: String {
        switch model.activityFilter {
        case .you: "Nothing you said yet"
        case .session: "Nothing about this session yet"
        default: "Nothing yet"
        }
    }

    private var emptyText: String {
        switch model.activityFilter {
        case .you: "Hold the hotkey and give a command. What you said and what Earshot did shows up here."
        case .session: "When Earshot says something about this session, it shows up here."
        default: model.config.history == .session
            ? "What Earshot says and hears shows up here until Earshot quits."
            : "What Earshot says and hears shows up here, kept for a day."
        }
    }
}
