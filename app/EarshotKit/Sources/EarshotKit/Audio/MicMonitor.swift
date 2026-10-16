import CoreAudio
import Darwin
import Foundation

/// Knows when another app captures from the mic, for example during a call
/// or while you dictate. Follows Core Audio's process list with property
/// listeners, so it costs nothing while nothing changes. Earshot itself and
/// always-on listeners (Siri, Voice Control) do not count, and neither does
/// input from no input device: a screen recording with system audio or an
/// app that records system audio (see MicProcess).
public final class MicMonitor: MicSource, @unchecked Sendable {
    static let ignored = ["com.apple.corespeechd", "com.apple.SpeechRecognitionCore", "com.apple.speech.",
                          "com.apple.inputmethod.ironwood"]
    private let queue = DispatchQueue(label: "com.earshot.app.mic")
    private var watched: Set<AudioObjectID> = []
    private var busy = false
    private var conts: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private let ownPID = getpid()

    public init() {
        queue.sync {
            var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
                self?.rewatch()
                self?.refresh()
            }
            rewatch()
            busy = compute()
        }
    }

    public static func counts(bundleID: String) -> Bool {
        !ignored.contains { !bundleID.isEmpty && bundleID.hasPrefix($0) }
    }

    /// Asks Core Audio now. Change notifications can arrive a second or more
    /// after an app starts capturing, so decisions never rely on them alone.
    public var isBusy: Bool {
        get async {
            // Hops to the monitor's queue instead of blocking a shared thread;
            // SpeechOut puts a time limit on the answer.
            await withCheckedContinuation { cont in
                queue.async {
                    self.refresh()
                    cont.resume(returning: self.busy)
                }
            }
        }
    }

    public func changes() -> AsyncStream<Bool> {
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        let id = UUID()
        queue.sync { conts[id] = cont }
        cont.onTermination = { [weak self] _ in self?.queue.async { self?.conts[id] = nil } }
        return stream
    }

    /// Each app that runs audio input now and whether it counts, for
    /// diagnostics. A screen recording shows as com.apple.replayd, not counted.
    public func appsUsingMic() -> [(bundleID: String, counts: Bool)] {
        queue.sync {
            Self.inputProcesses().map { ($0.bundleID, $0.counts(ownPID: ownPID)) }
        }
    }

    /// Whether any of these processes holds the mic for another app.
    static func busy(_ processes: [MicProcess], ownPID: pid_t) -> Bool {
        processes.contains { $0.counts(ownPID: ownPID) }
    }

    // MARK: - on queue

    private func rewatch() {
        for p in Self.processes() where !watched.contains(p) {
            watched.insert(p)
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectAddPropertyListenerBlock(p, &addr, queue) { [weak self] _, _ in self?.refresh() }
            // A screen recording that adds the mic keeps input running and
            // changes only the devices.
            var devices = Self.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            AudioObjectAddPropertyListenerBlock(p, &devices, queue) { [weak self] _, _ in self?.refresh() }
        }
    }

    private func refresh() {
        let now = compute()
        guard now != busy else { return }
        busy = now
        conts.values.forEach { $0.yield(now) }
    }

    private func compute() -> Bool {
        Self.busy(Self.inputProcesses(), ownPID: ownPID)
    }

    // MARK: - Core Audio helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// The processes that run audio input now, with the devices they use.
    static func inputProcesses() -> [MicProcess] {
        processes().compactMap { p in
            guard uint(p, kAudioProcessPropertyIsRunningInput) != 0 else { return nil }
            return MicProcess(pid: pid(p), bundleID: bundleID(p), runningInput: true,
                              inputDevices: objects(p, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)?
                                  .map { device($0) })
        }
    }

    /// A device and, for an aggregate, its active sub-devices (two levels at
    /// most). What Core Audio does not answer stays nil, and counts.
    static func device(_ id: AudioObjectID, depth: Int = 0) -> MicDevice {
        let transport = uint(id, kAudioDevicePropertyTransportType)
        var d = MicDevice(transport: transport,
                          inputStreams: objects(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)?.count)
        if depth < 2, transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate {
            d.subdevices = objects(id, kAudioAggregateDevicePropertyActiveSubDeviceList)?.map { device($0, depth: depth + 1) }
        }
        return d
    }

    /// An array of object IDs, or nil when Core Audio does not answer.
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var addr = address(selector, scope: scope)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return nil }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func processes() -> [AudioObjectID] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) ?? []
    }

    static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func pid(_ object: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func bundleID(_ object: AudioObjectID) -> String {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return "" }
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}
