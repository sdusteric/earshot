import AppKit
import EarshotKit
import SwiftUI

@main
struct EarshotApp: App {
    @State private var model = AppModel()
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("onboardingVersion") private var onboardingVersion = 0
    @State private var orb: OrbPanel?
    @State private var dock = DockPresence()
    @Environment(\.openWindow) private var openWindow

    init() {
        // A client hanging up must never kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Another Earshot already runs.
        if !SingleInstance.claim() { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPanel().environment(model)
        } label: {
            Image(nsImage: MenuIcon.image(model.menuIcon))
                .accessibilityLabel(model.menuIcon.label)
                // A click on a banner (see BannerPoster).
                .onChange(of: model.activityRequests) {
                    NSApp.activate()
                    openWindow(id: "activity")
                }
                .task {
                    model.start()
                    if orb == nil { orb = OrbPanel(model: model) }
                    dock.start()
                    #if DEBUG
                    // For checking the window during development: open with -openActivity YES.
                    // -openSession <id> opens it on that session's page.
                    if let id = UserDefaults.standard.string(forKey: "openSession") { model.activityPage = .session(id) }
                    // -appearance dark or light: check a window in the other appearance.
                    switch UserDefaults.standard.string(forKey: "appearance") {
                    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                    case "light": NSApp.appearance = NSAppearance(named: .aqua)
                    default: break
                    }
                    if UserDefaults.standard.bool(forKey: "openActivity") {
                        NSApp.activate()
                        openWindow(id: "activity")
                    }
                    #endif
                    if !Onboarding.steps(onboarded: onboarded, storedVersion: onboardingVersion).isEmpty {
                        NSApp.activate()
                        openWindow(id: "onboarding")
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window("Activity", id: "activity") {
            // The orb and the session page pause while the window is out of sight.
            ActivityView().environment(model).tracksWindowPresence()
        }
        .defaultSize(width: 1180, height: 760)
        .commands { ActivityCommands() }

        Settings { SettingsView().environment(model) }

        Window("Welcome to Earshot", id: "onboarding") {
            OnboardingView().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
