import Foundation
import Testing
@testable import EarshotKit

@Suite struct MicInputTests {
    let builtIn = AudioDevices.Device(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", hasInput: true,
                                      isBluetooth: false, isBuiltIn: true)
    let airpods = AudioDevices.Device(uid: "AA-BB:input", name: "AirPods Pro", hasInput: true, isBluetooth: true,
                                      isBuiltIn: false)
    let usb = AudioDevices.Device(uid: "USB-1", name: "Yeti", hasInput: true, isBluetooth: false, isBuiltIn: false)

    @Test func aChosenInputThatIsPresentWins() {
        #expect(AudioDevices.chooseInput(setting: "USB-1", inputs: [builtIn, usb], outputIsBluetooth: true) == "USB-1")
    }

    /// Opening a Bluetooth headset's mic drops all its audio to call quality.
    @Test func bluetoothOutputUsesTheBuiltInMic() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods, builtIn], outputIsBluetooth: true)
                == "BuiltInMicrophoneDevice")
    }

    @Test func otherwiseTheSystemDefault() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods, builtIn], outputIsBluetooth: false) == nil)
        #expect(AudioDevices.chooseInput(setting: "gone", inputs: [builtIn], outputIsBluetooth: false) == nil)
    }

    @Test func bluetoothOutputWithoutABuiltInMicFallsBack() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods], outputIsBluetooth: true) == nil)
    }

    /// A desktop Mac with AirPods and a USB mic must not open the AirPods mic.
    @Test func bluetoothOutputWithoutABuiltInMicUsesAnotherWiredMic() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods, usb], outputIsBluetooth: true) == "USB-1")
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods, usb, builtIn], outputIsBluetooth: true)
                == "BuiltInMicrophoneDevice")
    }

    /// Needs the mic and its permission: EARSHOT_TEST_MIC=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_MIC"] == "1"))
    func recordsAboutOneSecond() async throws {
        let mic = MicInput(deviceUID: { nil })
        let stream = try await mic.start()
        var count = 0
        let deadline = Date().addingTimeInterval(3)
        for await s in stream {
            count += s.count
            if count >= 16_000 || Date() > deadline { break }
        }
        await mic.stop()
        #expect(count >= 16_000)
    }
}

@Suite struct OutputChoiceTests {
    let speakers = AudioDevices.Device(uid: "SPK", name: "Audioengine 2+", hasInput: false, isBluetooth: true,
                                       isBuiltIn: false, hasOutput: true)
    let mic = AudioDevices.Device(uid: "MIC", name: "Yeti", hasInput: true, isBluetooth: false, isBuiltIn: false)

    @Test func aConnectedSpeakerIsUsed() {
        #expect(AudioDevices.chooseOutput(setting: "SPK", devices: [speakers, mic]) == "SPK")
    }

    @Test func aMissingOrInputOnlyDeviceFallsBackToTheSystemOutput() {
        #expect(AudioDevices.chooseOutput(setting: "GONE", devices: [speakers, mic]) == nil)
        #expect(AudioDevices.chooseOutput(setting: "MIC", devices: [speakers, mic]) == nil)
        #expect(AudioDevices.chooseOutput(setting: nil, devices: [speakers]) == nil)
    }
}
