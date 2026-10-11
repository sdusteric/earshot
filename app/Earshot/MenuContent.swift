import EarshotKit
import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let error = model.startError { Text(error) }
        if model.sessions.isEmpty {
            Text("No Claude Code sessions")
        } else {
            ForEach(model.sessions) { s in
                Text("\(s.name.prefix(1).uppercased() + s.name.dropFirst()): \(Self.describe(s))")
            }
        }
        Divider()
        if let until = model.mutedUntil {
            Text(until == .distantFuture ? "Muted" : "Muted until \(until.formatted(date: .omitted, time: .shortened))")
            Button("Unmute") { model.unmute() }
        } else {
            Button("Mute for 1 Hour") { model.mute(for: 3600) }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        if model.updater.canCheck { Button("Check for Updates…") { model.updater.check() } }
        Button("Copy Diagnostics") { model.copyDiagnostics() }
        Divider()
        Button("Quit Earshot") { NSApp.terminate(nil) }.keyboardShortcut("q")
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
