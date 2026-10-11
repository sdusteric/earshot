import AudioToolbox
import CoreAudio
import Foundation
import os

/// Lowers every other app's audio while Earshot talks. A Core Audio process
/// tap mutes the other apps and this plays their audio back quieter, fading
/// over 200 ms each way. The tap exists only while ducking; nothing is
/// recorded or saved. Needs the audio capture permission
/// (NSAudioCaptureUsageDescription); without it, begin() does nothing.
public actor TapDucker: Ducking {
    static let fade: Double = 0.2
    private let settings: @Sendable () -> (enabled: Bool, level: Float)
    private let log = Logger(subsystem: "com.earshot.app", category: "duck")
    private var tap = AudioObjectID(0)
    private var device = AudioDeviceID(0)
    private var proc: AudioDeviceIOProcID?
    private let gain = GainState()
    private var generation = 0
    public private(set) var lastError: OSStatus?

    public init(settings: @escaping @Sendable () -> (enabled: Bool, level: Float)) { self.settings = settings }

    public var isActive: Bool { device != 0 }
    public var callbacks: Int { gain.callbacks }

    public func begin() async {
        generation += 1
        let s = settings()
        guard s.enabled else { return }
        if device == 0 {
            do {
                try create()
            } catch let error as DuckError {
                lastError = error.status
                log.error("ducking failed at \(error.step, privacy: .public): \(error.status)")
                teardown()
                return
            } catch {
                teardown()
                return
            }
        }
        gain.setTarget(s.level)
    }

    public func end() async {
        guard device != 0 else { return }
        gain.setTarget(1)
        let g = generation
        try? await Task.sleep(for: .milliseconds(Int(Self.fade * 1000) + 50))
        // A new line started during the fade back: keep the tap.
        guard g == generation else { return }
        teardown()
    }

    /// Removes the tap at once, for quitting. Other apps play normally again.
    public func shutdown() { teardown() }

    // MARK: -

    struct DuckError: Error { let step: String; let status: OSStatus }

    private func create() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var pid = getpid()
        var me = AudioObjectID(0)
        var addr = MicMonitor.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me == 0 ? [] : [me])
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "Earshot"
        try check("create tap", AudioHardwareCreateProcessTap(desc, &tap))

        var out = AudioDeviceID(0)
        addr = MicMonitor.address(kAudioHardwarePropertyDefaultOutputDevice)
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check("output device", AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &out))
        var uid: Unmanaged<CFString>?
        addr = MicMonitor.address(kAudioDevicePropertyDeviceUID)
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check("output uid", AudioObjectGetPropertyData(out, &addr, 0, nil, &size, &uid))
        guard let outUID = uid?.takeRetainedValue() as String? else { throw DuckError(step: "output uid", status: -1) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earshot",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check("aggregate", AudioHardwareCreateAggregateDevice(description as CFDictionary, &device))

        var rate = Float64(48_000)
        addr = MicMonitor.address(kAudioDevicePropertyNominalSampleRate)
        size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        gain.reset(sampleRate: rate, fade: Self.fade)

        let g = gain
        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, inData, _, outData, _ in
            g.render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                     UnsafeMutableAudioBufferListPointer(outData))
        })
        try check("start", AudioDeviceStart(device, proc))
        lastError = nil
        log.info("ducking on")
    }

    private func teardown() {
        if device != 0, let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device) }
        if tap != 0 {
            AudioHardwareDestroyProcessTap(tap)
            log.info("ducking off")
        }
        proc = nil
        device = 0
        tap = 0
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw DuckError(step: step, status: status) }
    }

    /// Gain for each frame: a straight line from `from` to `to` over `fade` seconds.
    static func gainRamp(from: Float, to: Float, frames: Int, sampleRate: Double, fade: Double) -> [Float] {
        let step = (to - from) / Float(max(1, sampleRate * fade))
        var g = from
        return (0..<frames).map { _ in
            defer { g = step < 0 ? max(to, g + step) : min(to, g + step) }
            return g
        }
    }
}

/// Shared with the real-time audio thread: plain stores, no locks, no allocation.
final class GainState: @unchecked Sendable {
    private var current: Float = 1
    private var target: Float = 1
    private var step: Float = 0
    private var stepSize: Float = 1.0 / 9600
    private(set) var callbacks = 0

    func reset(sampleRate: Double, fade: Double) {
        current = 1
        target = 1
        step = 0
        stepSize = 1 / Float(max(1, sampleRate * fade))
    }

    func setTarget(_ t: Float) {
        target = t
        step = (t - current) * stepSize
    }

    func render(_ ins: UnsafeMutableAudioBufferListPointer, _ outs: UnsafeMutableAudioBufferListPointer) {
        callbacks &+= 1
        let channels = max(1, ins.first.map { Int($0.mNumberChannels) } ?? 1)
        var last = current
        for i in 0..<outs.count {
            guard let dst = outs[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(outs[i].mDataByteSize) / MemoryLayout<Float>.size
            guard i < ins.count, let src = ins[i].mData?.assumingMemoryBound(to: Float.self) else {
                dst.update(repeating: 0, count: n)
                continue
            }
            let m = min(n, Int(ins[i].mDataByteSize) / MemoryLayout<Float>.size)
            var g = current
            for k in 0..<m {
                if k % channels == 0, g != target {
                    g += step
                    if (step < 0 && g < target) || (step > 0 && g > target) { g = target }
                }
                dst[k] = src[k] * g
            }
            if m < n { (dst + m).update(repeating: 0, count: n - m) }
            last = g
        }
        current = last
    }
}
