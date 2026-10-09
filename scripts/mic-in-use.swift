// Exit 0 if any app is capturing from the default input device, 1 if not.
import CoreAudio

var dev = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                      mScope: kAudioObjectPropertyScopeGlobal,
                                      mElement: kAudioObjectPropertyElementMain)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { exit(1) }

var running = UInt32(0)
size = UInt32(MemoryLayout<UInt32>.size)
addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { exit(1) }
exit(running != 0 ? 0 : 1)
