import Foundation

/// The loudness of what Kobi plays or hears, from 0 (silence) to 1, for
/// the orb. One side writes it a few dozen times a second and the orb reads
/// it every frame, so it is a plain locked value instead of a stream.
public final class AudioLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Float = 0

    public init() {}

    public var value: Float { lock.withLock { current } }

    public func set(_ v: Float) {
        let v = v.isFinite ? min(max(v, 0), 1) : 0
        lock.withLock { current = v }
    }

    /// Maps decibels onto 0 to 1: `floor` and below is silence, `ceiling` and
    /// above is full.
    public static func fromDecibels(_ db: Float, floor: Float = -50, ceiling: Float = -10) -> Float {
        guard db.isFinite, ceiling > floor else { return 0 }
        return min(max((db - floor) / (ceiling - floor), 0), 1)
    }

    /// The level of a chunk of mic samples.
    public static func fromSamples(_ chunk: [Float]) -> Float {
        let rms = EnergyGate.rms(chunk)
        guard rms > 0 else { return 0 }
        return fromDecibels(20 * log10(rms))
    }
}
