import Foundation

/// What a command's clip looks like before it is transcribed.
public enum ClipLevel {
    /// The clip came through a noise gate that opened late: a run of exact
    /// zeros (0.1 s or more), then speech within 0.1 s (a 20 ms stretch at
    /// -50 dBFS or louder; a real gate fades in over a few milliseconds). A
    /// live mic always has some noise, so it never sends exact zeros, and a
    /// mic that starts up with zeros goes on to quiet room noise, not straight
    /// into speech. Such a clip likely lost its first word, so the parser
    /// reads it more tolerantly.
    public static func gated(_ s: [Float], minRun: Int = 1_600) -> Bool {
        let frame = 320, lookAhead = 1_600
        var run = 0
        var i = 0
        while i < s.count {
            if s[i] == 0 { run += 1; i += 1; continue }
            if run >= minRun {
                var start = i
                while start + frame <= min(s.count, i + lookAhead + frame) {
                    var sum: Float = 0
                    for x in s[start..<(start + frame)] { sum += x * x }
                    if (sum / Float(frame)).squareRoot() >= 0.003 { return true }
                    start += frame / 2
                }
            }
            run = 0
            i += 1
        }
        return false
    }

    /// The clip with silence after it up to `minSamples`. Parakeet returns
    /// nothing at all for a clip much under 2 s ("Yes." alone), and the
    /// silence costs it almost no time.
    public static func padded(_ s: [Float], to minSamples: Int = 40_000) -> [Float] {
        s.count >= minSamples ? s : s + [Float](repeating: 0, count: minSamples - s.count)
    }
}
