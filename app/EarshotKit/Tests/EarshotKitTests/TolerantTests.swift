import Foundation
import Testing
@testable import EarshotKit

/// What a webcam mic with its noise gate on made of real commands, and the
/// bench's degraded speech (tests/hearing).
@Suite struct TolerantTests {
    static let known = ["wedding", "guest confirmation email", "blog", "Projects", "reflow", "finebrief", "earshot",
                        "billing service", "your home folder", "diet journal", "kairos", "Daze", "Ardo", "Launch",
                        "What's next", "Project status"]

    @Test(arguments: [
        // "How are all the other sessions going?", heard on the real mic.
        "Or have all the other sentences going.", "Are the outer sections going?", "Are the other seconds going?",
        // "What's everyone doing?"
        "How'd everyone do your right now?", "Everyone up to?",
        // The first words cut off.
        "Other sessions gone.", "All the other sessions going.", "Thing going.", "Status update.",
    ])
    func garbledRollCalls(_ heard: String) {
        #expect(Tolerant.parse(heard, known: Self.known, gated: true) == .status(target: nil))
    }

    @Test func aRollCallMayLoseAllButItsLastWordsWhenGated() {
        #expect(Tolerant.parse("Sessions going.", known: Self.known, gated: true) == .status(target: nil))
        #expect(Tolerant.parse("Sessions going.", known: Self.known, gated: false) == nil)
    }

    @Test(arguments: ["Are you doing?", "You doing today?"])
    func garbledGreetings(_ heard: String) {
        #expect(Tolerant.parse(heard, known: Self.known, gated: true) == .greet)
    }

    @Test(arguments: [
        ("Airshot working on.", "earshot"), ("I at Journal Going.", "diet journal"), ("On Kairos.", "kairos"),
    ])
    func aSessionsStatusByTheSoundOfItsName(_ heard: String, _ name: String) {
        #expect(Tolerant.parse(heard, known: Self.known, gated: true) == .status(target: name))
    }

    /// Gated, a word that opens what was heard may be the end of a name.
    @Test func theEndOfANameAfterAGate() {
        #expect(Tolerant.parse("Shot doing.", known: Self.known, gated: true) == .status(target: "earshot"))
        #expect(Tolerant.parse("Shot doing.", known: Self.known, gated: false) == nil)
    }

    /// A prompt for a session found by sound is only ever asked about.
    @Test(arguments: [
        ("What else do you think we should do for Earshaw?", "earshot", "What else do you think we should do"),
        ("What else do you think we should do for your child?", "earshot", "What else do you think we should do"),
        ("Shot to run the test.", "earshot", "run the test"),
        ("Brief, to commit its work.", "finebrief", "commit its work"),
        ("Service Push the Branch.", "billing service", "Push the Branch"),
    ])
    func sendsBySoundAreAskedFirst(_ heard: String, _ name: String, _ prompt: String) {
        #expect(Tolerant.parse(heard, known: Self.known, gated: true) == .confirmSend(target: name, prompt: prompt))
    }

    @Test(arguments: [
        "I wonder what's for lunch today.", "The weather is nice outside.", "Can you hear me now?", "I'm going home.",
        "Thanks for doing that.", "The other day was fun.", "What should I make for dinner tonight?", "Are you sure?",
        "How are the kids doing?", "Is the oven on?", "My mom is doing well", "Done yet.",
    ])
    func everydayTalkIsNoCommand(_ heard: String) {
        #expect(Tolerant.parse(heard, known: Self.known, gated: true) == nil)
        #expect(Tolerant.parse(heard, known: Self.known, gated: false) == nil)
    }

    /// Never an answer to a permission prompt, never a stop, however it sounds.
    @Test(arguments: ["Yes to earshot.", "Yeah, earshot.", "Two earshot.", "Stop earshot.", "Earshot, stop.",
                      "Tell earshot to stop.", "Shot to stop it."])
    func neverAnswersOrStops(_ heard: String) {
        for gated in [true, false] {
            switch Tolerant.parse(heard, known: Self.known, gated: gated) {
            case .answer?, .stop?, .stopAll?, .send?: Issue.record("\(heard) acted: gated \(gated)")
            default: break
            }
        }
    }
}

@Suite struct ClipLevelTests {
    @Test func shortClipsArePaddedOut() {
        #expect(ClipLevel.padded([0.1, 0.2], to: 5) == [0.1, 0.2, 0, 0, 0])
        #expect(ClipLevel.padded([Float](repeating: 0.1, count: 8), to: 5).count == 8)
    }

    @Test func zerosThenSpeechAtOnceIsAGate() {
        let speech = (0..<8_000).map { Float(sin(Double($0) / 5)) * 0.05 }
        #expect(ClipLevel.gated([Float](repeating: 0, count: 8_000) + speech))
    }

    @Test func roomNoiseIsNoGate() {
        let noise = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
        let speech = (0..<8_000).map { Float(sin(Double($0) / 5)) * 0.05 }
        #expect(!ClipLevel.gated(noise + speech))
        // A mic that starts with a few zeros, then room noise, is no gate either.
        #expect(!ClipLevel.gated([Float](repeating: 0, count: 4_000) + noise + speech))
        // Nor are a few zeros between words.
        #expect(!ClipLevel.gated(speech + [Float](repeating: 0, count: 400) + speech))
    }
}
