import AVFoundation
import CoreAudio
import IOKit
import Foundation
import os

public enum AudioDevices {
    public struct Device: Sendable, Equatable {
        public let uid: String
        public let name: String
        public let hasInput: Bool
        public let isBluetooth: Bool
        public let isBuiltIn: Bool
        public var hasOutput = false
        /// Made by software (a meeting app's device, an aggregate), not a microphone.
        public var isVirtual = false
    }

    /// The mics to try, in order: the one you chose in Settings, when it is
    /// here, then the system default (nil), then the other real mics, wired
    /// before Bluetooth, in case those give nothing. The system default opens
    /// in about 0.2 s and switching to another mic takes about a second, so
    /// Automatic is the system default, except a MacBook's own mic with the
    /// lid closed: it is switched off then, and opens to pure silence.
    public static func inputCandidates(setting: String?, inputs: [Device], defaultUID: String? = nil,
                                       lidClosed: Bool = false) -> [String?] {
        let usable = inputs.filter { $0.hasInput && !(lidClosed && $0.isBuiltIn) }
        let defaultIsOff = lidClosed && inputs.contains { $0.uid == defaultUID && $0.isBuiltIn }
        var out: [String?] = []
        if let setting, usable.contains(where: { $0.uid == setting }) { out.append(setting) }
        if !defaultIsOff { out.append(nil) }
        let rest = usable.filter { !$0.isVirtual && $0.uid != setting && $0.uid != defaultUID }
        out += rest.filter { !$0.isBluetooth }.map(\.uid) + rest.filter(\.isBluetooth).map(\.uid)
        return out.isEmpty ? [nil] : out
    }

    /// The speaker for Earshot's voice: the setting when that device is here, else nil (the system output).
    public static func chooseOutput(setting: String?, devices: [Device]) -> String? {
        guard let setting, devices.contains(where: { $0.uid == setting && $0.hasOutput }) else { return nil }
        return setting
    }

    /// The mic to open first: your choice, when that device is here; else nil, the system default.
    public static func chooseInput(setting: String?, inputs: [Device], defaultUID: String? = nil,
                                   lidClosed: Bool = false) -> String? {
        inputCandidates(setting: setting, inputs: inputs, defaultUID: defaultUID, lidClosed: lidClosed)[0]
    }

    public static func all() -> [Device] { allIDs().compactMap(device) }

    /// A MacBook with its lid closed (running on an external display).
    public static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (v?.takeRetainedValue() as? Bool) ?? false
    }

    /// The system's current default input or output, for "System default (name)".
    public static func systemDefault(input: Bool) -> Device? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return device(id)
    }

    public static func defaultOutputIsBluetooth() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return false }
        return device(id)?.isBluetooth ?? false
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        allIDs().first { uidOf($0) == uid }
    }

    private static func allIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func device(_ id: AudioObjectID) -> Device? {
        guard let uid = uidOf(id) else { return nil }
        let transport = uint(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        return Device(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                      hasInput: streamCount(id, kAudioObjectPropertyScopeInput) > 0,
                      isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                      isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                      hasOutput: streamCount(id, kAudioObjectPropertyScopeOutput) > 0,
                      isVirtual: transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate)
    }

    private static func uidOf(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func streamCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

/// 16 kHz mono from whatever the mic delivers. One converter per mic
/// session, so chunk edges join smoothly. Used only on the tap's thread.
final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: out) else { return nil }
        converter = c
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * out.sampleRate / buffer.format.sampleRate) + 32
        guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: dst, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = dst.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(dst.frameLength)))
    }
}

/// The mic through AVAudioEngine. The engine exists only while the mic is
/// open, and is rebuilt when the audio hardware changes.
public actor MicInput: AudioInput {
    public enum Failure: Error { case noInput }

    private let deviceUID: @Sendable () -> String?
    private var engine: AVAudioEngine?
    private var cont: AsyncStream<[Float]>.Continuation?
    private var observer: (any NSObjectProtocol)?
    private let log = Logger(subsystem: "com.earshot.app", category: "mic")
    /// The mic that opened last time, tried first, and mics that gave no
    /// audio lately, skipped: each failed try costs about half a second
    /// before the listening chime.
    private var lastGood: String??
    private var failedAt: [String?: ContinuousClock.Instant] = [:]
    static let retryFailedAfter: Duration = .seconds(600)
    private var heard: HeardFlag?
    /// The mic now open (nil inside: the system default).
    private var current: String??

    public init(deviceUID: @escaping @Sendable () -> String?) { self.deviceUID = deviceUID }

    public func start() async throws -> AsyncStream<[Float]> {
        await stop()
        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.cont = cont
        do { try build() } catch { cont.finish(); self.cont = nil; throw error }
        return stream
    }

    public func stop() async {
        teardown()
        cont?.finish()
        cont = nil
    }

    private func build() throws {
        let all = AudioDevices.inputCandidates(setting: deviceUID(), inputs: AudioDevices.all().filter(\.hasInput),
                                               defaultUID: AudioDevices.systemDefault(input: true)?.uid,
                                               lidClosed: AudioDevices.lidClosed())
        let candidates = MicInput.order(all, lastGood: lastGood, failedAt: failedAt, now: .now)
        let began = ContinuousClock.now
        for uid in candidates {
            if open(uid) {
                let ms = (ContinuousClock.now - began).components.attoseconds / 1_000_000_000_000_000
                    + (ContinuousClock.now - began).components.seconds * 1000
                log.info("mic open in \(ms, privacy: .public) ms")
                lastGood = .some(uid)
                current = .some(uid)
                failedAt[uid] = nil
                return
            }
            failedAt[uid] = .now
        }
        throw Failure.noInput
    }

    /// Opens the engine on one mic (nil: the system default). False when that
    /// mic gives no usable audio, so the next one is tried. After the mic is
    /// switched, the input node still reports the old mic's format until the
    /// engine is prepared, and a tap in a format the hardware doesn't match
    /// raises an Objective-C exception that ends the app. So: prepare, then
    /// tap in the mic's own rate and channels.
    private func open(_ uid: String?) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid {
            guard var id = AudioDevices.deviceID(uid: uid), let unit = input.audioUnit else { return false }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioObjectID>.size))
            if status != noErr {
                log.error("couldn't choose a mic, status \(status, privacy: .public)")
                return false
            }
        }
        engine.prepare()
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount),
              let resampler = Resampler(from: format) else {
            log.error("a mic gave no usable audio (\(uid == nil ? "the default" : "the chosen one", privacy: .public)); trying the next")
            return false
        }
        let cont = self.cont
        let heard = HeardFlag()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            heard.set()
            let s = resampler.convert(buffer)
            heard.count(s)
            if !s.isEmpty { cont?.yield(s) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log.error("a mic didn't start: \(error.localizedDescription, privacy: .public); trying the next")
            return false
        }
        self.engine = engine
        self.heard = heard
        log.info("mic format \(Int(hardware.sampleRate), privacy: .public) Hz, \(hardware.channelCount, privacy: .public) ch")
        if let uid {
            // A mic you chose can open and still deliver nothing: then the default takes over.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if !heard.isSet { await self?.deliveredNothing(uid, engine: engine) }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            Task { await self?.formatChanged() }
        }
        return true
    }

    /// The mic that worked last time first, mics that failed in the last ten
    /// minutes last (still tried, in case nothing else opens).
    static func order(_ candidates: [String?], lastGood: String??, failedAt: [String?: ContinuousClock.Instant],
                      now: ContinuousClock.Instant) -> [String?] {
        func recentlyFailed(_ c: String?) -> Bool {
            guard let t = failedAt[c] else { return false }
            return now - t < retryFailedAfter
        }
        var out = candidates
        if let good = lastGood, let i = out.firstIndex(where: { $0 == good }) {
            out.insert(out.remove(at: i), at: 0)
        }
        return out.filter { !recentlyFailed($0) } + out.filter { recentlyFailed($0) }
    }

    private func deliveredNothing(_ uid: String, engine: AVAudioEngine) {
        guard self.engine === engine, cont != nil else { return }
        log.error("the chosen mic delivered no audio; trying the next")
        failedAt[uid] = .now
        if lastGood == .some(uid) { lastGood = nil }
        rebuild()
    }

    private func formatChanged() {
        guard cont != nil else { return }
        log.info("the mic's format changed (a headset switching mode); reopening")
        rebuild()
    }

    private func rebuild() {
        guard cont != nil else { return }
        teardown()
        do { try build() } catch {
            log.error("couldn't reopen the mic after a device change")
            cont?.finish()
            cont = nil
        }
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if engine != nil { log.info("mic closed: \(self.heard?.summary ?? "", privacy: .public)") }
        if let heard, let current, heard.onlySilence {
            // A live mic always has some noise; exact zeros mean it is off or
            // not allowed, so the next hold starts with another mic.
            log.error("the mic gave only silence; the next hold tries another")
            failedAt[current] = .now
            if lastGood == .some(current) { lastGood = nil }
        }
        engine = nil
        heard = nil
        current = nil
    }
}

/// Set by the tap's thread on the first buffer, read by the mic's actor.
final class HeardFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var buffers = 0
    private var peak: Float = 0
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
    /// For the log: how much came in and how loud, never the audio itself.
    func count(_ samples: [Float]) {
        var p: Float = 0
        for x in samples { p = max(p, abs(x)) }
        lock.withLock { buffers += 1; peak = max(peak, p) }
    }
    /// Most of a second of audio, every sample exactly zero.
    var onlySilence: Bool { lock.withLock { buffers >= 8 && peak == 0 } }
    var summary: String { lock.withLock { "\(buffers) buffers, peak \(String(format: "%.3f", peak))" } }
}
