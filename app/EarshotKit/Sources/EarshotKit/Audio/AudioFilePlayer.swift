import AVFoundation
import os

/// A started playback: AVAudioPlayer, or a stand-in in tests.
public protocol PlaybackHandle: AnyObject {
    var isPlaying: Bool { get }
    /// How loud the playback is now, from 0 to 1.
    var outputLevel: Float { get }
    func stop()
}

extension PlaybackHandle {
    public var outputLevel: Float { 0 }
}

extension AVAudioPlayer: PlaybackHandle {
    public var outputLevel: Float {
        guard isMeteringEnabled else { return 0 }
        updateMeters()
        return AudioLevel.fromDecibels(averagePower(forChannel: 0), floor: -45, ceiling: -8)
    }
}

/// Plays one file per line. Each play and stop names its line, so a stop that
/// arrives before the play has started still counts, and a start that returns
/// after its line was given up on stops at once instead of playing out of turn.
/// Watches isPlaying every 50 ms instead of relying on delegate callbacks,
/// which need a main run loop. AVAudioPlayer releases the output when it
/// stops, so the audio hardware can sleep between lines.
public final class AudioFilePlayer: LinePlayer, @unchecked Sendable {
    public typealias Starter = @Sendable (URL, Float) -> (any PlaybackHandle)?

    private let lock = NSLock()
    private var playing: [UUID: any PlaybackHandle] = [:]
    private var stopped: [UUID] = []   // the most recent stops, oldest first
    private let volume: Float
    private let starter: Starter
    /// The playing line's loudness, for the orb. 0 between lines.
    public let level: AudioLevel
    private let log = Logger(subsystem: "com.earshot.app", category: "player")

    public init(volume: Float = 1, level: AudioLevel = AudioLevel()) {
        self.volume = volume
        self.level = level
        starter = { url, volume in
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
            p.volume = volume
            p.isMeteringEnabled = true
            return p.play() ? p : nil
        }
    }

    init(volume: Float = 1, level: AudioLevel = AudioLevel(), starter: @escaping Starter) {
        self.volume = volume
        self.level = level
        self.starter = starter
    }

    public func play(_ url: URL, id: UUID) async -> Bool {
        if isStopped(id) { return false }
        // Opening and starting can block inside Core Audio (seen while a
        // Bluetooth output switched mode), so both run on a dispatch thread,
        // never on Swift's shared concurrency threads. SpeechOut gives up on a
        // line that takes too long and stops it by id.
        let volume = self.volume, starter = self.starter
        let started: (any PlaybackHandle)? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                nonisolated(unsafe) let handle = starter(url, volume)
                cont.resume(returning: handle)
            }
        }
        guard let p = started else {
            log.error("couldn't play \(url.lastPathComponent, privacy: .public)")
            return true   // nothing to wait for; the queue moves on
        }
        let stoppedAlready = lock.withLock {
            if stopped.contains(id) { return true }
            playing[id] = p
            return false
        }
        if stoppedAlready {
            p.stop()
            return false
        }
        defer { level.set(0) }
        while true {
            try? await Task.sleep(for: .milliseconds(50))
            let (isPlaying, wasStopped, loudness) = lock.withLock { (p.isPlaying, stopped.contains(id), p.outputLevel) }
            if wasStopped {
                // stop(id) stops a player it finds; stop it here only if it did not.
                lock.withLock { playing.removeValue(forKey: id) }?.stop()
                return false
            }
            if !isPlaying { break }
            level.set(loudness)
        }
        lock.withLock { playing[id] = nil }
        return true
    }

    public func stop(_ id: UUID) async {
        let p: (any PlaybackHandle)? = lock.withLock {
            stopped.append(id)
            if stopped.count > 64 { stopped.removeFirst(stopped.count - 64) }
            return playing.removeValue(forKey: id)
        }
        p?.stop()
    }

    private func isStopped(_ id: UUID) -> Bool { lock.withLock { stopped.contains(id) } }
}
