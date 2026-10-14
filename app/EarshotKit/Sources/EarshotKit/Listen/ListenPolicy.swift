/// What decides whether Earshot may open the mic.
public struct ListenInputs: Sendable, Equatable {
    public var micAllowed = false
    public var modelsReady = false
    /// 0 to 1 while the models download.
    public var modelProgress: Double?
    public var wakeWord = false
    public var battery: EarshotConfig.WakeBattery = .lowpower
    public var onBattery = false
    public var lowPower = false
    /// Open Claude Code sessions: as many as the plugin or `claude agents` knows, whichever is more.
    public var liveSessions = 0
    public var locked = false
    public var asleep = false
    /// Another app captures from the mic (a call, dictation).
    public var micInUse = false
    public var hotkey: EarshotConfig.Hotkey = .rightOption
    /// An app is full screen and the setting says to stay silent then.
    public var fullScreenSilent = false

    public init() {}
}

public enum ListenBlock: Sendable, Equatable {
    case micPermission
    case models(Double?)
    case wakeOff
    case asleep
    case locked
    case micInUse
    case fullScreen
    case lowPower
    case battery
    case noSessions
}

/// Stage 0 of the cascade. Pure, so the menu and the listener agree.
public enum ListenPolicy {
    /// Why the wake word may not listen now, or nil when it may. The order
    /// is the order the menu explains it in: the first reason wins.
    public static func wakeBlock(_ i: ListenInputs) -> ListenBlock? {
        if let b = commonBlock(i) { return b }
        if !i.wakeWord { return .wakeOff }
        if i.battery == .lowpower, i.lowPower { return .lowPower }
        if i.battery == .power, i.onBattery { return .battery }
        if i.liveSessions == 0 { return .noSessions }
        return nil
    }

    /// Why a command after the hotkey, or a follow-up answer, cannot be heard now.
    public static func commandBlock(_ i: ListenInputs) -> ListenBlock? { commonBlock(i) }

    /// For approvals: the app takes a prompt only when it could hear the answer.
    public static func canListen(_ i: ListenInputs) -> Bool {
        commandBlock(i) == nil && (i.wakeWord || i.hotkey != .off)
    }

    private static func commonBlock(_ i: ListenInputs) -> ListenBlock? {
        if !i.micAllowed { return .micPermission }
        if !i.modelsReady { return .models(i.modelProgress) }
        if i.asleep { return .asleep }
        if i.locked { return .locked }
        if i.micInUse { return .micInUse }
        if i.fullScreenSilent { return .fullScreen }
        return nil
    }

    /// Shown in the menu and in Settings while another app keeps secure input on.
    public static let secureInputLine =
        "The hotkey is paused while another app uses secure keyboard entry (for example Terminal's Secure Keyboard Entry)."

    /// `micApp` names the app holding the mic, when it is known ("Zoom").
    public static func menuLine(_ b: ListenBlock, micApp: String? = nil) -> String {
        switch b {
        case .micPermission: "Listening is off: Earshot can't use the mic. Allow it in System Settings, Privacy & Security, Microphone."
        case .models(let p):
            "Listening starts when the speech models finish downloading" + (p.map { " (\(Int($0 * 100))%)." } ?? ".")
        case .wakeOff: "The wake word is off. Hold the hotkey to talk."
        case .asleep, .locked: "Not listening while the Mac is locked."
        case .micInUse: "Not listening while \(micApp ?? "another app") uses the mic."
        case .fullScreen: "Not listening while an app is full screen."
        case .lowPower: "Not listening for the wake word in Low Power Mode."
        case .battery: "Not listening for the wake word on battery."
        case .noSessions: "Listening for the wake word once a session is open."
        }
    }
}
