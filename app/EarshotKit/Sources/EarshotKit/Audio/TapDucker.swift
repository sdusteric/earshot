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
    private let startTimeout: Duration
    private let makeBackend: @Sendable (@escaping @Sendable () -> Void) -> any DuckBackend
    private let log = Logger(subsystem: "com.earshot.app", category: "duck")
    private var backend: (any DuckBackend)?
    private var backendToken: UUID?
    private var generation = 0
    public private(set) var lastError: OSStatus?
    /// Core Audio calls run here, never on the actor, so one that hangs
    /// cannot stop the ducker from answering.
    private static let audioQueue = DispatchQueue(label: "com.earshot.app.duck.calls")

    public init(settings: @escaping @Sendable () -> (enabled: Bool, level: Float)) {
        self.init(settings: settings, maxDuck: .seconds(45), startTimeout: .seconds(2)) { CoreAudioTap(onOutputChange: $0) }
    }

    init(settings: @escaping @Sendable () -> (enabled: Bool, level: Float), maxDuck: Duration,
         startTimeout: Duration = .seconds(2),
         makeBackend: @escaping @Sendable (@escaping @Sendable () -> Void) -> any DuckBackend) {
        self.settings = settings
        self.maxDuck = maxDuck
        self.startTimeout = startTimeout
        self.makeBackend = makeBackend
    }

    public var isActive: Bool { backend != nil }
    public var callbacks: Int { backend?.callbacks ?? 0 }

    public func begin() async {
        generation += 1
        let s = settings()
        guard s.enabled else { return }
        if backend == nil {
            // The token ties a device-change callback to this tap, so a late
            // callback from an earlier tap cannot remove this one.
            let token = UUID()
            let b = makeBackend { [weak self] in Task { await self?.outputChanged(token) } }
            switch await start(b) {
            case .started:
                backend = b
                backendToken = token
                lastError = nil
                log.info("ducking on")
            case .failed(let status):
                lastError = status
                log.error("ducking failed: \(status)")
                return
            case .timedOut:
                lastError = -2
                log.error("ducking gave up: creating the tap took too long")
                return
            }
        }
        backend?.setTarget(s.level)
        armCap(generation)
    }

    private enum StartResult: Sendable { case started, failed(OSStatus), timedOut }

    /// Starts the backend on the audio queue, giving up after startTimeout. A
    /// start that finishes after that is undone at once, so no tap is left behind.
    private func start(_ b: any DuckBackend) async -> StartResult {
        let once = Once()
        let limit = startTimeout
        let backend = b
        return await withCheckedContinuation { (cont: CheckedContinuation<StartResult, Never>) in
            Self.audioQueue.async {
                let result: StartResult
                do {
                    try backend.start()
                    result = .started
                } catch {
                    backend.stop()
                    result = .failed((error as? DuckError)?.status ?? -1)
                }
                if once.claim() {
                    cont.resume(returning: result)
                } else if case .started = result {
                    backend.stop()   // begin() already gave up on this one
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { cont.resume(returning: .timedOut) }
            }
        }
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
    /// Waits for it, unlike the other teardowns: the app is about to exit.
    public func shutdown() {
        guard let b = backend else { return }
        backend = nil
        let held = b
        Self.audioQueue.sync { held.stop() }
        log.info("ducking off (quit)")
    }

    private func outputChanged(_ token: UUID) {
        guard backend != nil, token == backendToken else { return }
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
        backend = nil
        backendToken = nil
        let held = b
        Self.audioQueue.async { held.stop() }
        log.info("\(message, privacy: .public)")
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

    /// Earshot's own Core Audio process object, to leave out of the tap.
    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var me = AudioObjectID(0)
        var addr = MicMonitor.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        return status == noErr && me != 0 ? me : nil
    }

    func start() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Without it the tap would include Earshot's own voice and lower it too.
        guard let me = Self.ownProcessObject() else { throw DuckError(step: "own process", status: -1) }
        var addr = MicMonitor.address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(0)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
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

    /// Copies the tap's audio to the output at the current gain, frame by
    /// frame, mapping channels: the tap is stereo, the output may be mono (a
    /// headset in call mode) or have more channels. Buffers are either one
    /// interleaved buffer or one buffer per channel.
    func render(_ ins: UnsafeMutableAudioBufferListPointer, _ outs: UnsafeMutableAudioBufferListPointer) {
        callbacks &+= 1
        let inCh = Self.channels(ins), outCh = Self.channels(outs)
        guard outCh > 0 else { return }
        // Per-channel pointers live on the stack: no allocation on the audio thread.
        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: max(inCh, 1)) { inP in
            withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: outCh) { outP in
                guard let out = Self.fill(outs, outP) else { return }
                guard inCh > 0, let inp = Self.fill(ins, inP) else {
                    for f in 0..<out.frames { for c in 0..<outCh { outP[c][f * out.stride] = 0 } }
                    return
                }
                let frames = min(inp.frames, out.frames)
                var g = current
                for f in 0..<frames {
                    if g != target {
                        g += step
                        if (step < 0 && g < target) || (step > 0 && g > target) { g = target }
                    }
                    if outCh == 1 {
                        var sum: Float = 0
                        for c in 0..<inCh { sum += inP[c][f * inp.stride] }
                        outP[0][f * out.stride] = sum / Float(inCh) * g
                    } else {
                        for c in 0..<outCh {
                            let v: Float = c < inCh ? inP[c][f * inp.stride]
                                : (inCh == 1 && c < 2 ? inP[0][f * inp.stride] : 0)
                            outP[c][f * out.stride] = v * g
                        }
                    }
                }
                for f in frames..<out.frames { for c in 0..<outCh { outP[c][f * out.stride] = 0 } }
                current = g
            }
        }
    }

    /// Channels in a buffer list: one interleaved buffer, or one buffer per channel.
    static func channels(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        list.count == 1 ? max(1, Int(list[0].mNumberChannels)) : list.count
    }

    /// Fills `ptrs` with a pointer to each channel's first sample. Returns the
    /// stride between frames and the frame count, or nil when a buffer has no data.
    static func fill(_ list: UnsafeMutableAudioBufferListPointer,
                     _ ptrs: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>) -> (stride: Int, frames: Int)? {
        let size = MemoryLayout<Float>.size
        if list.count == 1 {
            guard let p = list[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let ch = max(1, Int(list[0].mNumberChannels))
            for c in 0..<ch { ptrs[c] = p + c }
            return (ch, Int(list[0].mDataByteSize) / size / ch)
        }
        var frames = Int.max
        for (i, b) in list.enumerated() {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            ptrs[i] = p
            frames = min(frames, Int(b.mDataByteSize) / size)
        }
        return list.isEmpty ? nil : (1, frames)
    }
}
