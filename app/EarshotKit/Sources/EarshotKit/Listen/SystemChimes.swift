import AppKit

/// Short system sounds: Earshot is listening, stopped listening, or did it.
public struct SystemChimes: Chimes {
    public init() {}

    public func play(_ chime: Chime) async {
        let name = switch chime {
        case .listening: "Tink"
        case .closed: "Pop"
        case .confirm: "Morse"
        }
        await MainActor.run { _ = NSSound(named: NSSound.Name(name))?.play() }
    }
}
