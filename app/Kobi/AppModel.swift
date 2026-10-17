import AppKit
import AVFoundation
import Carbon.HIToolbox
import KobiKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class AppModel {
    /// The plugin's sessions, with dismissed waits read as open (see Dismissals).
    private(set) var sessions: [SessionInfo] = []
    /// What `claude agents` lists: running sessions even before the plugin
    /// reports them. Dismissed waits read as open here too.
    private(set) var liveSessions: [LiveSession] = []
    /// Both lists as their sources give them, before dismissals.
    private var knownRaw: [SessionInfo] = []
    private var liveRaw: [LiveSession] = []
    /// Claude Code's list has come in once: before that, a session missing from it proves nothing.
    private var liveLoaded = false
    /// Waits you dismissed, kept across launches.
    private(set) var dismissals = AppModel.loadDismissals()
    /// What Kobi said and heard, oldest first (see HistoryStore).
    var history: [HistoryEntry] = []
    /// Permission prompts waiting on you, oldest first, for the Allow and Deny rows.
    var approvals: [OpenApproval] = []
    /// Whether Claude Code has the Kobi plugin, and an install under way.
    var pluginStatus: PluginStatus = .checking
    var pluginWorking = false
    /// What the plugin row says while `pluginWorking`.
    var pluginWorkLine = "Installing through Claude Code\u{2026}"
    /// What the Activity window shows; set before opening it from the panel.
    var activityPage: ActivityPage = .brief
    /// Goes up when a click on a banner asks for the Activity window (see KobiApp).
    var activityRequests = 0
    /// You turned Kobi's notifications off in System Settings.
    var notificationsDenied = false
    var speechState: SpeechOut.State = .idle
    var listenPhase: Listener.Phase = .off
    /// Kobi is working out its answer to what you said (see VoiceLoop.thinking).
    var thinking = false
    /// What the floating orb's caption shows: listening, what was heard (as the
    /// history keeps it), or the line Kobi is saying. Never logged.
    var caption: OrbCaption?
    /// What became of the last prompt sent to each session (see Dispatcher.watchReceipt).
    var receipts: [String: Dispatcher.Receipt] = [:]
    /// Sessions answered from a waiting card a moment ago, by when: the brief
    /// keeps the card up until it can say what became of the answer.
    var answered: [String: Date] = [:]
    var listenBlock: ListenBlock?
    /// Why a command can't be heard now (the hotkey, Talk, the orb), or nil.
    var commandBlock: ListenBlock?
    /// The app holding the mic while another app uses it, for "Not listening while Zoom uses the mic."
    var micApp: String?
    /// macOS hasn't asked about Kobi's notifications yet.
    var notificationsUndecided = false
    /// The two above have been read once, so a permission row can trust them.
    var notificationsChecked = false
    var modelState: ListenModels.State = ListenModelFiles.present ? .ready : .missing
    var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    /// You answered the mic prompt with no (or a profile blocks it): only System Settings can change it.
    var micDenied = AppModel.micAnsweredNo
    var hotkeyAllowed = HotkeyTap.allowed
    var hotkeyDenied = HotkeyTap.denied
    /// Another app has secure keyboard entry on, so the hotkey is refused.
    var secureInput = IsSecureEventInputEnabled()
    var wakeLoadFailed = false
    var mutedUntil: Date?
    var config = KobiConfig.load()
    var startError: String?
    /// On, or waiting for your OK in System Settings, Login Items.
    var launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    var launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    var launchAtLoginError: String?

    @ObservationIgnored let updater = Updater()
    @ObservationIgnored private var core: KobiCore?
    @ObservationIgnored private var ducker: TapDucker?
    @ObservationIgnored private var mic: MicMonitor?
    @ObservationIgnored private var muteTimer: Timer?
    @ObservationIgnored private let configBox = ConfigBox()
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var stack: ListenStack?
    /// Loudness of Kobi's voice and of the mic during a command, for the orb.
    @ObservationIgnored private(set) var speakLevel: AudioLevel?
    var micLevel: AudioLevel? { stack?.listener.level }
    @ObservationIgnored private let watch = SystemWatch()
    @ObservationIgnored private var hotkeyTap: HotkeyTap?
    @ObservationIgnored private var micInUse = false
    @ObservationIgnored private(set) var historyStore: HistoryStore?
    @ObservationIgnored private var pluginLink: PluginLink?
    @ObservationIgnored private var lastPluginCheck: Date?
    /// Lines that are replays or test lines: said again, never saved again.
    @ObservationIgnored private var unrecorded: Set<UUID> = []
    /// An app is full screen (and the setting isn't "speak as usual").
    @ObservationIgnored private var fullScreenNow = false
    /// Sessions `claude agents` lists: the plugin is silent while /voice is off or muted.
    @ObservationIgnored private var directorySessions = 0
    @ObservationIgnored private var lastDirectoryCheck: Date?
    @ObservationIgnored private var wakeLoaded = false
    @ObservationIgnored private var lastWakeLoad: Date?
    /// Frees the wake word model once the wake word has been off or blocked for 10 minutes.
    @ObservationIgnored private var wakeUnloadTimer: Task<Void, Never>?
    @ObservationIgnored private var wakeUnloading: Task<Void, Never>?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    /// The answer to a refused hold (closed chime or mic prompt), once it is a real hold.
    @ObservationIgnored private var refusedHold: Task<Void, Never>?
    @ObservationIgnored private var bannerPoster: BannerPoster?

    static let muteFile = URL.kobiDir.appending(path: "mute")

    var menuIcon: MenuIcon.State {
        if mutedUntil != nil { return .muted }
        switch listenPhase {
        case .capturing, .transcribing: return .active
        default: break
        }
        if thinking { return .active }
        switch speechState {
        case .speaking: return .active
        case .holding: return .holding
        case .idle: return listenPhase == .waiting ? .ready : .idle
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let box = configBox
        let live = KobiCore.live { box.value }
        let history = HistoryStore(keep: { box.value.history })
        historyStore = history
        Task { for await list in await history.changes() { self.history = list } }
        Task {
            for await e in await live.core.speech.lineEvents() {
                if case .started(let line) = e {
                    caption = OrbCaption(kind: .saying, text: line.text)
                    await record(line)
                }
            }
        }
        core = live.core
        live.core.dismissals.set(dismissals)
        ducker = live.ducker
        mic = live.mic
        speakLevel = live.speakLevel
        readMute()
        // The terminal (/kobi mute) can change the mute file at any time.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.readMute()
            }
        }
        let book = live.core.approvals
        let poster = BannerPoster(
            clicked: { [weak self] session in self?.openActivity(session: session) },
            approvals: { await book.current },
            answer: { [weak self] id, session, allow in self?.answer(approvalID: id, session: session, allow: allow) })
        bannerPoster = poster
        Task {
            await live.core.banners.connect(show: { poster.show($0) }, remove: { poster.remove($0) })
            notificationsDenied = await BannerPoster.denied()
            notificationsUndecided = await BannerPoster.undecided()
        }
        // Locked or asleep is away; coming back after 10 minutes or more may say a recap.
        Task {
            var away = false
            for await s in watch.changes() {
                let now = s.locked || s.asleep
                if now, !away { await live.core.wentAway() }
                if !now, away { await live.core.cameBack(speak: box.value.recap && !Self.muteActive()) }
                away = now
            }
        }
        Task {
            fullScreenNow = await live.fullScreen.isBusy
            for await busy in live.fullScreen.changes() {
                fullScreenNow = busy
                await listeningChanged()
            }
        }
        Task {
            do { try await live.core.start() } catch { startError = "Couldn't open the plugin socket: \(error)" }
            // Kokoro takes about 12 s to load cold, so load it before the first line.
            await live.synth.prepare()
        }
        Task { for await list in await live.core.sessions.changes() { knownRaw = list; applyDismissals(); await listeningChanged() } }
        // While a session works, Kokoro stays loaded, so the line that ends a long turn isn't a cold load.
        Task { for await list in await live.core.sessions.changes() { await live.synth.sessionsWorking(list.contains { $0.state == .working }) } }
        Task {
            for await list in await live.core.approvals.changes() {
                approvals = list
                // A banner posted before its prompt arrived gets Allow and Deny now.
                poster.approvalsChanged()
            }
        }
        Task { for await s in await live.core.speech.stateChanges() { speechState = s; updateActivity() } }
        Task {
            let stack = await ListenStack.live(core: live.core, history: history) { box.value }
            self.stack = stack
            // Claude Code may be installed after launch: each check looks for it until it is found.
            let claude = stack.claude
            pluginLink = PluginLink(find: { await claude.locate() == nil ? nil : claude })
            await checkPlugin(force: true)
            Task {
                for await s in await stack.models.changes() {
                    let shown = modelState.showing(s)
                    guard shown != modelState else { continue }
                    modelState = shown
                    await listeningChanged()
                }
            }
            Task {
                for await p in await stack.listener.phaseChanges() {
                    if case .capturing = p, listenPhase != p { caption = .listening }
                    listenPhase = p
                    updateActivity()
                }
            }
            Task { for await text in await stack.loop.heardLines() { caption = OrbCaption(kind: .heard, text: text) } }
            Task {
                for await r in await stack.dispatcher.receipts() {
                    // A receipt for an older send never replaces a newer one's line.
                    if let kept = receipts[r.session], kept.sent > r.sent { continue }
                    receipts[r.session] = r
                    // The card has said what became of the answer: let it go shortly.
                    if let at = answered[r.session], r.sent >= at { releaseCard(r.session, at, after: .seconds(4)) }
                }
            }
            Task { for await t in await stack.loop.thinkingChanges() { thinking = t; updateActivity() } }
            Task { for await _ in watch.changes() { await listeningChanged() } }
            // A session opened while the plugin is silent arms the wake word within a minute.
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(60))
                    if listenBlock == .noSessions { await listeningChanged() }
                }
            }
            Task {
                for await busy in live.mic.changes() {
                    micInUse = busy
                    micApp = busy ? micAppName() : nil
                    await stack.listener.setMicBusy(busy)
                    await listeningChanged()
                }
            }
            await listeningChanged()
        }
        // Actions before the stack exists are ignored (hotkey(_:) checks it).
        hotkeyTap = HotkeyTap(hotkey: configBox.value.hotkey) { [weak self] action in self?.hotkey(action) }
        // Creating the tap can show the Input Monitoring prompt, so wait for onboarding when not allowed yet.
        hotkeyAllowed = HotkeyTap.allowed ? (hotkeyTap?.start() ?? false) : false
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    /// Closes the socket and removes the tap at once, so other apps never stay quiet.
    func shutdown() {
        core?.stop()
        guard let ducker else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await ducker.shutdown()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: Settings

    func save(_ change: (inout KobiConfig) -> Void) {
        var c = KobiConfig.load()
        change(&c)
        try? c.save()
        config = c
        Task {
            await historyStore?.settingChanged()
            await listeningChanged()
        }
    }

    func reloadConfig() { config = configBox.value }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            // register() can throw yet leave the item waiting for approval; the status below says which.
            launchAtLoginError = "Couldn't change it: \(error.localizedDescription)"
        }
        readLaunchAtLogin()
    }

    /// Re-reads the login item, which you can approve or remove in System Settings.
    private func readLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        let on = status == .enabled || status == .requiresApproval
        if on != launchAtLogin { launchAtLogin = on }
        let waiting = status == .requiresApproval
        if waiting != launchAtLoginNeedsApproval { launchAtLoginNeedsApproval = waiting }
        if waiting, launchAtLoginError != nil { launchAtLoginError = nil }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// A line that is not saved in the history. `voice` says it in that Kokoro voice (a preview).
    func playTestLine(_ text: String = "This is how Kobi sounds.", voice: String? = nil) {
        guard let core else { return }
        let line = SpokenLine(text: text, kind: .roll, session: "", voice: voice)
        unrecorded.insert(line.id)
        Task { await core.speech.enqueue(line) }
    }

    // MARK: History

    /// Says it again: Kobi's line, or its reply to what you said.
    func replay(_ e: HistoryEntry) {
        let text = e.kind == .said ? e.text : (e.reply ?? e.text)
        playTestLine(text)
    }

    func clearHistory() { Task { await historyStore?.clear() } }

    /// A click on a banner: the Activity window, on the banner's session.
    func openActivity(session: String? = nil) {
        activityPage = session.map { .session($0) } ?? .brief
        activityRequests += 1
    }

    // MARK: Session view

    /// One name per session everywhere in Activity: the plugin's, then the name
    /// today's lines used, then Claude Code's own label.
    func displayName(_ id: String) -> String {
        ActivitySessions(known: sessions.map(ActivitySessions.Known.init),
                         live: liveSessions.map(ActivitySessions.Live.init), history: history).displayName(id)
    }

    /// A session as Claude Code lists it: its process, folder and kind.
    func liveSession(_ id: String) -> LiveSession? { liveSessions.first { $0.id == id } }

    /// The session's last turns and any question it left open, read from its
    /// transcript off the main thread. Nil when there is no transcript to read.
    /// A file that hasn't changed since the last read is not read again.
    func transcript(for id: String) async -> SessionTranscript.Recent? {
        let cwd = liveSession(id)?.cwd ?? ""
        let cached = transcripts[id]
        let (stamp, recent) = await Task.detached(priority: .userInitiated) { () -> (TranscriptStamp?, SessionTranscript.Recent?) in
            guard let url = SessionTranscript.file(sessionID: id, cwd: cwd),
                  let a = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                // A background session keeps notes in its job folder instead.
                return (nil, SessionTranscript.job(sessionID: id))
            }
            let stamp = TranscriptStamp(modified: a[.modificationDate] as? Date, size: a[.size] as? Int)
            if let cached, cached.stamp == stamp { return (stamp, cached.recent) }
            return (stamp, SessionTranscript.recent(url, limit: 30))
        }.value
        if let stamp, let recent { transcripts[id] = (stamp, recent) }
        return recent
    }

    struct TranscriptStamp: Equatable, Sendable {
        let modified: Date?
        let size: Int?
    }
    @ObservationIgnored private var transcripts: [String: (stamp: TranscriptStamp, recent: SessionTranscript.Recent)] = [:]

    // MARK: Dismissing a wait

    private static let dismissalsKey = "dismissedWaits"

    private static func loadDismissals() -> Dismissals {
        guard let data = UserDefaults.standard.data(forKey: dismissalsKey),
              let d = try? JSONDecoder().decode(Dismissals.self, from: data) else { return Dismissals() }
        return d
    }

    /// Saves them, and hands them to the kit, so the roll call and the recap read them too.
    private func saveDismissals() {
        UserDefaults.standard.set(try? JSONEncoder().encode(dismissals), forKey: Self.dismissalsKey)
        core?.dismissals.set(dismissals)
    }

    /// Takes a waiting session off Waiting on You, the recap, the roll call and
    /// the panel until it asks something new. It is not stopped and nothing is
    /// sent. Its held "needs you" lines and its banner go, as for an answered wait.
    func dismiss(_ id: String) {
        dismissals.dismiss(id)
        saveDismissals()
        applyDismissals()
        guard let core else { return }
        Task {
            await core.speech.sessionAnswered(id)
            await core.banners.sessionChanged(id, to: .open)
        }
    }

    /// Puts a dismissed session back on Waiting on You.
    func restore(_ id: String) {
        dismissals.restore(id)
        saveDismissals()
        applyDismissals()
    }

    /// Recomputes both lists from their sources. Set only on a change, as
    /// setting the same value still redraws every view that reads it.
    private func applyDismissals() {
        // Only once Claude Code's list is in: at launch an empty list proves nothing.
        if liveLoaded, dismissals.prune(known: knownRaw, live: liveRaw) { saveDismissals() }
        let known = knownRaw.map { dismissals.apply($0) }
        let live = liveRaw.map { dismissals.apply($0) }
        if known != sessions { sessions = known }
        if live != liveSessions { liveSessions = live }
    }

    /// What you typed in the session view, sent to that session. Returns the
    /// line Kobi would have said ("Sent to blog.", "Queued. Blog will see it when it finishes.").
    /// What became of it arrives later in `receipts`. `answering` is a waiting
    /// card's answer: the brief keeps that card up until the receipt.
    func send(_ text: String, toSession id: String, answering: Bool = false) async -> String {
        guard let stack else { return "Kobi is still starting." }
        let at = Date()
        if answering { answered[id] = at }
        let line = await stack.dispatcher.send(typed: text, toSession: id).line ?? ""
        // A "Sent to" receipt comes within seconds: keep the card 10 seconds at most. A queued
        // reply's receipt can take minutes, and one still waiting on your OK has none.
        if answering { releaseCard(id, at, after: line.hasPrefix("Sent") ? .seconds(10) : .zero) }
        return line
    }

    private func releaseCard(_ id: String, _ at: Date, after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.answered[id] == at else { return }
            self.answered[id] = nil
        }
    }

    /// The receipt for a send made at or after `since`, when it has a line to show.
    func receiptLine(for id: String, since: Date?) -> String? {
        guard let since, let r = receipts[id], r.sent >= since else { return nil }
        return r.line
    }

    /// The app a session's window is in ("Terminal", "Otty"), for button titles.
    func hostName(_ id: String) -> String {
        guard let s = liveSession(id), !s.isBackground, let pid = s.pid else { return "Terminal" }
        return TerminalHost.hostApp(of: pid)?.localizedName ?? "Terminal"
    }

    /// Brings the session's own window forward. Returns a line when that fails.
    func openInTerminal(_ id: String) -> String? {
        guard let s = liveSession(id) else { return "Claude Code doesn't list this session any more." }
        if case .failed(let why) = TerminalHost.open(s, claude: stack?.claudePath) { return why }
        return nil
    }

    /// Re-reads whether notifications are allowed, which changes in System Settings.
    func refreshNotifications() {
        Task {
            notificationsDenied = await BannerPoster.denied()
            notificationsUndecided = await BannerPoster.undecided()
            notificationsChecked = true
        }
    }

    /// Asks for notifications now (onboarding), rather than the first time a
    /// banner is needed, which is often mid-call.
    func requestNotifications() async {
        await BannerPoster.ask()
        notificationsDenied = await BannerPoster.denied()
        notificationsUndecided = await BannerPoster.undecided()
        notificationsChecked = true
    }

    /// The notifications button: the macOS prompt the first time, then
    /// Kobi's page in System Settings, Notifications, since macOS asks only once.
    func allowNotifications() {
        guard notificationsDenied else {
            Task { await requestNotifications() }
            return
        }
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A line Kobi started saying. Replies to what you said are saved with
    /// it by the voice loop, so confirm lines are skipped here.
    private func record(_ line: SpokenLine) async {
        if unrecorded.remove(line.id) != nil { return }
        guard line.kind != .confirm else { return }
        let name = line.name ?? sessionName(line.session)
        await historyStore?.add(HistoryEntry(kind: .said, text: line.text, session: line.session.isEmpty ? nil : line.session,
                                             sessionName: name, lineKind: line.kind))
    }

    /// A session's spoken name from the plugin's statuses, or from `claude agents`.
    func sessionName(_ id: String) -> String? {
        sessions.first { $0.id == id }?.name ?? liveSessions.first { $0.id == id }?.name
    }

    /// The last thing Kobi said about this session, for the panel.
    func lastLine(for session: String) -> HistoryEntry? {
        history.last { $0.kind == .said && $0.session == session }
    }

    // MARK: Approvals

    /// Allow or Deny clicked on a prompt's row: written like a spoken answer.
    /// A prompt already answered on screen just leaves the list.
    func answer(_ approval: OpenApproval, allow: Bool) {
        guard let stack else { return }
        approvals.removeAll { $0.id == approval.id }
        Task { await stack.loop.click(approval.id, allow: allow) }
    }

    /// Allow or Deny pressed on a banner: answers that one prompt the same way.
    /// A prompt already answered or gone is left alone.
    func answer(approvalID id: String, session: String, allow: Bool) {
        guard let a = BannerApproval.target(id: id, session: session, open: approvals) else { return }
        answer(a, allow: allow)
    }

    /// Drops the rows of prompts whose hook is gone (killed without saying so).
    func refreshApprovals() {
        guard let core else { return }
        Task { _ = await core.approvals.current }
    }

    // MARK: Listening

    /// Applies the current settings and system state: whether the wake word
    /// listens, what the menu says, and whether approvals are taken.
    func listeningChanged() async {
        guard let stack else { return }
        let c = configBox.value
        // Asked off the main thread: each answer is a round trip to tccd (15 ms was
        // seen), and this runs on every session status.
        let mic = await Task.detached { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }.value
        if mic != micAllowed { micAllowed = mic }
        var i = listenInputs(c)
        core?.availability.canListen = ListenPolicy.canListen(i)
        // Locked, asleep or without the mic: no approval window or hotkey may open it.
        await stack.listener.setBlocked(ListenPolicy.commandBlock(i) != nil)
        // At most once a minute (a failing `claude agents` is not cached by the directory),
        // every 3 minutes in Low Power Mode, and not while locked or asleep: coming back
        // changes the watch's state, which runs this again.
        let w = watch.state
        if stack.claudePath != nil,
           Cadence.directoryRefreshDue(last: lastDirectoryCheck, locked: w.locked, asleep: w.asleep, lowPower: w.lowPower) {
            lastDirectoryCheck = Date()
            refreshDirectory(stack, floor: Cadence.directoryRefresh(locked: w.locked, asleep: w.asleep, lowPower: w.lowPower) ?? 60)
        }
        let live = await stack.directory.sessions
        directorySessions = live.count
        if live != liveRaw || !liveLoaded { liveRaw = live; liveLoaded = true; applyDismissals() }
        i = listenInputs(c)
        // Set only on a change: setting the same value still redraws every view that reads it.
        let block = ListenPolicy.wakeBlock(i)
        if block != listenBlock { listenBlock = block }
        hotkeyTap?.setHotkey(c.hotkey)
        await stack.listener.setSensitivity(c.wakeSensitivity)
        // A new mic choice applies now, even while the wake word holds the mic open.
        await stack.listener.setInputDevice(c.inputDevice)
        // Retry a failed load at most once a minute.
        if listenBlock == nil, !wakeLoaded, lastWakeLoad.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            lastWakeLoad = Date()
            await wakeUnloading?.value   // an unload still running must not undo this load
            wakeLoaded = await stack.loadWakeModels()
            wakeLoadFailed = !wakeLoaded
        }
        // The load took a while: arm from the state now, not the state before it.
        let now = listenInputs(configBox.value)
        let blocked = ListenPolicy.commandBlock(now)
        if blocked != commandBlock { commandBlock = blocked }
        await stack.listener.setBlocked(blocked != nil)
        let fresh = ListenPolicy.wakeBlock(now)
        if fresh != listenBlock { listenBlock = fresh }
        await stack.listener.setWakeArmed(fresh == nil && wakeLoaded)
        scheduleWakeUnload(blocked: fresh != nil)
    }

    /// Asks `claude agents` for the session list in a task of its own, so no caller of
    /// listeningChanged waits for it (it can take seconds). Applies the result when the count changed.
    private func refreshDirectory(_ stack: ListenStack, floor: TimeInterval) {
        Task {
            await stack.directory.refresh(ifOlderThan: floor)
            let live = await stack.directory.sessions
            if live != liveRaw || !liveLoaded { liveRaw = live; liveLoaded = true; applyDismissals() }
            let count = live.count
            if count != directorySessions {
                directorySessions = count
                await listeningChanged()
            }
        }
    }

    /// The spotter and its share of the CTC model stay loaded only while the wake
    /// word may listen, plus 10 minutes. The VAD stays: follow-ups need it.
    private func scheduleWakeUnload(blocked: Bool) {
        guard blocked else { wakeUnloadTimer?.cancel(); wakeUnloadTimer = nil; return }
        guard wakeLoaded, wakeUnloadTimer == nil, let stack else { return }
        wakeUnloadTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self else { return }
            self.wakeUnloadTimer = nil
            guard self.listenBlock != nil, self.wakeLoaded else { return }
            self.wakeLoaded = false
            let unloading = Task { await stack.unloadWakeModels() }
            self.wakeUnloading = unloading
            await unloading.value
            if self.wakeUnloading == unloading { self.wakeUnloading = nil }
        }
    }

    private func listenInputs(_ c: KobiConfig) -> ListenInputs {
        var i = ListenInputs()
        i.micAllowed = micAllowed
        i.modelsReady = modelState == .ready
        if case .downloading(let p) = modelState { i.modelProgress = p }
        i.wakeWord = c.wakeWord
        i.battery = c.wakeOnBattery
        i.onBattery = watch.state.onBattery
        i.lowPower = watch.state.lowPower
        i.locked = watch.state.locked
        i.asleep = watch.state.asleep
        i.micInUse = micInUse
        i.liveSessions = max(sessions.count, directorySessions)
        i.hotkey = c.hotkey
        i.fullScreenSilent = c.fullScreen == .silent && fullScreenNow
        return i
    }

    private func hotkey(_ action: HotkeyDetector.Action) {
        guard let listener = stack?.listener else { return }
        switch action {
        case .down:
            var i = ListenInputs()
            i.micAllowed = micAllowed; i.modelsReady = modelState == .ready; i.micInUse = micInUse
            i.locked = watch.state.locked; i.asleep = watch.state.asleep
            i.fullScreenSilent = configBox.value.fullScreen == .silent && fullScreenNow
            if let block = ListenPolicy.commandBlock(i) {
                // Refused, but not silently: the closed chime, or the mic prompt the first time.
                refuseHold(askForMic: block == .micPermission && Self.micUnasked)
                return
            }
            // Secure input may hide key presses from the tap, so a chord could look like a hold.
            if IsSecureEventInputEnabled() {
                secureInput = true
                refuseHold(askForMic: false)
                return
            }
            Task { await listener.hotkeyDown() }
        case .up:
            refusedHold?.cancel()
            Task { await listener.hotkeyUp() }
        case .cancel:
            refusedHold?.cancel()
            Task { await listener.hotkeyCancel() }
        }
    }

    /// A hotkey press Kobi can't take. Only a real hold gets an answer, after the
    /// minimum hold, since a quick tap or a chord (Option with a letter) is not a command.
    private func refuseHold(askForMic: Bool) {
        refusedHold?.cancel()
        refusedHold = Task { [weak self, stack] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            if askForMic { await self?.requestMic() } else { await stack?.play(.closed) }
        }
    }

    /// The name of the app capturing from the mic, for the "not listening" line.
    private func micAppName() -> String? {
        guard let id = mic?.appsUsingMic().first(where: { $0.counts && !$0.bundleID.isEmpty })?.bundleID else { return nil }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Why Kobi isn't listening, naming the app that holds the mic when it can.
    func blockLine(_ b: ListenBlock) -> String { ListenPolicy.menuLine(b, micApp: micApp) }

    /// Clicking the orb: one command, as after "Hey Kobi". Refused like the
    /// hotkey when Kobi can't listen now; the closed chime says so, and the
    /// first time without the mic, macOS asks for it.
    func tapToTalk() {
        guard let stack else { return }
        let i = listenInputs(configBox.value)
        if let block = ListenPolicy.commandBlock(i) {
            if block == .micPermission, Self.micUnasked {
                Task { await requestMic() }
            } else {
                Task { await stack.play(.closed) }
            }
            return
        }
        Task { await stack.listener.tapToTalk() }
    }

    // MARK: Claude Code plugin

    /// Asks Claude Code again, at most once a minute unless forced. While
    /// `claude` is not found, each check looks for it again.
    func checkPlugin(force: Bool = false) async {
        guard let pluginLink, !pluginWorking else { return }
        if !force, let last = lastPluginCheck, Date().timeIntervalSince(last) < 60 { return }
        lastPluginCheck = Date()
        let hadClaude = stack?.claudePath != nil
        pluginStatus = await pluginLink.check()
        if !hadClaude, stack?.claudePath != nil { await listeningChanged() }   // sessions can be listed now
    }

    /// The plugin row's button: look again for Claude Code or its plugin list,
    /// or install, turn on, or update the plugin, whichever it needs.
    func fixPlugin() {
        if pluginStatus.actionRechecks { recheckPlugin() } else { connectPlugin() }
    }

    private func recheckPlugin() {
        guard let pluginLink, !pluginWorking else { return }
        pluginWorking = true
        pluginWorkLine = "Checking Claude Code\u{2026}"
        Task {
            let hadClaude = stack?.claudePath != nil
            pluginStatus = await pluginLink.check()
            lastPluginCheck = Date()
            pluginWorking = false
            if !hadClaude, stack?.claudePath != nil { await listeningChanged() }
        }
    }

    private func connectPlugin() {
        guard let pluginLink, !pluginWorking else { return }
        pluginWorking = true
        pluginWorkLine = "Installing through Claude Code\u{2026}"
        Task {
            pluginStatus = await pluginLink.connect()
            lastPluginCheck = Date()
            pluginWorking = false
        }
    }

    /// Asks for the mic the first time. Once you answered, macOS shows nothing
    /// again, so this opens the Microphone pane of System Settings instead.
    func requestMic() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .authorized: break
        default: Self.openPrivacyPane("Privacy_Microphone")
        }
        micDenied = Self.micAnsweredNo
        await listeningChanged()
    }

    /// The same for Input Monitoring: the prompt once, then System Settings.
    func requestHotkeyAccess() {
        if HotkeyTap.denied {
            Self.openPrivacyPane("Privacy_ListenEvent")
        } else {
            HotkeyTap.requestAccess()
        }
        hotkeyAllowed = hotkeyTap?.start() ?? false
        hotkeyDenied = HotkeyTap.denied
    }

    /// What a permission button says: macOS asks only once, so after that it opens System Settings.
    static func permissionAction(denied: Bool, ask: String = "Allow\u{2026}") -> String {
        denied ? "Open System Settings" : ask
    }

    private static var micUnasked: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }

    private static var micAnsweredNo: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Re-reads the mic and Input Monitoring permissions, which change in System
    /// Settings, and whether another app has secure keyboard entry on.
    func refreshPermissions() {
        readLaunchAtLogin()
        readMute()
        let secure = IsSecureEventInputEnabled()
        if secure != secureInput { secureInput = secure }
        var changed = false
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if mic != micAllowed { micAllowed = mic; changed = true }
        let micNo = Self.micAnsweredNo
        if micNo != micDenied { micDenied = micNo }
        var hot = HotkeyTap.allowed
        if hot { hot = hotkeyTap?.start() ?? false }
        if hot != hotkeyAllowed { hotkeyAllowed = hot; changed = true }
        let hotNo = !hot && HotkeyTap.denied
        if hotNo != hotkeyDenied { hotkeyDenied = hotNo }
        if changed { Task { await listeningChanged() } }
    }

    func downloadModels() {
        guard let stack else { return }
        Task { await stack.models.download() }
    }

    /// No App Nap while the mic is open or Kobi speaks: a napping process
    /// delays the audio work.
    private func updateActivity() {
        let busy = listenPhase != .off || speechState == .speaking || thinking
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Listening or speaking")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: Mute

    func mute(for interval: TimeInterval) {
        let text = MuteFile.text(until: Date().addingTimeInterval(interval))
        try? FileManager.default.createDirectory(at: .kobiDir, withIntermediateDirectories: true)
        try? text.write(to: Self.muteFile, atomically: true, encoding: .utf8)
        setMuted(MuteFile.until(text))
    }

    /// Until you unmute: an empty mute file, which the plugin reads the same way.
    func muteUntilUnmuted() {
        try? FileManager.default.createDirectory(at: .kobiDir, withIntermediateDirectories: true)
        try? "".write(to: Self.muteFile, atomically: true, encoding: .utf8)
        setMuted(.distantFuture)
    }

    func muteUntilTomorrow() {
        let cal = Calendar.current
        let morning = cal.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(12 * 3600)
        mute(for: morning.timeIntervalSinceNow)
    }

    func unmute() {
        try? FileManager.default.removeItem(at: Self.muteFile)
        setMuted(nil)
    }

    /// The mute file says muted now, read the way the plugin reads it, so a
    /// mute set from the terminal counts too.
    static func muteActive() -> Bool {
        MuteFile.until(try? String(contentsOf: muteFile, encoding: .utf8)) != nil
    }

    /// Shows what the mute file says now. A mute that ran out is left in place:
    /// the plugin reads it as not muted too, and removing it could remove a newer one.
    private func readMute() {
        let until = MuteFile.until(try? String(contentsOf: Self.muteFile, encoding: .utf8))
        if until != mutedUntil { setMuted(until) }
    }

    private func setMuted(_ until: Date?) {
        mutedUntil = until
        muteTimer?.invalidate()
        muteTimer = nil
        guard let until, until != .distantFuture else { return }
        // At the end, the file is read again: a mute set meanwhile (from the terminal) stays.
        muteTimer = Timer.scheduledTimer(withTimeInterval: max(until.timeIntervalSinceNow, 0) + 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.readMute() }
        }
    }

    // MARK: Diagnostics

    func diagnostics() async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let events = await core?.events.recent ?? []
        let duckError = await ducker?.lastError
        let micApps = mic?.appsUsingMic().map { "\($0.bundleID.isEmpty ? "(no ID)" : $0.bundleID) \($0.counts ? "counts" : "ignored")" } ?? []
        let c = configBox.value
        return """
        Kobi \(ver)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Engine: \(c.engine.rawValue), level \(c.level), style \(c.style)
        Full screen: \(c.fullScreen.rawValue), orb \(c.showOrb ? c.orbColor.rawValue : "off")
        Recap: \(c.recap ? "on" : "off"), banners \(c.banner ? "on" : "off")\(notificationsDenied ? " (notifications not allowed)" : "")
        Lower other audio: \(c.duckEnabled ? "on, \(Int(c.duckLevel * 100))%" : "off")\(duckError.map { ", last error \($0)" } ?? "")
        Kokoro models: \(KokoroEngine.modelsPresent ? "present" : "missing")
        Sessions: \(sessions.count)
        Mic in use by: \(micApps.isEmpty ? "nothing" : micApps.joined(separator: ", "))
        Listening: \(listenPhase), \(listenBlock.map { ListenPolicy.menuLine($0) } ?? "wake word armed")
        Wake word: \(c.wakeWord ? "on" : "off"), sensitivity \(c.wakeSensitivity), battery rule \(c.wakeOnBattery.rawValue)
        Hotkey: \(c.hotkey.rawValue), Input Monitoring \(hotkeyAllowed ? "allowed" : "not allowed")
        Mic permission: \(micAllowed ? "allowed" : "not allowed")
        Speech models: \(modelState)
        claude: \(stack?.claudePath ?? "not found")
        Plugin: \(pluginStatus.line)
        Recent events:
        \(events.joined(separator: "\n"))
        """
    }

    func copyDiagnostics() {
        Task {
            let text = await diagnostics()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// The config the speech engines read. Reads the file again when it changed
/// on disk, so settings saved here or by the plugin's setup apply to the next line.
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cached = KobiConfig(text: "")
    private var stamp: Date?

    var value: KobiConfig {
        lock.withLock {
            let modified = (try? FileManager.default.attributesOfItem(atPath: URL.kobiConfig.path))?[.modificationDate] as? Date
            if modified != stamp || stamp == nil {
                cached = KobiConfig.load()
                stamp = modified
            }
            return cached
        }
    }
}
