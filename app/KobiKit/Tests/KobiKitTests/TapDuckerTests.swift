import CoreAudio
import Foundation
import Testing
@testable import KobiKit

/// Records what the ducker asks of the audio side.
final class FakeBackend: DuckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0, _stops = 0, _target: Float = 1
    private let startDelay: TimeInterval
    /// startDelay: start blocks this long, like a Core Audio call that hangs.
    init(startDelay: TimeInterval = 0) { self.startDelay = startDelay }
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var target: Float { lock.withLock { _target } }
    var callbacks: Int { 0 }
    func start() throws {
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        lock.withLock { _starts += 1 }
    }
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

    @Test func theGainFadesToTheTargetInTheFadeTime() {
        let gain = GainState()
        gain.reset(sampleRate: 1000, fade: 0.2)   // 200 frames to fade
        gain.setTarget(0.5)
        let ones = [Float](repeating: 1, count: 300)
        let out = render(ones, inChannels: 1, outChannels: 1, outFrames: 300, gain: gain)
        #expect(abs(out[0] - 1) < 0.01)
        #expect(abs(out[100] - 0.75) < 0.02)
        #expect(abs(out[250] - 0.5) < 0.001)
    }

    /// A device-change callback from a tap that is already gone must not
    /// remove the tap that replaced it.
    @Test func anOldTapsCallbackLeavesTheNewTapAlone() async throws {
        let backends = [FakeBackend(), FakeBackend()]
        let made = Counter()
        let callbacks = CallbackList()
        let d = TapDucker(settings: { (true, 0.3) }, maxDuck: .seconds(45)) { change in
            callbacks.append(change)
            let i = callbacks.count - 1
            Task { await made.bump() }
            return backends[min(i, 1)]
        }
        await d.begin()
        callbacks.fire(0)                      // the output changed: tap 1 goes
        try await Task.sleep(for: .milliseconds(100))
        #expect(await d.isActive == false)
        await d.begin()                        // tap 2
        callbacks.fire(0)                      // a late callback from tap 1
        try await Task.sleep(for: .milliseconds(100))
        #expect(await d.isActive)
        #expect(backends[1].stops == 0)
        await d.end()
    }

    @Test func ourOwnProcessIsFound() {
        #expect(CoreAudioTap.ownProcessObject() != nil)
    }

    /// Runs GainState.render on one interleaved input and output buffer.
    func render(_ input: [Float], inChannels: Int, outChannels: Int, outFrames: Int, gain: GainState? = nil) -> [Float] {
        let gain = gain ?? {
            let g = GainState()
            g.reset(sampleRate: 48_000, fade: 0.2)
            return g
        }()
        var inData = input
        var outData = [Float](repeating: 99, count: outFrames * outChannels)
        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
        inData.withUnsafeMutableBytes { inBytes in
            outData.withUnsafeMutableBytes { outBytes in
                inList[0] = AudioBuffer(mNumberChannels: UInt32(inChannels), mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress)
                outList[0] = AudioBuffer(mNumberChannels: UInt32(outChannels), mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress)
                gain.render(inList, outList)
            }
        }
        return outData
    }

    @Test func stereoToStereoCopies() {
        #expect(render([0.1, 0.2, 0.3, 0.4], inChannels: 2, outChannels: 2, outFrames: 2) == [0.1, 0.2, 0.3, 0.4])
    }

    @Test func stereoToMonoMixes() {
        let out = render([0.2, 0.4, 0.6, 0.8], inChannels: 2, outChannels: 1, outFrames: 2)
        #expect(abs(out[0] - 0.3) < 0.0001 && abs(out[1] - 0.7) < 0.0001)
    }

    @Test func stereoToFourChannelsFillsTheFirstTwo() {
        #expect(render([0.1, 0.2, 0.3, 0.4], inChannels: 2, outChannels: 4, outFrames: 2)
            == [0.1, 0.2, 0, 0, 0.3, 0.4, 0, 0])
    }

    @Test func monoToStereoCopiesToBoth() {
        #expect(render([0.1, 0.3], inChannels: 1, outChannels: 2, outFrames: 2) == [0.1, 0.1, 0.3, 0.3])
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
        // The tap is removed on the audio queue, a moment after end returns.
        for _ in 0..<100 where backend.stops == 0 { try? await Task.sleep(for: .milliseconds(10)) }
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

    /// Review finding 5: creating the tap can hang inside Core Audio. begin()
    /// gives up quickly, and a tap that appears late is removed at once.
    @Test func aTapStartThatHangsIsGivenUpAndRemovedWhenItReturns() async throws {
        let backend = FakeBackend(startDelay: 0.4)
        let box = ChangeBox()
        let d = TapDucker(settings: { (true, 0.3) }, maxDuck: .seconds(45), startTimeout: .milliseconds(100)) { change in
            box.set(change)
            return backend
        }
        let t0 = Date()
        await d.begin()
        #expect(Date().timeIntervalSince(t0) < 0.3)
        #expect(await d.isActive == false)
        #expect(await d.lastError != nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(backend.starts == 1)
        #expect(backend.stops == 1)
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
    /// with KOBI_TEST_DUCK=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOBI_TEST_DUCK"] == "1"))
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

/// Every device-change callback the ducker handed out, in order.
final class CallbackList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { list.count } }
    func append(_ c: @escaping @Sendable () -> Void) { lock.withLock { list.append(c) } }
    func fire(_ i: Int) { lock.withLock { list[i] }() }
}

/// Holds the device-change callback the ducker hands its backend.
final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func set(_ c: @escaping @Sendable () -> Void) { lock.withLock { callback = c } }
    func fire() { lock.withLock { callback }?() }
}
