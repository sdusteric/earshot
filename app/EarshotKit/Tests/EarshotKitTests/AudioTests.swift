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

/// Stands in for AVAudioPlayer: starting takes `delay` (blocking, like Core
/// Audio), then it "plays" for `plays`.
final class FakeStarter: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = 0, _stopped = 0
    let delay: Duration, plays: Duration
    init(delay: Duration, plays: Duration = .milliseconds(10)) { self.delay = delay; self.plays = plays }
    var started: Int { lock.withLock { _started } }
    var stopped: Int { lock.withLock { _stopped } }

    final class Handle: PlaybackHandle, @unchecked Sendable {
        let owner: FakeStarter
        let until: Date
        init(owner: FakeStarter, until: Date) { self.owner = owner; self.until = until }
        var isPlaying: Bool { Date() < until }
        func stop() { owner.lock.withLock { owner._stopped += 1 } }
    }

    func start(_ url: URL, _ volume: Float) -> (any PlaybackHandle)? {
        let c = delay.components
        Thread.sleep(forTimeInterval: Double(c.seconds) + Double(c.attoseconds) / 1e18)
        lock.withLock { _started += 1 }
        let p = plays.components
        return Handle(owner: self, until: Date().addingTimeInterval(Double(p.seconds) + Double(p.attoseconds) / 1e18))
    }
}

@Suite(.serialized) struct AudioTests {
    let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    let submarine = URL(fileURLWithPath: "/System/Library/Sounds/Submarine.aiff")

    @Test(.enabled(if: outputWorks)) func playsToTheEnd() async {
        #expect(await AudioFilePlayer(volume: 0.05).play(tink, id: UUID()))
    }

    @Test(.enabled(if: outputWorks)) func stopEndsPlayEarly() async {
        let player = AudioFilePlayer(volume: 0.05)
        let id = UUID()
        async let finished = player.play(submarine, id: id)
        try? await Task.sleep(for: .milliseconds(100))
        await player.stop(id)
        #expect(await finished == false)
    }

    @Test func aMissingFileDoesNotHang() async {
        #expect(await AudioFilePlayer().play(URL(fileURLWithPath: "/nonexistent.wav"), id: UUID()))
    }

    /// Review finding 3: a stop that arrives before the play starts still counts.
    @Test func aStopBeforeThePlayStartsCounts() async {
        let fake = FakeStarter(delay: .zero)
        let player = AudioFilePlayer(starter: fake.start)
        let id = UUID()
        await player.stop(id)
        #expect(await player.play(tink, id: id) == false)
        #expect(fake.started == 0)
    }

    /// Review finding 4: a start that returns long after it was given up on
    /// must stop at once, not play out of turn.
    @Test func aStartThatReturnsLateIsStopped() async throws {
        let fake = FakeStarter(delay: .milliseconds(300))
        let player = AudioFilePlayer(starter: fake.start)
        let id = UUID()
        let result = Task { await player.play(tink, id: id) }
        try await Task.sleep(for: .milliseconds(50))
        await player.stop(id)
        #expect(await result.value == false)
        #expect(fake.started == 1)
        #expect(fake.stopped == 1)
    }

    /// Review finding 4: a stopped line's player is stopped, not left running.
    @Test func stopStopsTheRunningPlayer() async throws {
        let fake = FakeStarter(delay: .zero, plays: .seconds(5))
        let player = AudioFilePlayer(starter: fake.start)
        let id = UUID()
        let result = Task { await player.play(tink, id: id) }
        try await Task.sleep(for: .milliseconds(150))
        await player.stop(id)
        #expect(await result.value == false)
        #expect(fake.stopped == 1)
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
