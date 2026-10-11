import Sparkle
import SwiftUI

/// Sparkle's updater, started with the app. Without a public key (a local
/// build) it stays off.
@MainActor
final class Updater {
    let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var canCheck: Bool { controller != nil }
    func check() { controller?.checkForUpdates(nil) }
}
