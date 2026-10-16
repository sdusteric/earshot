import Testing
@testable import EarshotKit

/// Listener.wakeWords and confirmsWake on heads the wake bench's recognizers wrote (Apple's
/// SpeechTranscriber and Parakeet), for "Hey Earshot" and for the near-misses and mentions that
/// must not wake. Two tiers: a greeting and the phrase written as such (literal, with the words
/// after it), and "Earshot" alone first (bare) or words that only sound like it (sound-alike),
/// which may chime but never send their words.
@Suite struct WakeConfirmTextTests {
    /// How the bench's recognizers wrote "Hey Earshot" with the phrase spelled as such.
    @Test(arguments: [
        "Hey Earshot", "Hey, Earshot, what's everyone doing?", "OK Earshot, be quiet", "Hey ear shot, run the tests",
        "High earshot, any updates?", "Hay earshot.", "Hate ear shot.", "High ear shot, switch to the app session",
        "Okay ear shot.", "Eight ear shot.", "Hi Earshot, any updates?", "Hey air shot.", "Hey earshots",
    ])
    func misheardWakesSpelledAsThePhraseAreLiteral(_ head: String) {
        #expect(Listener.confirmsWake(head))
        #expect(Listener.wakeRemainder(head) != nil)
        if case .literal? = Listener.wakeWords(head) {} else { Issue.record("not literal: \(head)") }
    }

    /// A greeting, then a word or two that sound like ARXT but are spelled otherwise.
    @Test(arguments: [
        "Hate your shot.", "Hey your shot", "Okay your shot, status", "Eight year shot.", "Hey, you're shot. Stop.",
        "8 year shot", "Hey your shots", "A your shot.", "Hey airshot.",
    ])
    func misheardWakesThatOnlySoundLikeItAreSoundAlike(_ head: String) {
        #expect(Listener.confirmsWake(head))
        #expect(Listener.wakeWords(head) == .soundAlike)
        #expect(Listener.wakeRemainder(head) == nil)
    }

    /// The second safety review's sentences: they sound like the phrase, so they may chime,
    /// but the words after them are never a command ("Approve it." would approve a prompt).
    @Test(arguments: [
        "Okay, your shot. Approve it.", "Hey, we're shot", "Hey, our shots are ready.", "Okay, or shot",
        "Hey, wear shot", "Okay, you're shot, delete the branch", "okay, your shot, run the tests",
        "hey, your shot, approve it", "Hey your shot, what's everyone doing?",
    ])
    func soundAlikesAreNeverLiteral(_ text: String) {
        #expect(Listener.wakeWords(text) == .soundAlike)
        #expect(Listener.wakeRemainder(text) == nil)
        #expect(Listener.finishRemainder(text, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(text, plain: text, second: text, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(text, passedOnWords: false) == nil)
    }

    /// "Earshot" first with no greeting, standing apart, passes the confirm but never sends its
    /// words: a mention whose start a noise gate cut off reads the same ("did you ask earshot to
    /// run the tests" heard as "Ear shot. To run.").
    @Test(arguments: ["Earshot", "Earshot.", "Earshot, stop.", "Ear shot.", "Ear shot, what time is it?",
                      "Ear shot. To run.", "Earshot, approve it."])
    func aBareEarshotSetApartIsWindowOnly(_ head: String) {
        #expect(Listener.confirmsWake(head))
        #expect(Listener.wakeWords(head) == .bare)
        #expect(Listener.wakeRemainder(head) == nil)
        #expect(Listener.finishRemainder(head, plain: head, second: head, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(head, passedOnWords: false) == nil)
    }

    @Test(arguments: [
        "Here's a shot.", "A hair shot.", "Her shot, summarized the last session.", "Hey Urshad.",
        "Hey, fair shot.", "Hey Earl's hot.", "Hey ear shut up.", "Hey, ear shock.", "Hey Ashton, how are you?",
        "Nice shot, stop.", "Hey, her shirt.", "Airshot, what's the status?", "Air shot.", "Hey Marshall.",
    ])
    func nearMissesFail(_ head: String) {
        #expect(!Listener.confirmsWake(head))
        #expect(Listener.wakeWords(head) == nil)
    }

    /// Everyday sentences with "shot" that fired the spotter and that Apple's recognizer heard
    /// word for word: with a verb first, or "you shot" and "a shot" (AXT, not ARXT), they are
    /// sentences, and the rest of them would go out as a command. The near-misses in
    /// tests/wake/phrases.tsv that the words alone can tell apart.
    @Test(arguments: [
        "Take a shot, run the test.", "Take a shot at the login bug.", "Hey you shot the deploy.",
        "Get your shot today.", "Hey, a shot of the bill.", "Take your shot.", "Pay your shot.",
        "My earshot, switch to the app session", "Eat your shot.", "Paint your shot.", "Make your shot.",
        "Hey, you shot the deploy.", "Okay, you shot first.", "Nice shot, run it again.", "Good shot.",
        "Hey, what a shot.", "Okay, your turn to shoot.", "Hey, I shot it over.", "Hey, are you sure?",
        "High shot.", "Hey, hot shot.", "Hey, we shot the video.", "Eight shots.",
        "Hey, you're short on time.", "Hey, you shot.", "Hey, a shot.", "Take a shot, run the test",
        "take your shot", "get your shot today", "hey, you shot the deploy", "hey, a shot of the bill",
        "Maybe your shot.", "I your shot.", "Hey, nice shot.", "Hey, big shot, run it.", "Hey, mug shot.",
    ])
    func everydayShotSentencesFail(_ head: String) {
        #expect(!Listener.confirmsWake(head))
        #expect(Listener.wakeRemainder(head) == nil)
    }

    /// Near-misses whose words are the wake phrase's: the rule can't tell them from a wake,
    /// so only the spotter's score keeps them out (the bench counts how often). "Hey, your
    /// shot is next" is a sound-alike, so at most it chimes; "Hey, ear shot." is the phrase.
    @Test func sentencesMadeOfThePhrasesWordsPass() {
        #expect(Listener.wakeWords("Hey, your shot is next.") == .soundAlike)
        #expect(Listener.wakeWords("Hey, ear shot.") == .literal(remainder: ""))
    }

    /// A mention: the phrase run into a sentence, or later than the start. Never a wake, and
    /// never a command at finish, wherever the word is.
    @Test(arguments: [
        "Earshot is listening.", "Earshot of the door.", "Ear shot to run the test.", "Earshot app is on my...",
        "Within earshot of the door.", "The earshot app is on my menu bar.", "Is earshot still running?",
        "Yes, earshot is listening.", "I think earshot heard you.", "did you ask earshot to run the tests",
        "Hey there earshot what's the status",
    ])
    func mentionsFail(_ head: String) {
        #expect(!Listener.confirmsWake(head))
    }

    @Test(arguments: [
        "Within earshot of the door.", "The earshot app is on my menu bar.", "Is earshot still running?",
        "Yes, earshot is listening.", "I think earshot heard you.", "did you ask earshot to run the tests",
        "Hey there earshot what's the status", "Take a shot run the tests", "Your shot, run the tests.",
    ])
    func aMentionPastTheFirstWordIsNoCommandAtFinish(_ text: String) {
        #expect(Listener.finishRemainder(text, plain: text, second: text, passedOnWords: true) == nil)
    }

    /// wakeRemainder gives the words after the phrase, as written, in the literal tier.
    @Test(arguments: [
        ("Hey Earshot", ""), ("Hey Earshot.", ""), ("Hey, Earshot, what's everyone doing?", "what's everyone doing?"),
        ("Hey ear shot run the tests", "run the tests"), ("Hi Earshot, stop.", "stop."), ("Okay Earshot.", ""),
        ("Hey ear shot, what time is it?", "what time is it?"), ("  OK Earshot , be quiet ", "be quiet"),
        ("Hey earshots, status", "status"), ("Hey air shot... yes", "yes"),
        ("High ear shot switch to the app", "switch to the app"), ("Hey, earshot is listening.", "is listening."),
    ])
    func theRemainderIsWhatFollowsThePhrase(_ text: String, _ rest: String) {
        #expect(Listener.wakeRemainder(text) == rest)
        #expect(Listener.wakeWords(text) == .literal(remainder: rest))
        #expect(Listener.confirmsWake(text))
    }

    @Test(arguments: ["Hey, ear shock.", "Earshot is listening.", "Run the tests.", "", "Hey there, nice shot.",
                      "Take a shot, run the test.", "Take your shot, run the test."])
    func noRemainderWithoutThePhrase(_ text: String) {
        #expect(Listener.wakeRemainder(text) == nil)
        #expect(!Listener.confirmsWake(text))
    }

    @Test func noWordsFail() {
        #expect(!Listener.confirmsWake(""))
        #expect(!Listener.confirmsWake(" , . "))
        #expect(Listener.wakeWords("Hey") == nil)
    }

    /// At finish, a wake the confirmer passed on its words looks for a greeting and the phrase
    /// written as such in the unboosted words (plain, or the boosted ones when the boost changed
    /// nothing), then in the second hearing. The command is the boosted words after the phrase
    /// when they have it too.
    @Test(arguments: [
        ("Hey Earshot, what's everyone doing?", nil, nil, "what's everyone doing?"),
        ("Hearsay what's everyone doing", "Hey Earshot. What's everyone doing", nil, "What's everyone doing"),
        ("Hearsay what's everyone doing", nil, "Hey Earshot, what's everyone doing?", "what's everyone doing?"),
        ("Hey your shot, what's everyone doing", "Hey your shot what's", "Hey earshot, what's everyone doing", "what's everyone doing"),
        ("Hey reflow summarized the last session.", "Hey Earshot summarized the last session.", nil, "summarized the last session."),
        ("Hey Earshot, stop the blog", "Hey Earshot, stop the build", nil, "stop the blog"),
        ("", nil, "Hey Earshot, pause.", "pause."),
        ("Hey Earshot", "Hey earshot, run the tests", nil, ""),
    ] as [(String, String?, String?, String)])
    func aWakePassedOnWordsFindsTheLiteralPhraseInAnUnboostedHearing(_ text: String, _ plain: String?, _ second: String?, _ rest: String) {
        #expect(Listener.finishRemainder(text, plain: plain, second: second, passedOnWords: true) == rest)
    }

    /// No command when only "Earshot" first, a sound-alike or nothing of the phrase is heard, in any hearing.
    @Test(arguments: ["Which sessions are waiting", "Hearsay what's everyone doing", "", "The tests ran fine in the end",
                      "Okay, your shot. Approve it.", "Earshot which sessions are waiting", "Earshot tell the blog to run the tests",
                      "Ear shot run the tests", "Earshot, pause.", "Ear shot. To run the tests."])
    func aTranscriptWithNoLiteralPhraseIsNoCommand(_ text: String) {
        #expect(Listener.finishRemainder(text, plain: text, second: text, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(text, passedOnWords: false) == nil)
    }

    /// A session named earshot makes the boost write the phrase over a sound-alike: the boosted
    /// words alone never make a command.
    @Test(arguments: [
        ("Okay, earshot stop the blog", "Okay, you're shot, stop the build.", nil),
        ("Okay, earshot stop the blog", "Okay, you're shot, stop the build.", "Okay, your shot. Stop the build."),
        ("Hey earshot, approve it", "Hey your shot, approve it", "Hey, your shot. Approve it."),
        ("Hey earshot, approve it", "Earshot, approve it", nil),
    ] as [(String, String, String?)])
    func theBoostedWordsAloneAreNoCommand(_ text: String, _ plain: String, _ second: String?) {
        #expect(Listener.finishRemainder(text, plain: plain, second: second, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(text, plain: plain, second: second, passedOnWords: false) == nil)
    }

    /// A wake that passed on the strict score alone decides on the unboosted words too, and
    /// takes the command from them when the boost lost the phrase.
    @Test(arguments: [
        ("Okay reflow what's the status of the blog", "Okay earshot, what's the status of the build?", "what's the status of the build?"),
        ("Hey Earshot, stop the blog", "Hey Earshot, stop the build", "stop the blog"),
        ("Hey Earshot, stop the blog", nil, "stop the blog"),
    ] as [(String, String?, String)])
    func aWakePassedOnTheScoreAloneDecidesOnTheUnboostedWords(_ text: String, _ plain: String?, _ rest: String) {
        #expect(Listener.finishRemainder(text, plain: plain, passedOnWords: false) == rest)
    }

    /// A wake that passed on the strict score alone does not look at the second hearing.
    @Test(arguments: ["Earshot which sessions are waiting", "Hearsay what's everyone doing", "Take a shot run the tests",
                      "Hey your shot, what's everyone doing?"])
    func aWakePassedOnTheScoreAloneIgnoresTheSecondHearing(_ text: String) {
        #expect(Listener.finishRemainder(text, second: "Hey Earshot, what's everyone doing?", passedOnWords: false) == nil)
    }

    /// Names that spell the wake phrase are left out of a wake's own clip's vocabulary.
    @Test func namesThatSpellTheWakePhraseAreLeftOut() {
        #expect(Listener.wakeVocabulary(["billing service", "earshot", "Earshot Spike", "earshots", "Air Shot", "airshot",
                                         "blog", "ear", "shot"]) == ["billing service", "blog", "ear", "shot"])
    }
}
