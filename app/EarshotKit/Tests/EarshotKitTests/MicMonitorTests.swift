import CoreAudio
import Darwin
import Testing
@testable import EarshotKit

/// The mic-in-use decision, on processes shaped like what Core Audio listed
/// on macOS 27 (scratchpad probe screenmic): a screen recording with system
/// audio runs input in replayd with no input device; a system-audio tap runs
/// input with no input device; a mic app lists the microphone, and a
/// voice-processing app (FaceTime) lists the mic and the output device. A
/// call through a virtual mic lists that virtual device, and counts.
@Suite struct MicMonitorTests {
    static let me: pid_t = 100
    static let builtInMic = MicDevice(transport: kAudioDeviceTransportTypeBuiltIn, inputStreams: 1)
    static let usbMic = MicDevice(transport: kAudioDeviceTransportTypeUSB, inputStreams: 1)
    static let airPods = MicDevice(transport: kAudioDeviceTransportTypeBluetooth, inputStreams: 1)
    static let speaker = MicDevice(transport: kAudioDeviceTransportTypeBluetooth, inputStreams: 0)
    static let zoomDevice = MicDevice(transport: kAudioDeviceTransportTypeVirtual, inputStreams: 1)

    static func process(_ bundleID: String, pid: pid_t = 200, running: Bool = true,
                        _ devices: [MicDevice]?) -> MicProcess {
        MicProcess(pid: pid, bundleID: bundleID, runningInput: running, inputDevices: devices)
    }

    @Test func aScreenRecordingWithSystemAudioDoesNotCount() {
        let replayd = Self.process("com.apple.replayd", [])
        #expect(!replayd.counts(ownPID: Self.me))
        #expect(!MicMonitor.busy([replayd], ownPID: Self.me))
    }

    @Test func aScreenRecordingThatAlsoTakesTheMicCounts() {
        #expect(Self.process("com.apple.replayd", [Self.builtInMic]).counts(ownPID: Self.me))
    }

    @Test func anAppRecordingSystemAudioThroughATapDoesNotCount() {
        // The tap's private aggregate does not show in the process's devices.
        #expect(!Self.process("com.rogueamoeba.AudioHijack", []).counts(ownPID: Self.me))
    }

    @Test func callsStillCount() {
        #expect(Self.process("com.apple.FaceTime", [Self.builtInMic, Self.speaker]).counts(ownPID: Self.me))
        #expect(Self.process("us.zoom.xos", [Self.airPods, Self.zoomDevice]).counts(ownPID: Self.me))
        #expect(Self.process("com.google.Chrome.helper", [Self.usbMic]).counts(ownPID: Self.me))
        #expect(Self.process("", [Self.builtInMic]).counts(ownPID: Self.me))
    }

    /// A call whose selected mic is a virtual input device (a loopback or
    /// noise-cancelling driver) holds the mic like any other.
    @Test func aVirtualInputDeviceWithStreamsCounts() {
        #expect(Self.process("us.zoom.xos", [Self.zoomDevice]).counts(ownPID: Self.me))
        #expect(MicMonitor.busy([Self.process("us.zoom.xos", [Self.zoomDevice])], ownPID: Self.me))
        let noStreams = MicDevice(transport: kAudioDeviceTransportTypeVirtual, inputStreams: 0)
        #expect(!Self.process("com.example.app", [noStreams]).counts(ownPID: Self.me))
    }

    /// No input device listed is the screen recording, whatever app runs it.
    @Test func replaydWithNoInputDevicesDoesNotCount() {
        #expect(!MicMonitor.busy([Self.process("com.apple.replayd", [])], ownPID: Self.me))
        #expect(!MicMonitor.busy([Self.process("com.apple.replayd", [Self.speaker])], ownPID: Self.me))
    }

    @Test func anOutputDeviceInTheInputListIsNotAMic() {
        #expect(!Self.process("com.example.app", [Self.speaker]).counts(ownPID: Self.me))
    }

    @Test func anAggregateCountsWhenItHoldsAMic() {
        let withMic = MicDevice(transport: kAudioDeviceTransportTypeAggregate, inputStreams: 3,
                                subdevices: [Self.zoomDevice, Self.builtInMic])
        let tapOnly = MicDevice(transport: kAudioDeviceTransportTypeAggregate, inputStreams: 1,
                                subdevices: [Self.speaker])
        let auto = MicDevice(transport: kAudioDeviceTransportTypeAutoAggregate, inputStreams: 1, subdevices: [])
        let throughVirtual = MicDevice(transport: kAudioDeviceTransportTypeAggregate, inputStreams: 1,
                                       subdevices: [Self.zoomDevice])
        #expect(withMic.isMicrophone)
        #expect(throughVirtual.isMicrophone)
        #expect(!tapOnly.isMicrophone)
        #expect(!auto.isMicrophone)
    }

    /// Core Audio did not return the aggregate's active sub-devices: it counts.
    @Test func anAggregateWithAnUnreadableSubDeviceListCounts() {
        let agg = MicDevice(transport: kAudioDeviceTransportTypeAggregate, inputStreams: 2, subdevices: nil)
        #expect(agg.isMicrophone)
        #expect(MicMonitor.busy([Self.process("com.microsoft.teams2", [agg])], ownPID: Self.me))
    }

    @Test func aDeviceWhoseStreamsCannotBeReadCounts() {
        #expect(MicDevice(transport: kAudioDeviceTransportTypeBuiltIn, inputStreams: nil).isMicrophone)
    }

    @Test func anUnknownTransportWithInputCounts() {
        #expect(MicDevice(transport: kAudioDeviceTransportTypeUnknown, inputStreams: 1).isMicrophone)
        #expect(MicDevice(transport: kAudioDeviceTransportTypeContinuityCaptureWireless, inputStreams: 1).isMicrophone)
    }

    @Test func devicesCoreAudioCannotListStillCount() {
        #expect(Self.process("us.zoom.xos", nil).counts(ownPID: Self.me))
    }

    @Test func notRunningInputNeverCounts() {
        #expect(!Self.process("us.zoom.xos", running: false, [Self.builtInMic]).counts(ownPID: Self.me))
        #expect(!Self.process("us.zoom.xos", running: false, nil).counts(ownPID: Self.me))
    }

    @Test func earshotAndAlwaysOnListenersDoNotCount() {
        #expect(!Self.process("com.earshot.app", pid: Self.me, [Self.builtInMic]).counts(ownPID: Self.me))
        #expect(!Self.process("com.apple.corespeechd", [Self.builtInMic]).counts(ownPID: Self.me))
    }

    @Test func busyWhenAnyProcessCounts() {
        let replayd = Self.process("com.apple.replayd", [])
        let zoom = Self.process("us.zoom.xos", pid: 300, [Self.builtInMic])
        #expect(!MicMonitor.busy([], ownPID: Self.me))
        #expect(MicMonitor.busy([replayd, zoom], ownPID: Self.me))
    }

    /// Reads this Mac's processes the way the monitor does: no crash, and a
    /// process that runs input has its devices read (nil only on an error).
    @Test func readsInputProcesses() {
        for p in MicMonitor.inputProcesses() {
            #expect(p.runningInput)
        }
    }
}
