import AudioToolbox
import CoreAudio
import Foundation
import os

/// The audio side of ducking: a tap that plays every other app back at a gain.
protocol DuckBackend: AnyObject, Sendable {
    /// Creates the tap at full volume. Throws when Core Audio refuses.
    func start() throws
    /// Fades other apps toward this gain.
    func setTarget(_ gain: Float)
    /// Removes the tap; other apps play normally again.
    func stop()
    var callbacks: Int { get }
}

/// Lowers every other app's audio while Earshot talks. A Core Audio process
/// tap mutes the other apps and plays their audio back quieter, fading over
/// 200 ms each way. The tap exists only while ducking; nothing is recorded or
/// saved. Needs the audio capture permission (NSAudioCaptureUsageDescription);
/// without it, begin() does nothing.
///
/// Other apps must never stay quiet, so the tap also goes when the default
/// output device changes and, as a last resort, when no line has renewed it
/// for `maxDuck`.
public actor TapDucker: Ducking {
    static let fade: Double = 0.2
    private let settings: @Sendable () -> (enabled: Bool, level: Float)
    private let maxDuck: Duration
    private let makeBackend: @Sendable (@escaping @Sendable () -> Void) -> any DuckBackend
    private let log = Logger(subsystem: "com.earshot.app", category: "duck")
    private var backend: (any DuckBackend)?
    private var generation = 0
    public private(set) var lastError: OSStatus?

    public init(settings: @escaping @Sendable () -> (enabled: Bool, level: Float)) {
        self.init(settings: settings, maxDuck: .seconds(45)) { CoreAudioTap(onOutputChange: $0) }
    }

    init(settings: @escaping @Sendable () -> (enabled: Bool, level: Float), maxDuck: Duration,
         makeBackend: @escaping @Sendable (@escaping @Sendable () -> Void) -> any DuckBackend) {
        self.settings = settings
        self.maxDuck = maxDuck
        self.makeBackend = makeBackend
    }

    public var isActive: Bool { backend != nil }
    public var callbacks: Int { backend?.callbacks ?? 0 }

    public func begin() async {
        generation += 1
        let s = settings()
        guard s.enabled else { return }
        if backend == nil {
            let b = makeBackend { [weak self] in Task { await self?.outputChanged() } }
            do {
                try b.start()
                backend = b
                lastError = nil
                log.info("ducking on")
            } catch {
                lastError = (error as? DuckError)?.status ?? -1
                log.error("ducking failed: \(String(describing: error), privacy: .public)")
                b.stop()
                return
            }
        }
        backend?.setTarget(s.level)
        armCap(generation)
    }

    public func end() async {
        guard let b = backend else { return }
        b.setTarget(1)
        let g = generation
        try? await Task.sleep(for: .milliseconds(Int(Self.fade * 1000) + 50))
        // A new line started during the fade back: keep the tap.
        guard g == generation else { return }
        teardown("ducking off")
    }

    /// Removes the tap at once, for quitting. Other apps play normally again.
    public func shutdown() { teardown("ducking off (quit)") }

    private func outputChanged() {
        guard backend != nil else { return }
        teardown("ducking off: the output device changed")
    }

    /// The last resort: no line renewed the ducking in time.
    private func armCap(_ g: Int) {
        let cap = maxDuck
        Task { [weak self] in
            try? await Task.sleep(for: cap)
            await self?.capFired(g)
        }
    }

    private func capFired(_ g: Int) {
        guard g == generation, backend != nil else { return }
        teardown("ducking off: no line renewed it in time")
    }

    private func teardown(_ message: String) {
        guard let b = backend else { return }
        b.stop()
        backend = nil
        log.info("\(message, privacy: .public)")
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

struct DuckError: Error { let step: String; let status: OSStatus }

/// The real tap: a private aggregate device on the default output, with a
/// process tap of every app except Earshot, muted at the source and played
/// back through an IO proc at a gain.
final class CoreAudioTap: DuckBackend, @unchecked Sendable {
    private var tap = AudioObjectID(0)
    private var device = AudioDeviceID(0)
    private var proc: AudioDeviceIOProcID?
    private let gain = GainState()
    private let onOutputChange: @Sendable () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.earshot.app.duck")

    init(onOutputChange: @escaping @Sendable () -> Void) { self.onOutputChange = onOutputChange }

    var callbacks: Int { gain.callbacks }

    func start() throws {
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
        gain.reset(sampleRate: rate, fade: TapDucker.fade)

        let g = gain
        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, inData, _, outData, _ in
            g.render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                     UnsafeMutableAudioBufferListPointer(outData))
        })
        try check("start", AudioDeviceStart(device, proc))

        // A new default output (a headset connecting or switching mode) leaves
        // this aggregate on the old one: drop it, the next line builds a new one.
        let changed = onOutputChange
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        addr = MicMonitor.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(system, &addr, queue, block) == noErr { listener = block }
    }

    func setTarget(_ gain: Float) { self.gain.setTarget(gain) }

    func stop() {
        if let listener {
            var addr = MicMonitor.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
            self.listener = nil
        }
        if device != 0, let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        device = 0
        tap = 0
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw DuckError(step: step, status: status) }
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
