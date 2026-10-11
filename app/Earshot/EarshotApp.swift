import AppKit
import EarshotKit
import SwiftUI

@main
struct EarshotApp: App {
    @State private var model = AppModel()
    @AppStorage("onboarded") private var onboarded = false
    @State private var orb: OrbPanel?
    @Environment(\.openWindow) private var openWindow

    init() {
        // A client hanging up must never kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Another Earshot already runs.
        if !SingleInstance.claim() { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(systemName: model.menuIcon)
                .task {
                    model.start()
                    if orb == nil { orb = OrbPanel(model: model) }
                    if !onboarded {
                        NSApp.activate()
                        openWindow(id: "onboarding")
                    }
                }
        }
        .menuBarExtraStyle(.menu)

        Settings { SettingsView().environment(model) }

        Window("Welcome to Earshot", id: "onboarding") {
            OnboardingView().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
