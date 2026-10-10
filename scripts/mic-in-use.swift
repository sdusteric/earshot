// Is an app capturing from the microphone? Earshot holds its lines while one
// is, for example during a call or while you dictate with /voice.
// Exit 0: an app is capturing. Exit 1: none is.
// Exit 2: the input device is running, but this Mac (before macOS 14.2)
// cannot say which app uses it.
// Always-on listeners (Siri, Voice Control) do not count: they keep the mic
// open all day. --list prints each app that is capturing and whether it counts.
import CoreAudio
import Foundation

let ignored = ["com.apple.corespeechd", "com.apple.SpeechRecognitionCore", "com.apple.speech."]
let list = CommandLine.arguments.contains("--list")
let system = AudioObjectID(kAudioObjectSystemObject)

func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
  var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  var size = UInt32(MemoryLayout<T>.size)
  return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) == noErr }
}

if #available(macOS 14.2, *) {
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  var size = UInt32(0)
  if AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr {
    var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &procs) == noErr else { exit(1) }
    var busy = false
    for p in procs {
      var input = UInt32(0)
      guard get(p, kAudioProcessPropertyIsRunningInput, &input), input != 0 else { continue }
      var cf: Unmanaged<CFString>? = nil
      let id = get(p, kAudioProcessPropertyBundleID, &cf) ? ((cf?.takeRetainedValue() as String?) ?? "") : ""
      let skip = ignored.contains { id.hasPrefix($0) }
      if list { print(id.isEmpty ? "(no bundle ID)" : id, skip ? "ignored" : "counts") }
      if !skip { busy = true; if !list { break } }
    }
    exit(busy ? 0 : 1)
  }
}

// Before macOS 14.2: only the device state is known.
var dev = AudioDeviceID(0)
guard get(system, kAudioHardwarePropertyDefaultInputDevice, &dev) else { exit(1) }
var running = UInt32(0)
guard get(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, &running) else { exit(1) }
exit(running != 0 ? 2 : 1)
