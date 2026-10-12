import AppKit

/// Short system sounds: Earshot is listening, stopped listening, or did it.
public struct SystemChimes: Chimes {
    private let output: @Sendable () -> String?

    /// `output` names the speaker, as for Earshot's voice; nil is the system output.
    public init(output: @escaping @Sendable () -> String? = { nil }) { self.output = output }

    public func play(_ chime: Chime) async {
        let name = switch chime {
        case .listening: "Tink"
        case .closed: "Pop"
        case .confirm: "Morse"
        }
        let uid = output()
        await MainActor.run {
            // A copy, so a device set here never sticks to the shared named sound.
            guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
            if let uid { sound.playbackDeviceIdentifier = NSSound.PlaybackDeviceIdentifier(uid) }
            sound.play()
        }
    }
}
