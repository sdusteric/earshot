/// The last few seconds of mic audio, in memory only. Positions are absolute
/// sample counts since the mic opened, so a segment can be cut out later.
public struct SampleRing: Sendable {
    public let capacity: Int
    private var buffer: [Float]
    private var head = 0   // where the next sample goes
    public private(set) var total = 0

    public init(seconds: Double = 10, rate: Int = 16_000) {
        capacity = max(1, Int(seconds * Double(rate)))
        buffer = [Float](repeating: 0, count: capacity)
    }

    public var oldest: Int { max(0, total - capacity) }

    public mutating func append(_ s: [Float]) {
        for x in s.suffix(capacity) {
            buffer[head] = x
            head = (head + 1) % capacity
        }
        total += s.count
    }

    /// Samples from `from` up to, not including, `to` (default: the newest).
    public func samples(from: Int, to: Int? = nil) -> [Float] {
        let lo = max(from, oldest), hi = min(to ?? total, total)
        guard lo < hi else { return [] }
        let startSlot = (head - (total - lo) + capacity * 2) % capacity
        return (0..<(hi - lo)).map { buffer[(startSlot + $0) % capacity] }
    }
}

/// Stage 1 of the cascade: lets audio through to the VAD only when it is
/// louder than a quiet room, and for a few chunks after.
public struct EnergyGate: Sendable {
    public var threshold: Float
    public var hangover: Int
    private var quiet = Int.max / 2

    public init(threshold: Float = 0.008, hangover: Int = 8) {
        self.threshold = threshold
        self.hangover = hangover
    }

    public mutating func admit(_ chunk: [Float]) -> Bool {
        if Self.rms(chunk) >= threshold {
            quiet = 0
            return true
        }
        quiet += 1
        return quiet <= hangover
    }

    public static func rms(_ c: [Float]) -> Float {
        guard !c.isEmpty else { return 0 }
        var sum: Float = 0
        for x in c { sum += x * x }
        return (sum / Float(c.count)).squareRoot()
    }
}

/// Cuts a stream of any chunk sizes into the fixed chunks the VAD needs.
public struct Chunker: Sendable {
    public let size: Int
    private var pending: [Float] = []

    public init(size: Int = 4096) { self.size = size }

    public mutating func push(_ s: [Float]) -> [[Float]] {
        pending += s
        var out: [[Float]] = []
        while pending.count >= size {
            out.append(Array(pending.prefix(size)))
            pending.removeFirst(size)
        }
        return out
    }

    /// What is left over, for example when the hotkey is released.
    public mutating func drain() -> [Float] {
        defer { pending.removeAll() }
        return pending
    }
}
