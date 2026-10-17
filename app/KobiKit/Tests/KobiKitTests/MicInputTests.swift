import Foundation
import Testing
@testable import KobiKit

@Suite struct MicInputTests {
    let builtIn = AudioDevices.Device(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", hasInput: true,
                                      isBluetooth: false, isBuiltIn: true)
    let airpods = AudioDevices.Device(uid: "AA-BB:input", name: "AirPods Pro", hasInput: true, isBluetooth: true,
                                      isBuiltIn: false)
    let usb = AudioDevices.Device(uid: "USB-1", name: "Yeti", hasInput: true, isBluetooth: false, isBuiltIn: false)

    @Test func aChosenInputThatIsPresentWins() {
        #expect(AudioDevices.chooseInput(setting: "USB-1", inputs: [builtIn, usb]) == "USB-1")
    }

    /// Automatic is the system default, whatever is connected: switching mics is slow and unreliable.
    @Test func automaticIsTheSystemDefault() {
        #expect(AudioDevices.chooseInput(setting: nil, inputs: [airpods, builtIn, usb]) == nil)
        #expect(AudioDevices.chooseInput(setting: "gone", inputs: [builtIn]) == nil)
    }

    /// Needs the mic and its permission: KOBI_TEST_MIC=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOBI_TEST_MIC"] == "1"))
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

@Suite struct InputCandidateTests {
    let camera = AudioDevices.Device(uid: "USB", name: "Insta360 Link", hasInput: true, isBluetooth: false, isBuiltIn: false)

    let builtIn = AudioDevices.Device(uid: "BuiltIn", name: "MacBook Pro Microphone", hasInput: true,
                                      isBluetooth: false, isBuiltIn: true)
    let headset = AudioDevices.Device(uid: "BT", name: "WH-1000X", hasInput: true, isBluetooth: true, isBuiltIn: false)
    let zoom = AudioDevices.Device(uid: "ZOOM", name: "ZoomAudioDevice", hasInput: true, isBluetooth: false,
                                   isBuiltIn: false, isVirtual: true)

    @Test func aChosenMicThenTheDefault() {
        #expect(AudioDevices.inputCandidates(setting: "USB", inputs: [camera], defaultUID: "BuiltIn") == ["USB", nil])
    }

    @Test func automaticIsTheDefaultThenTheOtherRealMicsWiredFirst() {
        let all = [headset, builtIn, camera, zoom]
        #expect(AudioDevices.inputCandidates(setting: nil, inputs: all, defaultUID: "BuiltIn") == [nil, "USB", "BT"])
        #expect(AudioDevices.inputCandidates(setting: "gone", inputs: all, defaultUID: "USB") == [nil, "BuiltIn", "BT"])
    }

    /// With the lid closed the built-in mic opens to pure silence.
    @Test func theLidClosedSkipsTheBuiltInMic() {
        let all = [builtIn, headset, camera]
        #expect(AudioDevices.inputCandidates(setting: nil, inputs: all, defaultUID: "BuiltIn", lidClosed: true) == ["USB", "BT"])
        #expect(AudioDevices.inputCandidates(setting: "BuiltIn", inputs: all, defaultUID: "USB", lidClosed: true) == [nil, "BT"])
        #expect(AudioDevices.inputCandidates(setting: nil, inputs: [builtIn], defaultUID: "BuiltIn", lidClosed: true) == [nil])
    }
}

@Suite struct MicOrderTests {
    @Test func theMicThatWorkedGoesFirstAndRecentFailuresGoLast() {
        let now = ContinuousClock.now
        let o = MicInput.order(["BuiltIn", "USB", nil], lastGood: .some("USB"), failedAt: ["BuiltIn": now], now: now)
        #expect(o == ["USB", nil, "BuiltIn"])
    }

    @Test func aFailureFromLongAgoIsTriedInItsPlaceAgain() {
        let now = ContinuousClock.now
        let o = MicInput.order(["BuiltIn", "USB", nil], lastGood: nil, failedAt: ["BuiltIn": now - .seconds(700)], now: now)
        #expect(o == ["BuiltIn", "USB", nil])
    }

    @Test func aSilentSystemDefaultGoesLast() {
        let now = ContinuousClock.now
        let o = MicInput.order([nil, "USB"], lastGood: nil, failedAt: [nil: now], now: now)
        #expect(o == ["USB", nil])
    }

    @Test func theSystemDefaultCanBeTheOneThatWorked() {
        let o = MicInput.order(["BuiltIn", nil], lastGood: .some(nil), failedAt: [:], now: .now)
        #expect(o == [nil, "BuiltIn"])
    }
}

@Suite struct DeadMicTests {
    /// A webcam mic's noise gate sends exact zeros while nobody talks, so a short
    /// stretch of zeros is not a dead mic; a long hold of nothing else is.
    @Test func onlyALongHoldOfZerosCountsAsSilent() {
        let h = HeardFlag()
        let zeros = [Float](repeating: 0, count: 2_048)
        for _ in 0..<20 { h.count(zeros) }   // 2.6 s
        #expect(!h.onlySilence)
        for _ in 0..<4 { h.count(zeros) }    // 3.1 s
        #expect(h.onlySilence)
    }

    /// A quiet room is never exactly zero: that is not a dead mic.
    @Test func quietAudioIsNotADeadMic() {
        let h = HeardFlag()
        let quiet = (0..<2_048).map { i in Float(i % 3 - 1) * 0.000_01 }
        for _ in 0..<30 { h.count(quiet) }
        #expect(!h.onlySilence)
    }

    /// A gated mic: zeros, then your voice opens the gate.
    @Test func zerosThenSpeechIsNotSilent() {
        let h = HeardFlag()
        for _ in 0..<30 { h.count([Float](repeating: 0, count: 2_048)) }
        h.count([0.2, 0.1])
        #expect(!h.onlySilence)
    }

    @Test func anotherMicIsTriedOnlyWhenOneHasNotFailedLately() {
        let now = ContinuousClock.now
        #expect(MicInput.hasAnother([nil, "USB"], than: nil, failedAt: [nil: now], now: now))
        #expect(!MicInput.hasAnother([nil, "USB"], than: nil, failedAt: [nil: now, "USB": now], now: now))
        #expect(!MicInput.hasAnother([nil], than: nil, failedAt: [nil: now], now: now))
        #expect(MicInput.hasAnother([nil, "USB"], than: nil, failedAt: [nil: now, "USB": now - .seconds(700)], now: now))
    }
}
