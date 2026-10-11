import CoreAudio
import Darwin
import Foundation

/// Knows when another app captures from the mic, for example during a call
/// or while you dictate. Follows Core Audio's process list with property
/// listeners, so it costs nothing while nothing changes. Earshot itself and
/// always-on listeners (Siri, Voice Control) do not count.
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
            queue.sync {
                refresh()
                return busy
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

    /// Each app that captures now and whether it counts, for diagnostics.
    public func appsUsingMic() -> [(bundleID: String, counts: Bool)] {
        queue.sync {
            Self.processes().compactMap { p in
                guard Self.uint(p, kAudioProcessPropertyIsRunningInput) != 0 else { return nil }
                let id = Self.bundleID(p)
                return (id, Self.pid(p) != ownPID && Self.counts(bundleID: id))
            }
        }
    }

    // MARK: - on queue

    private func rewatch() {
        for p in Self.processes() where !watched.contains(p) {
            watched.insert(p)
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectAddPropertyListenerBlock(p, &addr, queue) { [weak self] _, _ in self?.refresh() }
        }
    }

    private func refresh() {
        let now = compute()
        guard now != busy else { return }
        busy = now
        conts.values.forEach { $0.yield(now) }
    }

    private func compute() -> Bool {
        Self.processes().contains { p in
            Self.uint(p, kAudioProcessPropertyIsRunningInput) != 0 && Self.pid(p) != ownPID
                && Self.counts(bundleID: Self.bundleID(p))
        }
    }

    // MARK: - Core Audio helpers

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func processes() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
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
