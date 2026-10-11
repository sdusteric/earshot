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
}
