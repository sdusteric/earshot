import Foundation
import Testing
@testable import KobiKit

actor FakeModel: CommandModel {
    private(set) var asked: [String] = []
    private(set) var prewarmed = 0
    let available: Bool
    let answer: Command?
    init(available: Bool = true, answer: Command?) { self.available = available; self.answer = answer }
    var isAvailable: Bool { available }
    func prewarm(sessions: [String]) async { prewarmed += 1 }
    func parse(_ text: String, sessions: [String]) async -> Command? { asked.append(text); return answer }
}

actor SlowCommandModel: CommandModel {
    var isAvailable: Bool { true }
    func prewarm(sessions: [String]) async {}
    func parse(_ text: String, sessions: [String]) async -> Command? {
        try? await Task.sleep(for: .seconds(5))
        return .status(target: nil)
    }
}

@Suite struct CommandParserTests {
    @Test func theGrammarWinsWithoutAskingTheModel() async {
        let model = FakeModel(answer: .unknown)
        let p = CommandParser(model: model)
        #expect(await p.parse("Tell blog to deploy.", sessions: ["blog"]) == .send(target: "blog", prompt: "deploy"))
        #expect(await model.asked.isEmpty)
    }

    @Test func theModelGetsWhatTheGrammarMissed() async {
        let model = FakeModel(answer: .send(target: nil, prompt: "run the tests"))
        let p = CommandParser(model: model)
        #expect(await p.parse("Run the tests.", sessions: ["blog"]) == .send(target: nil, prompt: "run the tests"))
        #expect(await model.asked == ["Run the tests."])
    }

    /// Garbled words are read tolerantly before the model is asked: it is quicker, and safer.
    @Test func theTolerantReadingComesBeforeTheModel() async {
        let model = FakeModel(answer: .send(target: "blog", prompt: "are the other seconds going"))
        let p = CommandParser(model: model)
        #expect(await p.parse("Are the other seconds going?", sessions: ["blog"]) == .status(target: nil))
        // A session named earshot (any name: this is name matching, not the wake), cut to "shot".
        #expect(await p.parse("Shot to run the tests.", sessions: ["earshot"], gated: true)
                == .confirmSend(target: "earshot", prompt: "run the tests"))
        #expect(await model.asked.isEmpty)
    }

    /// The tolerant reading takes the words heard before the boost.
    @Test func theTolerantReadingUsesTheUnboostedWords() async {
        let p = CommandParser(model: nil)
        #expect(await p.parse("Are you wedding?", plain: "Are you doing?", sessions: ["wedding"]) == .greet)
    }

    /// A second recognizer's words are tried before the model, and only when the first make nothing.
    @Test func aSecondHearingIsTriedBeforeTheModel() async {
        let model = FakeModel(answer: .unknown)
        let p = CommandParser(model: model)
        #expect(await p.parse("Pyro mists.", second: "What's everyone doing?", sessions: ["blog"]) == .status(target: nil))
        #expect(await p.parse("How's blog doing?", second: "What's everyone doing?", sessions: ["blog"])
                == .status(target: "blog"))
        #expect(await model.asked.isEmpty)
        // An explicit "didn't get it" from the grammar still stands when the second makes nothing either.
        #expect(await p.parse("Go ahead.", second: "Go ahead.", sessions: ["blog"]) == .unknown)
        #expect(await model.asked.isEmpty)
    }

    /// "Everyone" is the roll call, never a session.
    @Test func theModelsEveryoneIsTheRollCall() async {
        let p = CommandParser(model: FakeModel(answer: .status(target: "everyone")))
        #expect(await p.parse("Uh everyone at the moment", sessions: ["blog"]) == .status(target: nil))
    }

    /// The name boost turned "doing" into the session "wedding".
    @Test func theUnboostedWordsWinWhenTheyMakeACommand() async {
        let model = FakeModel(answer: .status(target: "wedding"))
        let p = CommandParser(model: model)
        #expect(await p.parse("How's everyone wedding", plain: "How's everyone doing", sessions: ["wedding"]) == .status(target: nil))
        #expect(await model.asked.isEmpty)
    }

    @Test func theBoostedNameIsUsedWhenThePlainWordsMakeNoCommand() async {
        let p = CommandParser(model: nil)
        #expect(await p.parse("Tell finebrief to run the tests", plain: "Tell fine brief to run the tests", sessions: ["finebrief"])
                == .send(target: "finebrief", prompt: "run the tests"))
    }

    @Test func theModelOnlySeesTheUnboostedWords() async {
        let model = FakeModel(answer: .unknown)
        let p = CommandParser(model: model)
        _ = await p.parse("How are you feeling about wedding", plain: "How are you feeling about it", sessions: ["wedding"])
        #expect(await model.asked == ["How are you feeling about it"])
    }

    @Test func noModelMeansUnknown() async {
        #expect(await CommandParser(model: nil).parse("Run the tests.", sessions: []) == .unknown)
        let off = FakeModel(available: false, answer: .status(target: nil))
        #expect(await CommandParser(model: off).parse("Run the tests.", sessions: []) == .unknown)
        let failing = FakeModel(answer: nil)
        #expect(await CommandParser(model: failing).parse("Run the tests.", sessions: []) == .unknown)
    }

    /// With no answer from the model (off, failed or too slow), words that say one open
    /// session's whole name are read back and sent on a yes. Nothing is ever sent outright.
    @Test func noModelAnswerReadsBackWhatNamesOneSession() async {
        let sessions = ["billing service", "blog", "What's next", "Showcase site links"]
        let heard = "See if billing service can speed up the query."
        for model in [nil, FakeModel(answer: nil), FakeModel(available: false, answer: nil)] as [FakeModel?] {
            #expect(await CommandParser(model: model).parse(heard, sessions: sessions)
                    == .confirmSend(target: "billing service", prompt: "See if billing service can speed up the query"))
        }
        let p = CommandParser(model: nil)
        // A question about it only reads its status.
        #expect(await p.parse("Is billing service still on the migration?", sessions: sessions)
                == .status(target: "billing service"))
        #expect(await p.parse("Has the blog finished the deploy?", sessions: sessions) == .status(target: "blog"))
        // One word of a name is not the name: titles are often everyday words.
        #expect(await p.parse("See if billing can speed up the query.", sessions: sessions) == .unknown)
        #expect(await p.parse("What else should we do?", sessions: sessions) == .unknown)
        #expect(await p.parse("I have to fix the broken links.", sessions: sessions) == .unknown)
        // Never a pick between two sessions, a stop, a start, or an answer to a permission prompt.
        #expect(await p.parse("Billing service and blog should both rebase.", sessions: sessions) == .unknown)
        #expect(await p.parse("Maybe billing service could halt the deploy.", sessions: sessions) == .unknown)
        #expect(await p.parse("Start a new session and blog to write a post.", sessions: sessions) == .unknown)
        #expect(await p.parse("Sure, let billing service run that.", sessions: sessions) == .unknown)
        #expect(await p.parse("Nah, billing service can't have that.", sessions: sessions) == .unknown)
        // The model's own "didn't get it" stands.
        #expect(await CommandParser(model: FakeModel(answer: .unknown)).parse(heard, sessions: sessions) == .unknown)
    }

    @Test(arguments: [
        ("send", "billing", "run the tests", false, Command.send(target: "billing", prompt: "run the tests")),
        ("send", "", "run the tests", false, .send(target: nil, prompt: "run the tests")),
        ("send", "billing", "", false, .unknown),            // never send an empty prompt
        ("status", "", "", false, .status(target: nil)),
        ("status", "blog", "", false, .status(target: "blog")),
        ("stop", "blog", "", true, .stop(target: "blog", now: true)),
        ("start", "blog", "fix the header", false, .start(project: "blog", prompt: "fix the header")),
        ("start", "", "fix the header", false, .unknown),     // a session needs a folder
        ("approve", "blog", "", false, .answer(allow: true, target: "blog")),
        ("deny", "", "", false, .answer(allow: false, target: nil)),
        ("unknown", "", "", false, .unknown),
        ("dance", "", "", false, .unknown),
    ] as [(String, String, String, Bool, Command)])
    func modelOutputMapsToACommand(_ action: String, _ target: String, _ prompt: String, _ now: Bool, _ expected: Command) {
        #expect(FoundationCommandModel.command(action: action, target: target, prompt: prompt, immediately: now) == expected)
    }

    @Test func prewarmReachesTheModel() async {
        let model = FakeModel(answer: nil)
        await CommandParser(model: model).prewarm(sessions: ["blog"])
        #expect(await model.prewarmed == 1)
    }

    /// Needs Apple Intelligence on: KOBI_TEST_FM=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOBI_TEST_FM"] == "1"))
    func theRealModelUnderstandsAFreeformCommand() async {
        let m = FoundationCommandModel()
        #expect(await m.isAvailable)
        let c = await m.parse("could billing service maybe run the integration tests again",
                              sessions: ["billing service", "blog"])
        guard case .send(let target, let prompt) = c else { Issue.record("got \(String(describing: c))"); return }
        #expect(target?.lowercased().contains("billing") == true)
        #expect(prompt.lowercased().contains("integration tests"))
    }

    // 2026-10-15: the model names a session in full and rewords; what it may and may not do then.
    @Test func aSessionNamedInPartBacksTheModelsFullName() async {
        let p = CommandParser(model: FakeModel(answer: .send(target: "billing service", prompt: "speed up the query")))
        #expect(await p.parse("see if billing can speed up the query", sessions: ["billing service", "blog"])
                == .send(target: "billing service", prompt: "speed up the query"))
    }

    @Test func aRewordedPromptToANamedSessionGoesAsYourWords() async {
        let heard = "billing needs to hear that the API key we use changed today"
        let p = CommandParser(model: FakeModel(answer: .send(target: "billing service", prompt: "tell it the API key changed")))
        #expect(await p.parse(heard, sessions: ["billing service"]) == .send(target: "billing service", prompt: heard))
    }

    @Test func aSessionYouNeverNamedIsDroppedOnlyWhenYouNamedNone() async {
        let invented = FakeModel(answer: .send(target: "blog", prompt: "run the tests again"))
        #expect(await CommandParser(model: invented).parse("run the tests again", sessions: ["blog"])
                == .send(target: nil, prompt: "run the tests again"))
        // Named another: nothing goes.
        #expect(await CommandParser(model: invented).parse("maybe billing could run the tests again", sessions: ["blog", "billing"])
                == .unknown)
    }

    @Test func aStatusAboutASessionYouNeverNamedIsTheRollCall() async {
        let p = CommandParser(model: FakeModel(answer: .status(target: "billing service")))
        #expect(await p.parse("is anybody stuck", sessions: ["billing service"]) == .status(target: nil))
    }

    @Test func aStopIsRightAwayOnlyWhenYouSaidSo() async {
        let p = CommandParser(model: FakeModel(answer: .stop(target: "billing", now: true)))
        #expect(await p.parse("shut billing off for me", sessions: ["billing"]) == .stop(target: "billing", now: false))
        #expect(await p.parse("shut billing off right away", sessions: ["billing"]) == .stop(target: "billing", now: true))
    }

    @Test func aStopFollowedByWhyIsStillAStop() async {
        let p = CommandParser(model: FakeModel(answer: .stop(target: "billing", now: false)))
        #expect(await p.parse("stop billing, it's about to delete the database", sessions: ["billing"])
                == .stop(target: "billing", now: false))
        #expect(await p.parse("pause billing for a sec", sessions: ["billing"]) == .stop(target: "billing", now: false))
        let now = CommandParser(model: FakeModel(answer: .stop(target: "billing", now: true)))
        #expect(await now.parse("please stop billing right now before it deletes everything", sessions: ["billing"])
                == .stop(target: "billing", now: true))
    }

    @Test func aWordInsideANameDoesNotNameIt() async {
        let p = CommandParser(model: FakeModel(answer: .send(target: "finebrief", prompt: "ship it")))
        // By sound it may be asked about first (confirmSend), never sent straight.
        #expect(await p.parse("fine, ship it", sessions: ["finebrief"]) != .send(target: "finebrief", prompt: "ship it"))
        let s = CommandParser(model: FakeModel(answer: .send(target: "billing service", prompt: "restart the service")))
        #expect(await s.parse("restart the service", sessions: ["billing service"]) == .unknown)
    }

    @Test func letItGoIsNoAnswer() {
        #expect(Grammar.windowAnswer("let it go") == nil)
        #expect(Grammar.windowAnswer("let that go") == nil)
        #expect(Grammar.windowAnswer("let it run") == true)
    }

    @Test func stoppingOneThingIsAPrompt() async {
        let heard = "tell whoever is on billing to stop logging so much"
        let p = CommandParser(model: FakeModel(answer: .stop(target: "billing", now: false)))
        #expect(await p.parse(heard, sessions: ["billing"]) == .send(target: "billing", prompt: heard))
    }

    @Test func aPlaceholderTargetIsNoTarget() {
        #expect(CommandParser.clean("unknown") == nil)
        #expect(CommandParser.clean(" ") == nil)
        #expect(CommandParser.clean("blog") == "blog")
    }

    // Round 1 (M1): the model may only use words the user said.
    @Test func modelWordsMustBeHeard() async {
        let heard = "could billing run the integration tests again"
        let sessions = ["billing service", "blog"]
        let grounded = FakeModel(answer: .send(target: "billing", prompt: "run the integration tests"))
        #expect(await CommandParser(model: grounded).parse(heard, sessions: sessions)
                == .send(target: "billing", prompt: "run the integration tests"))
        let invented = FakeModel(answer: .send(target: "billing", prompt: "deploy to production"))
        #expect(await CommandParser(model: invented).parse(heard, sessions: sessions) == .unknown)
        let wrongTarget = FakeModel(answer: .send(target: "payments", prompt: "run the integration tests"))
        #expect(await CommandParser(model: wrongTarget).parse(heard, sessions: sessions) == .unknown)
    }

    // Round 1 (M2): a model approval counts only when the transcript holds a clear approval word.
    @Test func modelApprovalNeedsAClearWord() async {
        let stray = FakeModel(answer: .answer(allow: true, target: nil))
        #expect(await CommandParser(model: stray).parse("yes but use the other file instead of this", sessions: [])
                == .unknown)
        let yes = FakeModel(answer: .answer(allow: true, target: "billing"))
        #expect(await CommandParser(model: yes).parse("yeah billing", sessions: ["billing"])
                == .answer(allow: true, target: "billing"))
        let no = FakeModel(answer: .answer(allow: true, target: "billing"))
        #expect(await CommandParser(model: no).parse("nope billing", sessions: ["billing"])
                == .answer(allow: false, target: "billing"))
        let nah = FakeModel(answer: .answer(allow: false, target: "billing"))
        #expect(await CommandParser(model: nah).parse("nah billing", sessions: ["billing"])
                == .answer(allow: false, target: "billing"))
        // Without a session named, only yes, allow or approve counts.
        #expect(await CommandParser(model: stray).parse("sure, why not", sessions: []) == .unknown)
        let unheard = FakeModel(answer: .answer(allow: true, target: "payments"))
        #expect(await CommandParser(model: unheard).parse("yeah, the other one", sessions: ["payments"]) == .unknown)
    }

    /// Outside the window "stop" and "cancel" are the Stop command, never a no to a prompt.
    @Test func stopAndCancelAreNotAModelDeny() async {
        let deny = FakeModel(answer: .answer(allow: false, target: "billing"))
        #expect(await CommandParser(model: deny).parse("cancel billing", sessions: ["billing"]) == .unknown)
        #expect(await CommandParser(model: deny).parse("billing, cancel", sessions: ["billing"]) == .unknown)
        #expect(await CommandParser(model: deny).parse("no billing", sessions: ["billing"])
                == .answer(allow: false, target: "billing"))
    }

    /// "Hold on a second" must not stop the only session.
    @Test func aModelStopNeedsAStopWord() async {
        let stop = FakeModel(answer: .stop(target: nil, now: false))
        #expect(await CommandParser(model: stop).parse("hold on a second", sessions: ["billing"]) == .unknown)
        // With no session named, a stop only quiets Kobi: it never picks a session.
        #expect(await CommandParser(model: stop).parse("could you pause for a moment", sessions: ["billing"]) == .quiet)
        let all = FakeModel(answer: .stop(target: "everyone", now: false))
        #expect(await CommandParser(model: all).parse("could everyone please stop", sessions: ["billing"]) == .stopAll)
        let named = FakeModel(answer: .stop(target: "billing", now: false))
        #expect(await CommandParser(model: named).parse("billing should hold off for now", sessions: ["billing"]) == .unknown)
        #expect(await CommandParser(model: named).parse("billing should wait for now", sessions: ["billing"])
                == .stop(target: "billing", now: false))
    }

    @Test func aSlowModelGivesUpAfterItsLimit() async {
        let p = CommandParser(model: SlowCommandModel(), timeout: .milliseconds(50))
        let start = ContinuousClock.now
        #expect(await p.parse("Maybe billing could run the tests.", sessions: ["billing"])
                == .confirmSend(target: "billing", prompt: "Maybe billing could run the tests"))
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
