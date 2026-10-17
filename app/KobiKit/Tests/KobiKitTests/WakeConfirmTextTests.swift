import Testing
@testable import KobiKit

/// Listener.wakeWords and confirmsWake on heads the wake bench's recognizers wrote (Apple's
/// SpeechTranscriber and Parakeet), for "Hey Kobi" and for the near-misses, mentions and
/// collisions. Two tiers: a greeting and the name written as such (literal, with the words
/// after it), and the name alone first (bare), which may chime but never sends its words.
@Suite struct WakeConfirmTextTests {
    /// How the bench's recognizers wrote "Hey Kobi" with the name spelled as such. Apple wrote
    /// "Kobe" for most of them, and "Koby" now and then.
    @Test(arguments: [
        "Hey, Kobe.", "Okay, Kobe.", "Hi, Kobe.", "Hey Kobi", "Hey, Kobe, stop.", "Okay, Kobe, be quiet.",
        "Hey Kobe, how are you?", "Hi Kobe.", "Okay, Kobe status.", "Hey, Kobe, tell the website.", "Hey Koby.",
        "Hey Koby, tell the blog.", "K Kobe, status.", "K, Kobe.", "I, Kobe, switch to the app.", "Eight Kobe.",
        "High Kobe, any updates?", "A Kobe.", "OK Kobi, be quiet",
    ])
    func wakesSpelledAsTheNameAreLiteral(_ head: String) {
        #expect(Listener.confirmsWake(head))
        #expect(Listener.wakeRemainder(head) != nil)
        if case .literal? = Listener.wakeWords(head) {} else { Issue.record("not literal: \(head)") }
    }

    /// After a weak greeting (a, i, k, eight, 8, hate, high, hay: words that start ordinary
    /// sentences too), the name sends what follows only when it stands apart: a comma, a stop,
    /// ? or ! after it, or nothing. Run into the sentence it is window only, as the name alone
    /// first is: "Kobe" is a common word ("a Kobe steak"). After hey, hi, ok and okay the name
    /// run into the sentence still sends it: recognizers often write a real command with no
    /// comma ("Hey Kobe pause.", "Okay Kobe status."), and requiring one cost 25 of 440 tune
    /// commands in clean and 20 in quiet on the wake bench (5.7 and 4.5 points).
    @Test(arguments: ["A Kobe beef burger, please.", "Eight Kobe sliders, please.", "A Kobe Bryant jersey for my son.",
                      "A Kobe steak, medium rare.", "8 Kobe sliders.", "I Kobe is listening.", "K Kobe what time is it"])
    func aWeakGreetingRunIntoTheSentenceIsWindowOnly(_ head: String) {
        #expect(Listener.wakeWords(head) == .bare)
        #expect(Listener.wakeRemainder(head) == nil)
        #expect(Listener.finishRemainder(head, plain: head, second: head, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(head, passedOnWords: false) == nil)
        #expect(Listener.stripWake(head) != nil)
    }

    @Test func aStrongGreetingRunIntoTheSentenceStillSends() {
        #expect(Listener.wakeWords("Hey Kobe pause.") == .literal(remainder: "pause."))
        #expect(Listener.wakeWords("Okay Kobe status.") == .literal(remainder: "status."))
        #expect(Listener.wakeWords("A Kobe, status.") == .literal(remainder: "status."))
    }

    /// The name first with no greeting, standing apart, passes the confirm but never sends its
    /// words: a mention whose start a noise gate cut off reads the same ("can Kobi read my
    /// mail" heard as "Kobe, read my mail.").
    @Test(arguments: ["Kobe.", "Kobe, stop.", "Kobi", "Koby, what time is it?", "Kobe, read that again.",
                      "Kobe, read my mail.", "Kobe, to run the test.", "Kobe, approve it."])
    func theNameAloneFirstSetApartIsWindowOnly(_ head: String) {
        #expect(Listener.confirmsWake(head))
        #expect(Listener.wakeWords(head) == .bare)
        #expect(Listener.wakeRemainder(head) == nil)
        #expect(Listener.finishRemainder(head, plain: head, second: head, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(head, passedOnWords: false) == nil)
    }

    /// Near-misses as the bench's recognizers wrote them: other names and everyday words. None
    /// of them pass, the names that sound like Kobi included ("Hey, Colby." is now and then a
    /// "Hey Kobi", and "Toby." a gated one), since they cost more near-misses than they win wakes.
    @Test(arguments: [
        "Copy that.", "Cool beans.", "Okay, go be quiet.", "Hey, go be quiet.", "Cody, approve it.", "Colby.",
        "Okay, cookie.", "Hey, go be nice.", "Nobody knows.", "Hey, Toby.", "Hey, Goldie.", "Hey, Cody.",
        "Hey, nobody's here.", "Hey, Jody.", "Hi Colby, how are you?", "Hey, Robbie.", "Hey, Gobi.", "Hey, Colby.",
        "Okay, Cody, go ahead.", "Hey, Bobby, stop.", "Okay, Colby, stop.", "Hey coach, what's up?", "Toby.",
        "Toby, stop.", "Hey, Kofi.", "Hey Obi.", "Hey, nobody stop.", "Hey, Cuba is warm.", "Take Kobe to the vet.",
        "Like Kobe, run the tests.",
    ])
    func nearMissesFail(_ head: String) {
        #expect(!Listener.confirmsWake(head))
        #expect(Listener.wakeWords(head) == nil)
    }

    /// Collisions: "Kobe" and "Coby" are said the same as "Kobi". "Hey Kobe" wakes, and the words
    /// after it are a command, as for "Hey Kobi". "Coby" is not taken.
    @Test func aCollisionWakesAsTheNameDoes() {
        #expect(Listener.wakeWords("Hey, Kobe, run the test.") == .literal(remainder: "run the test."))
        #expect(Listener.wakeWords("Okay, Kobe, approve it.") == .literal(remainder: "approve it."))
        #expect(Listener.wakeWords("Kobe, stop.") == .bare)
        #expect(Listener.wakeWords("Hey Coby, stop.") == nil)
    }

    /// A mention: the name run into a sentence, or later than the start. Never a wake, and
    /// never a command at finish, wherever the name is.
    @Test(arguments: [
        "Kobe is listening.", "Yes, Kobe is listening.", "Is Kobe still running?", "I think Kobe heard you.",
        "Open Kobe settings.", "Kobe Bryant scored.", "Tell me when Kobe is ready.", "Can Kobe read my mail?",
        "Kobe beef is expensive.", "I asked Kobe yesterday.", "Kobe heard you.", "We flew to Kobe last.",
        "My dog, Kobe.", "Kobe's still running.", "Kobe still running.", "did you ask kobi to run the tests",
        "Hey there Kobe what's the status", "Kobi said the tests passed.",
    ])
    func mentionsFail(_ head: String) {
        #expect(!Listener.confirmsWake(head))
        #expect(Listener.finishRemainder(head, plain: head, second: head, passedOnWords: true) == nil)
    }

    /// wakeRemainder gives the words after the name, as written, in the literal tier.
    @Test(arguments: [
        ("Hey Kobi", ""), ("Hey, Kobe.", ""), ("Hey, Kobe, what's everyone doing?", "what's everyone doing?"),
        ("Hey kobe run the tests", "run the tests"), ("Hi Kobe, stop.", "stop."), ("Okay Kobe.", ""),
        ("Okay, Kobe status.", "status."), ("  OK Kobi , be quiet ", "be quiet"), ("Hey Koby, tell the blog.", "tell the blog."),
        ("K Kobe, status.", "status."), ("Hey Kobe... yes", "yes"), ("Hey, Kobe is listening.", "is listening."),
    ])
    func theRemainderIsWhatFollowsTheName(_ text: String, _ rest: String) {
        #expect(Listener.wakeRemainder(text) == rest)
        #expect(Listener.wakeWords(text) == .literal(remainder: rest))
        #expect(Listener.confirmsWake(text))
    }

    @Test(arguments: ["Hey, Toby.", "Kobe is listening.", "Run the tests.", "", "Hey there, Kobe.", "Copy that, run the test."])
    func noRemainderWithoutTheName(_ text: String) {
        #expect(Listener.wakeRemainder(text) == nil)
        #expect(!Listener.confirmsWake(text))
    }

    @Test func noWordsFail() {
        #expect(!Listener.confirmsWake(""))
        #expect(!Listener.confirmsWake(" , . "))
        #expect(Listener.wakeWords("Hey") == nil)
    }

    /// At finish, a wake the confirmer passed on its words looks for a greeting and the name
    /// written as such in the unboosted words (plain, or the boosted ones when the boost changed
    /// nothing), then in the second hearing. The command is the boosted words after the name
    /// when they have it too.
    @Test(arguments: [
        ("Hey Kobe, what's everyone doing?", nil, nil, "what's everyone doing?"),
        ("Hey Colby what's everyone doing", "Hey Kobe. What's everyone doing", nil, "What's everyone doing"),
        ("Hey Colby what's everyone doing", nil, "Hey Kobe, what's everyone doing?", "what's everyone doing?"),
        ("Hey reflow summarized the last session.", "Hey Kobe summarized the last session.", nil, "summarized the last session."),
        ("Hey Kobe, stop the blog", "Hey Kobe, stop the build", nil, "stop the blog"),
        ("", nil, "Hey Kobe, pause.", "pause."),
        ("Hey Kobi", "Hey kobe, run the tests", nil, ""),
    ] as [(String, String?, String?, String)])
    func aWakePassedOnWordsFindsTheLiteralNameInAnUnboostedHearing(_ text: String, _ plain: String?, _ second: String?, _ rest: String) {
        #expect(Listener.finishRemainder(text, plain: plain, second: second, passedOnWords: true) == rest)
    }

    /// No command when only the name alone first, or nothing of it, is heard, in any hearing.
    @Test(arguments: ["Which sessions are waiting", "Hey Colby, what's everyone doing", "", "The tests ran fine in the end",
                      "Kobe which sessions are waiting", "Kobe tell the blog to run the tests", "Kobe, pause.",
                      "Kobe. To run the tests.", "Toby, approve it."])
    func aTranscriptWithNoLiteralNameIsNoCommand(_ text: String) {
        #expect(Listener.finishRemainder(text, plain: text, second: text, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(text, passedOnWords: false) == nil)
    }

    /// A session named kobe makes the boost write the name over another ("Hey Toby, approve
    /// it."): the boosted words alone never make a command.
    @Test(arguments: [
        ("Hey Kobe, approve it", "Hey Toby, approve it", nil),
        ("Hey Kobe, approve it", "Hey Toby, approve it", "Hey, Toby. Approve it."),
        ("Okay, Kobe stop the blog", "Okay, Colby, stop the build.", "Okay, Colby, stop the build."),
        ("Hey Kobe, approve it", "Kobe, approve it", nil),
    ] as [(String, String, String?)])
    func theBoostedWordsAloneAreNoCommand(_ text: String, _ plain: String, _ second: String?) {
        #expect(Listener.finishRemainder(text, plain: plain, second: second, passedOnWords: true) == nil)
        #expect(Listener.finishRemainder(text, plain: plain, second: second, passedOnWords: false) == nil)
    }

    /// A wake that passed on the strict score alone decides on the unboosted words too, and
    /// takes the command from them when the boost lost the name.
    @Test(arguments: [
        ("Okay reflow what's the status of the blog", "Okay Kobe, what's the status of the build?", "what's the status of the build?"),
        ("Hey Kobe, stop the blog", "Hey Kobe, stop the build", "stop the blog"),
        ("Hey Kobe, stop the blog", nil, "stop the blog"),
    ] as [(String, String?, String)])
    func aWakePassedOnTheScoreAloneDecidesOnTheUnboostedWords(_ text: String, _ plain: String?, _ rest: String) {
        #expect(Listener.finishRemainder(text, plain: plain, passedOnWords: false) == rest)
    }

    /// A wake that passed on the strict score alone does not look at the second hearing.
    @Test(arguments: ["Kobe which sessions are waiting", "Hey Colby, what's everyone doing", "Copy that, run the tests"])
    func aWakePassedOnTheScoreAloneIgnoresTheSecondHearing(_ text: String) {
        #expect(Listener.finishRemainder(text, second: "Hey Kobe, what's everyone doing?", passedOnWords: false) == nil)
    }

    /// Names with a spelling of the name in them are left out of a wake's own clip's vocabulary.
    @Test func namesThatSpellTheNameAreLeftOut() {
        #expect(Listener.wakeVocabulary(["billing service", "kobi", "Kobe app", "kobi-web", "Koby", "blog", "Colby", "kob", "Coby", "KobiKit"])
                == ["billing service", "blog", "Colby", "kob"])
    }
}
