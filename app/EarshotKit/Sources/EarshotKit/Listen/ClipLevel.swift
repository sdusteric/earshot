import Foundation

/// What a command's clip looks like before it is transcribed.
public enum ClipLevel {
    /// The clip came through a noise gate that opened late: a run of exact
    /// zeros (0.1 s or more), then sound at once. A live mic always has some
    /// noise, so it never sends exact zeros, and a mic that starts up with
    /// zeros goes on to quiet room noise, not straight into speech. Such a
    /// clip likely lost its first word, so the parser reads it more tolerantly.
    public static func gated(_ s: [Float], minRun: Int = 1_600) -> Bool {
        var run = 0
        var i = 0
        while i < s.count {
            if s[i] == 0 { run += 1; i += 1; continue }
            if run >= minRun {
                let end = min(s.count, i + 320)
                var sum: Float = 0
                for x in s[i..<end] { sum += x * x }
                if (sum / Float(end - i)).squareRoot() >= 0.003 { return true }
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
