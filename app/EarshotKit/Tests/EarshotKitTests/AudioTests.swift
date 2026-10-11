import CoreAudio
import Foundation
import Testing
@testable import EarshotKit

/// The default output can start playback within 3 s. A speaker in standby
/// can take 15 s and then fail, which says nothing about Earshot.
let outputWorks: Bool = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["-v", "0", "/System/Library/Sounds/Tink.aiff"]
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let deadline = Date().addingTimeInterval(3)
    while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning { p.terminate(); return false }
    return p.terminationStatus == 0
}()

@Suite(.serialized) struct AudioTests {
    let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    let submarine = URL(fileURLWithPath: "/System/Library/Sounds/Submarine.aiff")

    @Test(.enabled(if: outputWorks)) func playsToTheEnd() async {
        #expect(await AudioFilePlayer(volume: 0.05).play(tink))
    }

    @Test(.enabled(if: outputWorks)) func stopEndsPlayEarly() async {
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

    /// Opens the mic with a helper program (EARSHOT_TEST_MIC_HOG=<path>, which
    /// keeps the mic open for the seconds given) and checks the monitor sees it
    /// and tells listeners.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_MIC_HOG"] != nil))
    func seesAnotherAppOpenTheMic() async throws {
        let m = MicMonitor()
        let changes = m.changes()
        let seen = Counter()
        let watcher = Task { for await busy in changes where busy { await seen.bump() } }
        let hog = Process()
        hog.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EARSHOT_TEST_MIC_HOG"]!)
        hog.arguments = ["3"]
        hog.standardOutput = FileHandle.nullDevice
        #expect(await m.isBusy == false, "something already uses the mic: \(m.appsUsingMic())")
        try hog.run()
        // Wait until Core Audio lists the helper as capturing. At that moment
        // isBusy must already say so: a line that arrives then must be held.
        var listed = false
        for _ in 0..<60 where !listed {
            try await Task.sleep(for: .milliseconds(25))
            listed = MicMonitor.processes().contains {
                MicMonitor.pid($0) == hog.processIdentifier && MicMonitor.uint($0, kAudioProcessPropertyIsRunningInput) != 0
            }
        }
        #expect(listed)
        #expect(await m.isBusy)
        for _ in 0..<40 where await seen.n == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await seen.n >= 1)
        hog.waitUntilExit()
        watcher.cancel()
    }

    @Test func readsTheMicState() async {
        let m = MicMonitor()
        _ = await m.isBusy   // no crash, no hang; the value depends on this Mac
        _ = m.appsUsingMic()
    }
}
