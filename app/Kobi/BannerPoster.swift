import KobiKit
import UserNotifications

/// Shows Kobi's banners (see Banners in KobiKit) and opens Activity on
/// the session when you click one. A banner for a permission prompt carries
/// Allow and Deny, which answer that one prompt (see BannerApproval).
/// A banner posted before its prompt reached Kobi gets the buttons when
/// the prompt arrives (see approvalsChanged). Permission is asked the first
/// time a banner is needed.
///
/// Posting, removing and adding buttons run one at a time, in the order
/// asked, so an older change never lands after a newer one.
final class BannerPoster: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// A click on the banner itself, with the banner's session.
    private let clicked: @MainActor @Sendable (String?) -> Void
    /// The open permission prompts, read when a banner is posted.
    private let approvals: @Sendable () async -> [OpenApproval]
    /// Allow (true) or Deny pressed on a banner: the prompt's id and session.
    private let answer: @MainActor @Sendable (_ id: String, _ session: String, _ allow: Bool) -> Void

    private enum Job: Sendable {
        case show(Banner)
        case remove(String)
        /// The open prompts changed: read them again and add buttons where they fit.
        case approvalsChanged
    }

    /// The jobs, run in order by the one task that drains them.
    private let jobs: AsyncStream<Job>.Continuation

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
        let (queue, jobs) = AsyncStream<Job>.makeStream()
        self.jobs = jobs
        super.init()
        Task { [weak self] in
            for await job in queue {
                guard let self else { return }
                await self.run(job)
            }
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Allow needs the Mac unlocked; neither button brings Kobi forward.
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: [], options: []),
        ])
    }

    /// One banner per session: a newer one replaces it.
    private static let idPrefix = "needs-you-"
    private static func id(_ session: String) -> String { idPrefix + session }

    func show(_ banner: Banner) { jobs.yield(.show(banner)) }

    /// The session went back to work: its banner is stale.
    func remove(_ session: String) { jobs.yield(.remove(session)) }

    /// The open prompts changed. A banner still delivered whose session now has
    /// exactly one open prompt, and whose buttons answer none of them, is posted
    /// again under the same identifier (replacing it) with Allow and Deny. The
    /// prompts are read when the job runs, so the latest ones are used.
    func approvalsChanged() { jobs.yield(.approvalsChanged) }

    private func run(_ job: Job) async {
        switch job {
        case .show(let banner): await post(banner)
        case .remove(let session):
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.id(session)])
        case .approvalsChanged: await addButtons()
        }
    }

    private func post(_ banner: Banner) async {
        let center = UNUserNotificationCenter.current()
        // macOS asks only once; later calls return the answer you gave.
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        content.threadIdentifier = banner.session
        var info: [String: String] = [Self.sessionKey: banner.session]
        // The session's one open prompt, when it has exactly one: the buttons answer it.
        let matched = BannerApproval.match(session: banner.session, open: await approvals())
        if let a = matched {
            content.categoryIdentifier = Self.approvalCategory
            content.body = BannerApproval.body(a)
            info[Self.approvalKey] = a.id
        }
        content.userInfo = info
        try? await center.add(UNNotificationRequest(identifier: Self.id(banner.session), content: content, trigger: nil))
        // The prompt may have arrived while this was posted: look once more.
        if matched == nil { await addButtons() }
    }

    /// Kobi's banners in Notification Center, by session.
    private static func delivered() async -> [String: UNNotificationContent] {
        var out: [String: UNNotificationContent] = [:]
        for n in await UNUserNotificationCenter.current().deliveredNotifications()
        where n.request.identifier.hasPrefix(idPrefix) {
            let c = n.request.content
            if let session = c.userInfo[sessionKey] as? String { out[session] = c }
        }
        return out
    }

    private static func shown(_ delivered: [String: UNNotificationContent]) -> [BannerApproval.Shown] {
        delivered.map { .init(session: $0.key, approval: $0.value.userInfo[approvalKey] as? String) }
    }

    /// See approvalsChanged.
    private func addButtons() async {
        let center = UNUserNotificationCenter.current()
        let open = await approvals()
        guard !open.isEmpty else { return }
        for (session, a) in BannerApproval.repost(shown: Self.shown(await Self.delivered()), open: open) {
            // Read again right before posting: the banner may have gone (you
            // closed it, or it was removed) or the prompt closed meanwhile.
            let now = await Self.delivered()
            guard let old = now[session],
                  BannerApproval.repost(shown: Self.shown(now), open: await approvals())
                      .contains(where: { $0.session == session && $0.approval.id == a.id })
            else { continue }
            let content = UNMutableNotificationContent()
            content.title = old.title
            content.threadIdentifier = old.threadIdentifier
            content.categoryIdentifier = Self.approvalCategory
            content.body = BannerApproval.body(a)
            content.userInfo = [Self.sessionKey: session, Self.approvalKey: a.id]
            try? await center.add(UNNotificationRequest(identifier: Self.id(session), content: content, trigger: nil))
        }
    }

    /// True until macOS has asked about Kobi's notifications.
    static func undecided() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    /// Shows macOS's notification prompt, once.
    static func ask() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    /// True when you turned Kobi's notifications off in System Settings.
    static func denied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    // Shown even while Kobi is the active app, for example with Settings open.
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
