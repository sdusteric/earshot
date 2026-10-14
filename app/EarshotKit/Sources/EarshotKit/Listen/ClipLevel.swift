import Foundation

/// What a command's clip looks like before it is transcribed.
public enum ClipLevel {
    /// The clip with silence after it up to `minSamples`. Parakeet returns
    /// nothing at all for a clip much under 2 s ("Yes." alone), and the
    /// silence costs it almost no time.
    public static func padded(_ s: [Float], to minSamples: Int = 40_000) -> [Float] {
        s.count >= minSamples ? s : s + [Float](repeating: 0, count: minSamples - s.count)
    }
}
