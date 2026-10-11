import Foundation
import Testing
@testable import EarshotKit

/// Records what the ducker asks of the audio side.
final class FakeBackend: DuckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0, _stops = 0, _target: Float = 1
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var target: Float { lock.withLock { _target } }
    var callbacks: Int { 0 }
    func start() throws { lock.withLock { _starts += 1 } }
    func setTarget(_ gain: Float) { lock.withLock { _target = gain } }
    func stop() { lock.withLock { _stops += 1 } }
}

@Suite(.serialized) struct TapDuckerTests {
    func make(_ backend: FakeBackend, enabled: Bool = true, maxDuck: Duration = .seconds(45))
        -> (TapDucker, @Sendable () -> Void) {
        let box = ChangeBox()
        let d = TapDucker(settings: { (enabled, 0.3) }, maxDuck: maxDuck) { onChange in
            box.set(onChange)
            return backend
        }
        return (d, { box.fire() })
    }

    @Test func rampReachesTheTargetInTheFadeTime() {
        let r = TapDucker.gainRamp(from: 1, to: 0.3, frames: 9600, sampleRate: 48_000, fade: 0.2)
        #expect(abs(r[0] - 1) < 0.01)
        #expect(abs(r[9599] - 0.3) < 0.01)
        #expect(abs(r[4800] - 0.65) < 0.02)
    }

    @Test func offMeansNoTap() async {
        let backend = FakeBackend()
        let (d, _) = make(backend, enabled: false)
        await d.begin()
        #expect(await d.isActive == false)
        #expect(backend.starts == 0)
    }

    @Test func beginLowersAndEndRestoresThenRemovesTheTap() async throws {
        let backend = FakeBackend()
        let (d, _) = make(backend)
        await d.begin()
        #expect(await d.isActive)
        #expect(backend.target == 0.3)
        await d.end()
        #expect(backend.target == 1)
        #expect(await d.isActive == false)
        #expect(backend.stops == 1)
    }

    @Test func theSafetyCapRemovesAForgottenTap() async throws {
        let backend = FakeBackend()
        let (d, _) = make(backend, maxDuck: .milliseconds(150))
        await d.begin()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await d.isActive == false)
        #expect(backend.stops == 1)
    }

    @Test func eachBeginRenewsTheCap() async throws {
        let backend = FakeBackend()
        let (d, _) = make(backend, maxDuck: .milliseconds(200))
        for _ in 0..<4 {
            await d.begin()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await d.isActive)
        #expect(backend.starts == 1)
        await d.end()
    }

    @Test func anOutputDeviceChangeRemovesTheTap() async throws {
        let backend = FakeBackend()
        let (d, fire) = make(backend)
        await d.begin()
        fire()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await d.isActive == false)
        #expect(backend.stops == 1)
        await d.begin()   // the next line builds a new tap on the new device
        #expect(backend.starts == 2)
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
        #expect(await d.isActive == false)
        afplay.waitUntilExit()
    }
}

/// Holds the device-change callback the ducker hands its backend.
final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func set(_ c: @escaping @Sendable () -> Void) { lock.withLock { callback = c } }
    func fire() { lock.withLock { callback }?() }
}
