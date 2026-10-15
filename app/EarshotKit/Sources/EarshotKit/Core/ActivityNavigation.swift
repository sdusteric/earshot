import Foundation

/// The Activity sidebar's groups, in the order you'd act on them.
public enum ActivityGroup: Int, CaseIterable, Sendable, Comparable {
    case needsYou, trouble, working, finished, open

    public init(_ state: SessionState) {
        switch state {
        case .needs, .reply: self = .needsYou
        case .stuck, .failed: self = .trouble
        case .working: self = .working
        case .done: self = .finished
        case .open, .closed: self = .open
        }
    }

    public var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .trouble: "Stuck or Failed"
        case .working: "Working"
        case .finished: "Finished"
        case .open: "Open"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Moving around the Activity window from the keyboard.
public enum ActivityNavigation {
    /// The sessions as the sidebar lists them: group by group, each group in
    /// the order it was given. Open sessions count even while their group is collapsed.
    public static func sidebarOrder(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.enumerated()
            .sorted { (ActivityGroup($0.element.state), $0.offset) < (ActivityGroup($1.element.state), $1.offset) }
            .map(\.element)
    }

    /// The sessions Command-1 to Command-9 open, in sidebar order.
    public static func numbered(_ sessions: [SessionInfo]) -> [SessionInfo] {
        Array(sidebarOrder(sessions).prefix(9))
    }

    /// A key for the sidebar's layout: which session sits in which group, in
    /// order. It changes when a session moves between groups, appears, or goes.
    public static func layoutKey(_ sessions: [SessionInfo]) -> [String] {
        sidebarOrder(sessions).map { "\(ActivityGroup($0.state).rawValue):\($0.id)" }
    }
}

/// The quick switcher's search over sessions by name.
public enum SwitcherMatch {
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let name: String
        /// Other words that find it: Claude Code's title for it, its project or folder.
        public let other: [String]

        public init(id: String, name: String, other: [String] = []) {
            self.id = id; self.name = name; self.other = other
        }
    }

    /// The ids that match, best first. Within a tier the given order holds,
    /// so an empty query lists every session as the sidebar does. Tiers: the
    /// whole name, the start of the name, the start of its words, anywhere in
    /// the name, anywhere in its other words, then its letters in order
    /// ("bsv" for "billing service").
    public static func rank(_ query: String, _ candidates: [Candidate]) -> [String] {
        let q = fold(query)
        guard !q.isEmpty else { return candidates.map(\.id) }
        let scored = candidates.enumerated().compactMap { i, c -> (Int, Int, String)? in
            tier(q, c).map { ($0, i, c.id) }
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    static func tier(_ q: String, _ c: Candidate) -> Int? {
        let name = fold(c.name)
        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        let words = name.split(separator: " ")
        let qWords = q.split(separator: " ")
        if qWords.allSatisfy({ qw in words.contains { $0.hasPrefix(qw) } }) { return 2 }
        if name.contains(q) { return 3 }
        if c.other.contains(where: { fold($0).contains(q) }) { return 4 }
        if inOrder(q.replacingOccurrences(of: " ", with: ""), name.replacingOccurrences(of: " ", with: "")) { return 5 }
        return nil
    }

    /// Lowercase, without accents, with dashes and underscores read as spaces.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// Every letter of `needle` appears in `hay`, in order.
    static func inOrder(_ needle: String, _ hay: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var it = hay.makeIterator()
        for ch in needle {
            var found = false
            while let h = it.next() { if h == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }
}
