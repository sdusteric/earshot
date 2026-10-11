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
    var speechState: SpeechOut.State = .idle
    var listenPhase: Listener.Phase = .off
    var listenBlock: ListenBlock?
    var modelState: ListenModels.State = ListenModelFiles.present ? .ready : .missing
    var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var hotkeyAllowed = HotkeyTap.allowed
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
    @ObservationIgnored private let watch = SystemWatch()
    @ObservationIgnored private var hotkeyTap: HotkeyTap?
    @ObservationIgnored private var micInUse = false
    @ObservationIgnored private var wakeLoaded = false
    @ObservationIgnored private var lastWakeLoad: Date?
    /// Frees the wake word model once the wake word has been off or blocked for 10 minutes.
    @ObservationIgnored private var wakeUnloadTimer: Task<Void, Never>?
    @ObservationIgnored private var wakeUnloading: Task<Void, Never>?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    static let muteFile = URL.earshotDir.appending(path: "mute")

    var menuIcon: String {
        if mutedUntil != nil { return "speaker.slash" }
        switch listenPhase {
        case .capturing: return "mic.fill"
        case .transcribing: return "ellipsis.circle"
        default: break
        }
        switch speechState {
        case .speaking: return "waveform"
        case .holding: return "pause.circle"
        case .idle: return listenPhase == .waiting ? "ear.badge.waveform" : "ear"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let box = configBox
        let live = EarshotCore.live { box.value }
        core = live.core
        ducker = live.ducker
        mic = live.mic
        readMute()
        Task {
            do { try await live.core.start() } catch { startError = "Couldn't open the plugin socket: \(error)" }
            // Kokoro takes about 12 s to load cold, so load it before the first line.
            await live.synth.prepare()
        }
        Task { for await list in await live.core.sessions.changes() { sessions = list; await listeningChanged() } }
        Task { for await s in await live.core.speech.stateChanges() { speechState = s; updateActivity() } }
        Task {
            let stack = await ListenStack.live(core: live.core) { box.value }
            self.stack = stack
            Task { for await s in await stack.models.changes() { modelState = s; await listeningChanged() } }
            Task { for await p in await stack.listener.phaseChanges() { listenPhase = p; updateActivity() } }
            Task { for await _ in watch.changes() { await listeningChanged() } }
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
        Task { await listeningChanged() }
    }

    func reloadConfig() { config = configBox.value }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func playTestLine() {
        guard let core else { return }
        Task { await core.speech.enqueue(SpokenLine(text: "This is how Earshot sounds.", kind: .roll, session: "")) }
    }

    // MARK: Listening

    /// Applies the current settings and system state: whether the wake word
    /// listens, what the menu says, and whether approvals are taken.
    func listeningChanged() async {
        guard let stack else { return }
        let c = configBox.value
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let i = listenInputs(c)
        core?.availability.canListen = ListenPolicy.canListen(i)
        // Locked, asleep or without the mic: no approval window or hotkey may open it.
        await stack.listener.setBlocked(ListenPolicy.commandBlock(i) != nil)
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
        i.liveSessions = sessions.count
        i.hotkey = c.hotkey
        return i
    }

    private func hotkey(_ action: HotkeyDetector.Action) {
        guard let listener = stack?.listener else { return }
        switch action {
        case .down:
            var i = ListenInputs()
            i.micAllowed = micAllowed; i.modelsReady = modelState == .ready; i.micInUse = micInUse
            i.locked = watch.state.locked; i.asleep = watch.state.asleep
            guard ListenPolicy.commandBlock(i) == nil else { return }
            // Secure input may hide key presses from the tap, so a chord could look like a hold.
            guard !IsSecureEventInputEnabled() else { return }
            Task { await listener.hotkeyDown() }
        case .up: Task { await listener.hotkeyUp() }
        case .cancel: Task { await listener.hotkeyCancel() }
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

    /// Re-reads the mic and Input Monitoring permissions, which change in System Settings.
    func refreshPermissions() {
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

    func unmute() {
        try? FileManager.default.removeItem(at: Self.muteFile)
        setMuted(nil)
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
