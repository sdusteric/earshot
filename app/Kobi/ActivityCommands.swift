import KobiKit
import SwiftUI

/// What the Go menu can do in the Activity window, published while that
/// window is key (see ActivityView). Nil anywhere else, which turns the menu off.
struct ActivityNav {
    struct Numbered: Identifiable {
        let id: String
        let name: String
    }

    /// The sessions Command-1 to Command-9 open, in sidebar order.
    var numbered: [Numbered]
    var go: @MainActor (ActivityPage) -> Void
    var openSwitcher: @MainActor () -> Void
    var focusSearch: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var activityNav: ActivityNav?
}

/// The Go menu: the brief, the history, the first nine sessions, the quick
/// switcher and the search field, each with its shortcut.
struct ActivityCommands: Commands {
    @FocusedValue(\.activityNav) private var nav

    var body: some Commands {
        CommandMenu("Go") {
            Button("Since You Left") { nav?.go(.brief) }
                .keyboardShortcut("0")
                .disabled(nav == nil)
            Button("Today\u{2019}s History") { nav?.go(.history) }
                .disabled(nav == nil)
            Divider()
            if let nav, !nav.numbered.isEmpty {
                ForEach(Array(nav.numbered.enumerated()), id: \.element.id) { i, s in
                    Button(s.name) { nav.go(.session(s.id)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            } else {
                Button("No Sessions") {}.disabled(true)
            }
            Divider()
            Button("Go to Session\u{2026}") { nav?.openSwitcher() }
                .keyboardShortcut("k")
                .disabled(nav == nil)
            Button("Search What Was Said") { nav?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(nav == nil)
        }
    }
}

/// Command-K: type part of a session's name, pick with the arrow keys, open with Return.
struct QuickSwitcher: View {
    /// Every session, in sidebar order.
    let sessions: [SessionInfo]
    let name: (String) -> String
    /// Other words that find a session: its title in Claude Code, its folder.
    let other: (SessionInfo) -> [String]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked = 0
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 34
    private static let visibleRows = 8

    private var matches: [SessionInfo] {
        let candidates = sessions.map { SwitcherMatch.Candidate(id: $0.id, name: name($0.id), other: other($0)) }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return SwitcherMatch.rank(query, candidates).compactMap { byID[$0] }
    }

    var body: some View {
        let matches = self.matches
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Go to a session", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(matches) }
                    .onKeyPress(.downArrow) { move(1, count: matches.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: matches.count); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(ActivityPalette.track).frame(height: 1)
            if matches.isEmpty {
                Text(sessions.isEmpty ? "No Claude Code sessions are open." : "No session matches \u{201C}\(query)\u{201D}.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { i, s in
                                row(s, selected: i == picked).id(i)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: CGFloat(min(matches.count, Self.visibleRows)) * Self.rowHeight + 12)
                    .onChange(of: picked) { proxy.scrollTo(picked) }
                }
            }
            Rectangle().fill(ActivityPalette.track).frame(height: 1)
            Text("Up and Down to choose, Return to open, Escape to close.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 460)
        .background(ActivityPalette.raised)
        .background {
            // The field keeps focus; these take the arrows and Escape before it does.
            Group {
                Button("Previous") { move(-1, count: matches.count) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("Next") { move(1, count: matches.count) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: query) { picked = 0 }
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func row(_ s: SessionInfo, selected: Bool) -> some View {
        let number = ActivityNavigation.numbered(sessions).firstIndex { $0.id == s.id }.map { $0 + 1 }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(SessionStyle.color(s.state)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(SessionStyle.title(name(s.id))).fontWeight(.medium).lineLimit(1)
            Text(SessionStyle.describe(s)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if let number {
                Text("\u{2318}\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture { open(s.id); dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        picked = (picked + step + count) % count
    }

    private func choose(_ matches: [SessionInfo]) {
        guard matches.indices.contains(picked) else { return }
        open(matches[picked].id)
        dismiss()
    }
}
