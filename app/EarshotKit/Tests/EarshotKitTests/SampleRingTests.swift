import Testing
@testable import EarshotKit

@Suite struct SampleRingTests {
    @Test func keepsTheNewestSamples() {
        var r = SampleRing(seconds: 1, rate: 10)   // 10 samples
        r.append((0..<7).map(Float.init))
        r.append((7..<15).map(Float.init))
        #expect(r.total == 15)
        #expect(r.oldest == 5)
        #expect(r.samples(from: 0) == (5..<15).map(Float.init))
        #expect(r.samples(from: 8, to: 11) == [8, 9, 10])
        #expect(r.samples(from: 14, to: 99) == [14])
        #expect(r.samples(from: 20).isEmpty)
    }

    @Test func aLongAppendKeepsItsTail() {
        var r = SampleRing(seconds: 1, rate: 4)
        r.append((0..<10).map(Float.init))
        #expect(r.samples(from: 0) == [6, 7, 8, 9])
    }

    @Test func gateOpensOnSoundAndStaysOpenBriefly() {
        var g = EnergyGate(threshold: 0.1, hangover: 2)
        let quiet = [Float](repeating: 0.01, count: 100), loud = [Float](repeating: 0.5, count: 100)
        do { let r = g.admit(quiet); #expect(!r) }
        do { let r = g.admit(loud); #expect(r) }
        do { let r = g.admit(quiet); #expect(r) }
        do { let r = g.admit(quiet); #expect(r) }
        do { let r = g.admit(quiet); #expect(!r) }
    }

    @Test func chunkerCutsFixedChunksAndDrainsTheRest() {
        var c = Chunker(size: 4)
        do { let r = c.push([1, 2, 3]); #expect(r.isEmpty) }
        do { let r = c.push([4, 5, 6, 7, 8, 9]); #expect(r == [[1, 2, 3, 4], [5, 6, 7, 8]]) }
        do { let r = c.drain(); #expect(r == [9]) }
        do { let r = c.drain(); #expect(r.isEmpty) }
    }
}
