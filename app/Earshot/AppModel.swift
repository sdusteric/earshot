import AppKit
import EarshotKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class AppModel {
    var sessions: [SessionInfo] = []
    var speechState: SpeechOut.State = .idle
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

    static let muteFile = URL.earshotDir.appending(path: "mute")

    var menuIcon: String {
        if mutedUntil != nil { return "speaker.slash" }
        switch speechState {
        case .speaking: return "waveform"
        case .holding: return "pause.circle"
        case .idle: return "ear"
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
        Task { for await list in await live.core.sessions.changes() { sessions = list } }
        Task { for await s in await live.core.speech.stateChanges() { speechState = s } }
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
