import Foundation
import Testing
@testable import KobiKit

@Suite struct AudioLevelTests {
    @Test func decibelsMapOntoZeroToOne() {
        #expect(AudioLevel.fromDecibels(-60) == 0)
        #expect(AudioLevel.fromDecibels(-50) == 0)
        #expect(AudioLevel.fromDecibels(-30) == 0.5)
        #expect(AudioLevel.fromDecibels(0) == 1)
        #expect(AudioLevel.fromDecibels(-.infinity) == 0)
        #expect(AudioLevel.fromDecibels(.nan) == 0)
    }

    @Test func silenceIsZeroAndAFullScaleSineIsFull() {
        #expect(AudioLevel.fromSamples([]) == 0)
        #expect(AudioLevel.fromSamples([Float](repeating: 0, count: 512)) == 0)
        let sine = (0..<1600).map { Float(sin(Double($0) * 0.2)) }
        #expect(AudioLevel.fromSamples(sine) == 1)
    }

    @Test func setClampsToZeroToOne() {
        let l = AudioLevel()
        l.set(2); #expect(l.value == 1)
        l.set(-1); #expect(l.value == 0)
        l.set(.nan); #expect(l.value == 0)
    }

    final class LoudHandle: PlaybackHandle, @unchecked Sendable {
        let until = Date().addingTimeInterval(0.3)
        var isPlaying: Bool { Date() < until }
        var outputLevel: Float { 0.7 }
        func stop() {}
    }

    @Test func thePlayerPublishesTheLineLevelAndZeroAfter() async {
        let player = AudioFilePlayer(starter: { _, _ in LoudHandle() })
        async let done = player.play(URL(fileURLWithPath: "/dev/null"), id: UUID())
        try? await Task.sleep(for: .milliseconds(150))
        #expect(player.level.value == 0.7)
        #expect(await done)
        #expect(player.level.value == 0)
    }
}
