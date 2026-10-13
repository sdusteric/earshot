import AppKit
import AVFoundation
import Carbon.HIToolbox
import EarshotKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class AppModel {
    var sessions: [SessionInfo] = []
    /// What `claude agents` lists: running sessions even before the plugin reports them.
    var liveSessions: [LiveSession] = []
    /// What Earshot said and heard, oldest first (see HistoryStore).
    var history: [HistoryEntry] = []
    /// Permission prompts waiting on you, oldest first, for the Allow and Deny rows.
    var approvals: [OpenApproval] = []
    /// Whether Claude Code has the Earshot plugin, and an install under way.
    var pluginStatus: PluginStatus = .checking
    var pluginWorking = false
    /// What the Activity window shows; set before opening it from the panel.
    var activityFilter: ActivityFilter = .all
    /// Goes up when a click on a banner asks for the Activity window (see EarshotApp).
    var activityRequests = 0
    /// You turned Earshot's notifications off in System Settings.
    var notificationsDenied = false
    var speechState: SpeechOut.State = .idle
    var listenPhase: Listener.Phase = .off
    var listenBlock: ListenBlock?
    var modelState: ListenModels.State = ListenModelFiles.present ? .ready : .missing
    var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var hotkeyAllowed = HotkeyTap.allowed
    /// Another app has secure keyboard entry on, so the hotkey is refused.
    var secureInput = IsSecureEventInputEnabled()
    var wakeLoadFailed = false
    var mutedUntil: Date?
    var config = EarshotConfig.load()
    var startError: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored let updater = Updater()
    @ObservationIgnored private var core: EarshotCore?
    @ObservationIgnored private var ducker: TapDucker?
    @ObservationIgnored private var mic: MicMonitor?
    @ObservationIgnored private var muteTimer: Timer?
    @ObservationIgnored private let configBox = ConfigBox()
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var stack: ListenStack?
    /// Loudness of Earshot's voice and of the mic during a command, for the orb.
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
    /// The closed chime for a hold refused under secure input, once it is a real hold.
    @ObservationIgnored private var refusedHold: Task<Void, Never>?
    @ObservationIgnored private var bannerPoster: BannerPoster?

    static let muteFile = URL.earshotDir.appending(path: "mute")

    var menuIcon: MenuIcon.State {
        if mutedUntil != nil { return .muted }
        switch listenPhase {
        case .capturing, .transcribing: return .active
        default: break
        }
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
        let live = EarshotCore.live { box.value }
        let history = HistoryStore(keep: { box.value.history })
        historyStore = history
        Task { for await list in await history.changes() { self.history = list } }
        Task {
            for await e in await live.core.speech.lineEvents() {
                if case .started(let line) = e { await record(line) }
            }
        }
        core = live.core
        ducker = live.ducker
        mic = live.mic
        speakLevel = live.speakLevel
        readMute()
        let poster = BannerPoster { [weak self] in self?.openActivity() }
        bannerPoster = poster
        Task {
            await live.core.banners.connect(show: { await poster.show($0) }, remove: { poster.remove($0) })
            notificationsDenied = await BannerPoster.denied()
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
        Task { for await list in await live.core.sessions.changes() { sessions = list; await listeningChanged() } }
        Task { for await list in await live.core.approvals.changes() { approvals = list } }
        Task { for await s in await live.core.speech.stateChanges() { speechState = s; updateActivity() } }
        Task {
            let stack = await ListenStack.live(core: live.core, history: history) { box.value }
            self.stack = stack
            pluginLink = PluginLink(runner: stack.claudePath.map { ClaudeCLI(path: $0) })
            await checkPlugin(force: true)
            Task { for await s in await stack.models.changes() { modelState = s; await listeningChanged() } }
            Task { for await p in await stack.listener.phaseChanges() { listenPhase = p; updateActivity() } }
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

    func save(_ change: (inout EarshotConfig) -> Void) {
        var c = EarshotConfig.load()
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
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func playTestLine(_ text: String = "This is how Earshot sounds.") {
        guard let core else { return }
        let line = SpokenLine(text: text, kind: .roll, session: "")
        unrecorded.insert(line.id)
        Task { await core.speech.enqueue(line) }
    }

    // MARK: History

    /// Says it again: Earshot's line, or its reply to what you said.
    func replay(_ e: HistoryEntry) {
        let text = e.kind == .said ? e.text : (e.reply ?? e.text)
        playTestLine(text)
    }

    func clearHistory() { Task { await historyStore?.clear() } }

    /// A click on a banner: the Activity window, showing everything.
    func openActivity() {
        activityFilter = .all
        activityRequests += 1
    }

    /// Re-reads whether notifications are allowed, which changes in System Settings.
    func refreshNotifications() {
        Task { notificationsDenied = await BannerPoster.denied() }
    }

    /// A line Earshot started saying. Replies to what you said are saved with
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

    /// The last thing Earshot said about this session, for the panel.
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
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        var i = listenInputs(c)
        core?.availability.canListen = ListenPolicy.canListen(i)
        // Locked, asleep or without the mic: no approval window or hotkey may open it.
        await stack.listener.setBlocked(ListenPolicy.commandBlock(i) != nil)
        // At most once a minute: a failing `claude agents` is not cached by the directory.
        if stack.claudePath != nil, lastDirectoryCheck.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            lastDirectoryCheck = Date()
            refreshDirectory(stack)
        }
        let live = await stack.directory.sessions
        directorySessions = live.count
        if live != liveSessions { liveSessions = live }
        i = listenInputs(c)
        listenBlock = ListenPolicy.wakeBlock(i)
        hotkeyTap?.setHotkey(c.hotkey)
        await stack.listener.setSensitivity(c.wakeSensitivity)
        // Retry a failed load at most once a minute.
        if listenBlock == nil, !wakeLoaded, lastWakeLoad.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            lastWakeLoad = Date()
            await wakeUnloading?.value   // an unload still running must not undo this load
            wakeLoaded = await stack.loadWakeModels()
            wakeLoadFailed = !wakeLoaded
        }
        // The load took a while: arm from the state now, not the state before it.
        let now = listenInputs(configBox.value)
        await stack.listener.setBlocked(ListenPolicy.commandBlock(now) != nil)
        let fresh = ListenPolicy.wakeBlock(now)
        listenBlock = fresh
        await stack.listener.setWakeArmed(fresh == nil && wakeLoaded)
        scheduleWakeUnload(blocked: fresh != nil)
    }

    /// Asks `claude agents` for the session list in a task of its own, so no caller of
    /// listeningChanged waits for it (it can take seconds). Applies the result when the count changed.
    private func refreshDirectory(_ stack: ListenStack) {
        Task {
            await stack.directory.refresh(ifOlderThan: 60)
            let live = await stack.directory.sessions
            if live != liveSessions { liveSessions = live }
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

    private func listenInputs(_ c: EarshotConfig) -> ListenInputs {
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
            guard ListenPolicy.commandBlock(i) == nil else { return }
            // Secure input may hide key presses from the tap, so a chord could look like a hold.
            // Refused, but not silently: a hold past the minimum gets the closed chime.
            if IsSecureEventInputEnabled() {
                secureInput = true
                refusedHold?.cancel()
                refusedHold = Task { [stack] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    await stack?.play(.closed)
                }
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

    /// Clicking the orb: one command, as after "Hey Earshot". Refused like the
    /// hotkey when Earshot can't listen now; the closed chime says so.
    func tapToTalk() {
        guard let stack else { return }
        let i = listenInputs(configBox.value)
        guard ListenPolicy.commandBlock(i) == nil else {
            Task { await stack.play(.closed) }
            return
        }
        Task { await stack.listener.tapToTalk() }
    }

    // MARK: Claude Code plugin

    /// Asks Claude Code again, at most once a minute unless forced.
    func checkPlugin(force: Bool = false) async {
        guard let pluginLink, !pluginWorking else { return }
        if !force, let last = lastPluginCheck, Date().timeIntervalSince(last) < 60 { return }
        lastPluginCheck = Date()
        pluginStatus = await pluginLink.check()
    }

    /// Installs, turns on, or updates the plugin, whichever it needs.
    func connectPlugin() {
        guard let pluginLink, !pluginWorking else { return }
        pluginWorking = true
        Task {
            pluginStatus = await pluginLink.connect()
            lastPluginCheck = Date()
            pluginWorking = false
        }
    }

    func requestMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await listeningChanged()
    }

    func requestHotkeyAccess() {
        HotkeyTap.requestAccess()
        hotkeyAllowed = hotkeyTap?.start() ?? false
    }

    /// Re-reads the mic and Input Monitoring permissions, which change in System
    /// Settings, and whether another app has secure keyboard entry on.
    func refreshPermissions() {
        let secure = IsSecureEventInputEnabled()
        if secure != secureInput { secureInput = secure }
        var changed = false
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if mic != micAllowed { micAllowed = mic; changed = true }
        var hot = HotkeyTap.allowed
        if hot { hot = hotkeyTap?.start() ?? false }
        if hot != hotkeyAllowed { hotkeyAllowed = hot; changed = true }
        if changed { Task { await listeningChanged() } }
    }

    func downloadModels() {
        guard let stack else { return }
        Task { await stack.models.download() }
    }

    /// No App Nap while the mic is open or Earshot speaks: a napping process
    /// delays the audio work.
    private func updateActivity() {
        let busy = listenPhase != .off || speechState == .speaking
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
        let until = Date().addingTimeInterval(interval)
        try? FileManager.default.createDirectory(at: .earshotDir, withIntermediateDirectories: true)
        try? "\(Int(until.timeIntervalSince1970))\n".write(to: Self.muteFile, atomically: true, encoding: .utf8)
        setMuted(until)
    }

    /// Until you unmute: an empty mute file, which the plugin reads the same way.
    func muteUntilUnmuted() {
        try? FileManager.default.createDirectory(at: .earshotDir, withIntermediateDirectories: true)
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
        guard let text = try? String(contentsOf: muteFile, encoding: .utf8) else { return false }
        let digits = text.filter { $0.isNumber }
        if digits.isEmpty { return true }
        return Date(timeIntervalSince1970: TimeInterval(digits) ?? 0) > Date()
    }

    private func readMute() {
        guard let text = try? String(contentsOf: Self.muteFile, encoding: .utf8) else { return }
        let digits = text.filter { $0.isNumber }
        if digits.isEmpty { mutedUntil = .distantFuture; return }
        let until = Date(timeIntervalSince1970: TimeInterval(digits) ?? 0)
        if until > Date() { setMuted(until) } else { unmute() }
    }

    private func setMuted(_ until: Date?) {
        mutedUntil = until
        muteTimer?.invalidate()
        guard let until, until != .distantFuture else { return }
        muteTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.unmute() }
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
        Earshot \(ver)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Engine: \(c.engine.rawValue), level \(c.level), style \(c.style)
        Full screen: \(c.fullScreen.rawValue), orb \(c.showOrb ? c.orbColor.rawValue : "off")
        Recap: \(c.recap ? "on" : "off"), banners \(c.banner ? "on" : "off")\(notificationsDenied ? " (notifications not allowed)" : "")
        Lower other audio: \(c.duckEnabled ? "on, \(Int(c.duckLevel * 100))%" : "off")\(duckError.map { ", last error \($0)" } ?? "")
        Kokoro models: \(KokoroEngine.modelsPresent ? "present" : "missing")
        Sessions: \(sessions.count)
        Mic in use by: \(micApps.isEmpty ? "nothing" : micApps.joined(separator: ", "))
        Listening: \(listenPhase), \(listenBlock.map(ListenPolicy.menuLine) ?? "wake word armed")
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
    private var cached = EarshotConfig(text: "")
    private var stamp: Date?

    var value: EarshotConfig {
        lock.withLock {
            let modified = (try? FileManager.default.attributesOfItem(atPath: URL.earshotConfig.path))?[.modificationDate] as? Date
            if modified != stamp || stamp == nil {
                cached = EarshotConfig.load()
                stamp = modified
            }
            return cached
        }
    }
}
