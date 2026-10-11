import Foundation
import Testing
@testable import EarshotKit

@Suite(.serialized) struct TapDuckerTests {
    @Test func rampReachesTheTargetInTheFadeTime() {
        let r = TapDucker.gainRamp(from: 1, to: 0.3, frames: 9600, sampleRate: 48_000, fade: 0.2)
        #expect(abs(r[0] - 1) < 0.01)
        #expect(abs(r[9599] - 0.3) < 0.01)
        #expect(abs(r[4800] - 0.65) < 0.02)
    }

    @Test func offMeansNoTap() async {
        let d = TapDucker { (false, 0.3) }
        await d.begin()
        #expect(await d.isActive == false)
        await d.end()
    }

    /// Needs audio hardware and the audio capture permission, so it runs only
    /// with EARSHOT_TEST_DUCK=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_DUCK"] == "1"))
    func tapsAndRestores() async throws {
        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = ["-v", "0.05", "/System/Library/Sounds/Submarine.aiff"]
        try afplay.run()
        let d = TapDucker { (true, 0.3) }
        await d.begin()
        #expect(await d.lastError == nil)
        #expect(await d.isActive)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await d.callbacks > 0)
        await d.end()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await d.isActive == false)
        afplay.waitUntilExit()
    }
}
