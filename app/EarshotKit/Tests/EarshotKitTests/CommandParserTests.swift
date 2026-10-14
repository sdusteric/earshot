import Foundation
import Testing
@testable import EarshotKit

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

    /// Needs Apple Intelligence on: EARSHOT_TEST_FM=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_TEST_FM"] == "1"))
    func theRealModelUnderstandsAFreeformCommand() async {
        let m = FoundationCommandModel()
        #expect(await m.isAvailable)
        let c = await m.parse("could billing service maybe run the integration tests again",
                              sessions: ["billing service", "blog"])
        guard case .send(let target, let prompt) = c else { Issue.record("got \(String(describing: c))"); return }
        #expect(target?.lowercased().contains("billing") == true)
        #expect(prompt.lowercased().contains("integration tests"))
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
        #expect(await CommandParser(model: stop).parse("could you pause for a moment", sessions: ["billing"])
                == .stop(target: nil, now: false))
        let named = FakeModel(answer: .stop(target: "billing", now: false))
        #expect(await CommandParser(model: named).parse("billing should hold off for now", sessions: ["billing"]) == .unknown)
        #expect(await CommandParser(model: named).parse("billing should wait for now", sessions: ["billing"])
                == .stop(target: "billing", now: false))
    }

    @Test func aSlowModelGivesUpAfterItsLimit() async {
        let p = CommandParser(model: SlowCommandModel(), timeout: .milliseconds(50))
        let start = ContinuousClock.now
        #expect(await p.parse("Could billing maybe run the tests.", sessions: ["billing"]) == .unknown)
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
