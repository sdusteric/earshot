import AppKit
import KobiKit

/// Brings a session's own window forward: the app it runs in (Terminal,
/// iTerm, Ghostty, an editor), found by walking up from its process. A
/// background session has no window, so it opens in Terminal with
/// `claude attach`.
@MainActor
enum TerminalHost {
    enum Result: Equatable {
        case shown(String)
        case attached
        case failed(String)
    }

    static func open(_ s: LiveSession, claude: String?) -> Result {
        if let pid = s.pid, let app = hostApp(of: pid) {
            app.activate()
            return .shown(app.localizedName ?? "its terminal")
        }
        if s.isBackground || s.pid == nil {
            return attach(s, claude: claude)
        }
        return .failed("Couldn't find the window \(s.name) runs in.")
    }

    /// The nearest app with a Dock icon among the process's parents.
    static func hostApp(of pid: Int32) -> NSRunningApplication? {
        for p in ProcessTree.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                return app
            }
        }
        return nil
    }

    /// A one-line script Terminal runs: go to the session's folder and attach.
    private static func attach(_ s: LiveSession, claude: String?) -> Result {
        guard let claude else { return .failed("Kobi can't find the claude command to open \(s.name).") }
        let dir = FileManager.default.temporaryDirectory.appending(path: "kobi-attach", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(s.id.prefix(8)).command")
        var lines = ["#!/bin/zsh -l"]
        if !s.cwd.isEmpty { lines.append("cd \(quoted(s.cwd))") }
        lines.append("exec \(quoted(claude)) attach \(quoted(s.id))")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return .failed("Couldn't open \(s.name) in Terminal.")
        }
        return NSWorkspace.shared.open(file) ? .attached : .failed("Couldn't open \(s.name) in Terminal.")
    }

    /// Single quotes for the shell, with any single quote inside escaped.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
