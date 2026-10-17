import Sparkle
import SwiftUI

/// Sparkle's updater, started with the app. Without a real public key (a local
/// build, or project.yml still holding its placeholder) it stays off.
@MainActor
final class Updater {
    let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        // An EdDSA public key is 32 bytes in base64. The placeholder is not.
        let hasKey = Data(base64Encoded: key)?.count == 32
        controller = hasKey
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var canCheck: Bool { controller != nil }
    func check() { controller?.checkForUpdates(nil) }
}
