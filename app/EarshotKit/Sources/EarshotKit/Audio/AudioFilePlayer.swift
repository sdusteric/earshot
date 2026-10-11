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
        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(contentsOf: url)
        } catch {
            log.error("couldn't play \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return true   // nothing to wait for; the queue moves on
        }
        p.volume = volume
        lock.withLock {
            player = p
            stopped = false
        }
        guard p.play() else { return true }
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
