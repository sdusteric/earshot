import AVFoundation
import os

/// Plays one file at a time. AVAudioPlayer releases the output when it stops,
/// so the audio hardware can sleep between lines. Watches isPlaying every
/// 50 ms instead of relying on delegate callbacks, which need a main run loop.
public final class AudioFilePlayer: LinePlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var stopped = false
    private let volume: Float
    private let log = Logger(subsystem: "com.earshot.app", category: "player")

    public init(volume: Float = 1) { self.volume = volume }

    public func play(_ url: URL) async -> Bool {
        // Opening and starting the player can block inside Core Audio (seen
        // while a Bluetooth headset switches mode), so both run on a dispatch
        // thread, never on Swift's shared concurrency threads. SpeechOut gives
        // up on a line that takes too long.
        let volume = self.volume
        lock.withLock { stopped = false }   // a stop from here on counts, even before the start
        let started: AVAudioPlayer? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let p = try? AVAudioPlayer(contentsOf: url) else {
                    cont.resume(returning: nil)
                    return
                }
                p.volume = volume
                cont.resume(returning: p.play() ? p : nil)
            }
        }
        guard let p = started else {
            log.error("couldn't play \(url.lastPathComponent, privacy: .public)")
            return true   // nothing to wait for; the queue moves on
        }
        let stoppedEarly = lock.withLock {
            player = p
            return stopped
        }
        if stoppedEarly {
            p.stop()
            return false
        }
        while true {
            try? await Task.sleep(for: .milliseconds(50))
            let (playing, wasStopped) = lock.withLock { (p.isPlaying, stopped) }
            if wasStopped { return false }
            if !playing { break }
        }
        lock.withLock { if player === p { player = nil } }
        return true
    }

    public func stop() async {
        lock.withLock {
            stopped = true
            player?.stop()
            player = nil
        }
    }
}
