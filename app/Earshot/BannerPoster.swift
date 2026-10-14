import EarshotKit
import UserNotifications

/// Shows Earshot's banners (see Banners in EarshotKit) and opens Activity
/// when you click one. Permission is asked the first time a banner is needed.
final class BannerPoster: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let clicked: @MainActor @Sendable () -> Void

    init(clicked: @escaping @MainActor @Sendable () -> Void) {
        self.clicked = clicked
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// One banner per session: a newer one replaces it.
    private static func id(_ session: String) -> String { "needs-you-\(session)" }

    func show(_ banner: Banner) async {
        let center = UNUserNotificationCenter.current()
        // macOS asks only once; later calls return the answer you gave.
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        content.threadIdentifier = banner.session
        try? await center.add(UNNotificationRequest(identifier: Self.id(banner.session), content: content, trigger: nil))
    }

    /// The session went back to work: its banner is stale.
    func remove(_ session: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.id(session)])
    }

    /// True until macOS has asked about Earshot's notifications.
    static func undecided() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    /// Shows macOS's notification prompt, once.
    static func ask() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    /// True when you turned Earshot's notifications off in System Settings.
    static func denied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    // Shown even while Earshot is the active app, for example with Settings open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await clicked()
    }
}
