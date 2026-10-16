import CoreAudio
import Darwin

/// One audio device a process takes input from, as Core Audio describes it.
struct MicDevice: Equatable, Sendable {
    /// kAudioDevicePropertyTransportType: built-in, USB, Bluetooth, virtual, aggregate.
    var transport: UInt32
    /// Its input streams, or nil when Core Audio does not answer.
    var inputStreams: Int?
    /// The active sub-devices, for an aggregate device, or nil when Core Audio
    /// does not answer (or the aggregate sits too deep to read).
    var subdevices: [MicDevice]? = nil

    /// An input device: one with input streams, virtual ones included (a call
    /// may take its mic through a loopback or noise-cancelling driver), or an
    /// aggregate that holds one. A device whose streams or sub-devices Core
    /// Audio does not list counts, so an odd driver never hides a call.
    var isMicrophone: Bool {
        switch transport {
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            guard let subdevices else { return true }
            return subdevices.contains { $0.isMicrophone }
        default:
            return (inputStreams ?? 1) > 0
        }
    }
}

/// What Core Audio says about one process: enough to tell whether it
/// captures from a microphone.
struct MicProcess: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String
    /// kAudioProcessPropertyIsRunningInput.
    var runningInput: Bool
    /// The devices it takes input from (kAudioProcessPropertyDevices, input
    /// scope), or nil when Core Audio does not answer.
    var inputDevices: [MicDevice]?

    /// Running input alone is not enough. A screen recording with system
    /// audio runs input in replayd, and an app that records system audio runs
    /// input from a process tap; both list no input device, so neither counts.
    /// Any input device counts, and so does a process whose devices Core
    /// Audio cannot list.
    var capturesMicrophone: Bool {
        guard runningInput else { return false }
        guard let inputDevices else { return true }
        return inputDevices.contains { $0.isMicrophone }
    }

    /// Captures from a microphone and is not Earshot or an always-on listener.
    func counts(ownPID: pid_t) -> Bool {
        capturesMicrophone && pid != ownPID && MicMonitor.counts(bundleID: bundleID)
    }
}
