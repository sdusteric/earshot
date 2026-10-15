import EarshotKit
import UserNotifications

/// Shows Earshot's banners (see Banners in EarshotKit) and opens Activity on
/// the session when you click one. A banner for a permission prompt carries
/// Allow and Deny, which answer that one prompt (see BannerApproval).
/// Permission is asked the first time a banner is needed.
final class BannerPoster: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// A click on the banner itself, with the banner's session.
    private let clicked: @MainActor @Sendable (String?) -> Void
    /// The open permission prompts, read when a banner is posted.
    private let approvals: @Sendable () async -> [OpenApproval]
    /// Allow (true) or Deny pressed on a banner: the prompt's id and session.
    private let answer: @MainActor @Sendable (_ id: String, _ session: String, _ allow: Bool) -> Void

    static let approvalCategory = "approval"
    static let allowAction = "allow"
    static let denyAction = "deny"
    private static let sessionKey = "session"
    private static let approvalKey = "approval"

    init(clicked: @escaping @MainActor @Sendable (String?) -> Void,
         approvals: @escaping @Sendable () async -> [OpenApproval],
         answer: @escaping @MainActor @Sendable (_ id: String, _ session: String, _ allow: Bool) -> Void) {
        self.clicked = clicked
        self.approvals = approvals
        self.answer = answer
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Allow needs the Mac unlocked; neither button brings Earshot forward.
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: [], options: []),
        ])
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
        var info: [String: String] = [Self.sessionKey: banner.session]
        // The session's one open prompt, when it has exactly one: the buttons answer it.
        if let a = BannerApproval.match(session: banner.session, open: await approvals()) {
            content.categoryIdentifier = Self.approvalCategory
            content.body = BannerApproval.body(a)
            info[Self.approvalKey] = a.id
        }
        content.userInfo = info
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
        let info = response.notification.request.content.userInfo
        let session = info[Self.sessionKey] as? String
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            await clicked(session)
        case Self.allowAction, Self.denyAction:
            // Only a banner made for one prompt has these; the app checks it is still open.
            guard let id = info[Self.approvalKey] as? String, let session else { return }
            await answer(id, session, response.actionIdentifier == Self.allowAction)
        default:
            break   // dismissed
        }
    }
}
