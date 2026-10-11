import Foundation
import Testing
@testable import EarshotKit

@Suite(.serialized) struct AudioTests {
    let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    let submarine = URL(fileURLWithPath: "/System/Library/Sounds/Submarine.aiff")

    @Test func playsToTheEnd() async {
        #expect(await AudioFilePlayer(volume: 0.05).play(tink))
    }

    @Test func stopEndsPlayEarly() async {
        let player = AudioFilePlayer(volume: 0.05)
        async let finished = player.play(submarine)
        try? await Task.sleep(for: .milliseconds(100))
        await player.stop()
        #expect(await finished == false)
    }

    @Test func aMissingFileDoesNotHang() async {
        #expect(await AudioFilePlayer().play(URL(fileURLWithPath: "/nonexistent.wav")))
    }

    @Test func alwaysOnListenersDoNotCount() {
        #expect(!MicMonitor.counts(bundleID: "com.apple.corespeechd"))
        #expect(!MicMonitor.counts(bundleID: "com.apple.inputmethod.ironwood"))
        #expect(MicMonitor.counts(bundleID: "us.zoom.xos"))
        #expect(MicMonitor.counts(bundleID: ""))
    }

    @Test func readsTheMicState() async {
        let m = MicMonitor()
        _ = await m.isBusy   // no crash, no hang; the value depends on this Mac
        _ = m.appsUsingMic()
    }
}
