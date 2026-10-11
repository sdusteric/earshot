import AVFoundation
import CoreAudio
import Foundation
import os

public enum AudioDevices {
    public struct Device: Sendable, Equatable {
        public let uid: String
        public let name: String
        public let hasInput: Bool
        public let isBluetooth: Bool
        public let isBuiltIn: Bool
    }

    /// The mic to open. The setting, when that device is here; else the
    /// built-in mic when the output is Bluetooth (opening a Bluetooth mic
    /// switches the headset to call quality); else nil, the system default.
    public static func chooseInput(setting: String?, inputs: [Device], outputIsBluetooth: Bool) -> String? {
        if let setting, inputs.contains(where: { $0.uid == setting && $0.hasInput }) { return setting }
        if outputIsBluetooth, let b = inputs.first(where: { $0.isBuiltIn && $0.hasInput }) { return b.uid }
        return nil
    }

    public static func all() -> [Device] { allIDs().compactMap(device) }

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
                      isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
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
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let choice = AudioDevices.chooseInput(setting: deviceUID(), inputs: AudioDevices.all().filter(\.hasInput),
                                              outputIsBluetooth: AudioDevices.defaultOutputIsBluetooth())
        if let uid = choice, var id = AudioDevices.deviceID(uid: uid), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioObjectID>.size))
            if status != noErr { log.error("couldn't choose the mic, status \(status, privacy: .public)") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let resampler = Resampler(from: format) else {
            throw Failure.noInput
        }
        let cont = self.cont
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            let s = resampler.convert(buffer)
            if !s.isEmpty { cont?.yield(s) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            Task { await self?.rebuild() }
        }
        log.info("mic open")
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
        if engine != nil { log.info("mic closed") }
        engine = nil
    }
}
