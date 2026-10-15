import Foundation
import Testing
@testable import EarshotKit

actor FakeTransport: SessionTransport {
    struct Sent: Equatable { let pid: Int32; let session: String; let text: String; let priority: Priority }
    private(set) var sent: [Sent] = []
    private var works = true
    func setWorks(_ w: Bool) { works = w }
    func send(pid: Int32, sessionID: String, text: String, priority: Priority) async -> Bool {
        sent.append(Sent(pid: pid, session: sessionID, text: text, priority: priority))
        return works
    }
}

@Suite struct DispatcherTests {
    let store = SessionStore()
    let transport = FakeTransport()
    let said = Collected<String>()
    let approvalsDir: String = {
        let d = NSTemporaryDirectory() + "ek-d-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    let secret = "0123456789abcdef0123456789abcdef"

    func make(_ agents: [AgentEntry], claudeJSON: String = "/nonexistent", poll: Duration = .seconds(1)) -> (Dispatcher, FakeRunner, ApprovalBook) {
        let runner = FakeRunner(agents)
        let directory = SessionDirectory(runner: runner, store: store, labeler: Labeler(model: nil, liveDir: NSTemporaryDirectory()),
                                         claudeJSON: claudeJSON)
        let book = ApprovalBook(stateDir: approvalsDir, isAlive: { _ in true })
        let said = self.said
        let d = Dispatcher(directory: directory, store: store, transport: transport, runner: runner, approvals: book,
                           say: { await said.add($0) }, receiptTimeout: .milliseconds(200), pollInterval: poll)
        return (d, runner, book)
    }

    func approval(_ session: String, _ id: String, _ name: String) -> AppMessage.Approval {
        .init(session: session, id: id, name: name, what: "to run the migration",
              answer: "\(approvalsDir)/answer-\(session)-\(id)", secret: secret, pid: 1)
    }

    // MARK: Send

    @Test func sendsToTheNamedSession() async {
        let (d, _, _) = make([agent("a", "billing-service", pid: 10), agent("b", "blog", pid: 11)])
        let o = await d.run(.send(target: "billing service", prompt: "run the tests"))
        #expect(o.line == "Sent to billing service.")
        #expect(o.spokeAbout == "a")
        #expect(await transport.sent == [.init(pid: 10, session: "a", text: "run the tests", priority: .next)])
    }

    @Test func aBusySessionIsQueued() async {
        let (d, _, _) = make([agent("a", "billing-service", status: "busy")])
        #expect(await d.run(.send(target: "billing", prompt: "x")).line == "Queued, billing service is busy.")
    }

    @Test func aSessionOnAPromptSaysItStillWaits() async {
        await store.apply(.init(session: "a", state: .needs, detail: "needs your OK", name: "billing service"))
        let (d, _, _) = make([agent("a", "billing-service", status: "waiting")])
        #expect(await d.run(.send(target: "billing", prompt: "x")).line == "Queued. Billing service is still waiting on your OK.")
    }

    @Test func noTargetWithOneSessionUsesIt() async {
        let (d, _, _) = make([agent("b", "blog")])
        #expect(await d.run(.send(target: nil, prompt: "deploy")).line == "Sent to blog.")
    }

    @Test func noTargetWithSeveralAsks() async {
        let (d, _, _) = make([agent("a", "billing-service"), agent("b", "blog"), agent("c", "earshot"), agent("e", "extra")])
        let o = await d.run(.send(target: nil, prompt: "deploy"))
        #expect(o.line?.hasPrefix("Which session? Open ones are ") == true)
        #expect(o.pending == .chooseSession(.send(target: nil, prompt: "deploy"), ["a", "b", "c", "e"]))
        #expect(await transport.sent.isEmpty)
    }

    @Test func twoInOneProjectAsksWhichOneThenSends() async {
        let (d, _, _) = make([agent("a", "billing-service", name: "Fix refund rounding", pid: 10),
                              agent("b", "billing-service", name: "Invoice export", pid: 11)])
        let o = await d.run(.send(target: "billing", prompt: "run the tests"))
        #expect(o.line == "Billing service has two: Fix refund rounding and Invoice export. Which one?")
        guard let p = o.pending else { Issue.record("no question"); return }
        let r = await d.reply("invoices", to: p)
        #expect(r.line == "Sent to the Invoice export session.")
        #expect(await transport.sent.map(\.pid) == [11])
    }

    @Test func twoUntitledInOneFolderAreAskedAboutByAge() async {
        let (d, _, _) = make([agent("a", "blog", pid: 10, startedAt: 1_790_000_200_000),
                              agent("b", "blog", pid: 11, startedAt: 1_790_000_100_000)])
        let o = await d.run(.send(target: "blog", prompt: "deploy"))
        #expect(o.line == "Blog has two: the older blog session and the newer blog session. Which one?")
        guard let p = o.pending else { Issue.record("no question"); return }
        #expect(await d.reply("The newer one.", to: p).line == "Sent to the newer blog session.")
        #expect(await transport.sent.map(\.pid) == [10])
    }

    @Test func anUnknownTargetListsAtMostThree() async {
        let (d, _, _) = make([agent("a", "billing-service"), agent("b", "blog"), agent("c", "earshot"), agent("e", "extra")])
        let line = await d.run(.send(target: "payments", prompt: "x")).line ?? ""
        #expect(line.hasPrefix("I don't know a session called payments. Open ones are "))
        #expect(line.components(separatedBy: ",").count + line.components(separatedBy: " and ").count - 1 == 3)
    }

    @Test func aClosedSessionIsSaid() async {
        await transport.setWorks(false)
        let (d, _, _) = make([agent("a", "billing-service")])
        #expect(await d.run(.send(target: "billing", prompt: "x")).line == "Billing service has closed.")
    }

    @Test func noReceiptIsSaidLater() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        _ = await d.run(.send(target: "billing", prompt: "x"))
        #expect(await eventually { await said.items == ["Billing service didn't pick it up."] })
    }

    @Test func aReceiptKeepsItQuiet() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        _ = await d.run(.send(target: "billing", prompt: "x"))
        await store.apply(.init(session: "a", state: .working, name: "billing service"))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await said.items.isEmpty)
    }

    @Test func twoMissesMarkSendingBrokenAndBackgroundSessionsResume() async {
        let (d, runner, _) = make([agent("a", "billing-service"), agent("g", "wedding", pid: nil, kind: "background", status: nil)])
        _ = await d.run(.send(target: "billing", prompt: "x"))
        #expect(await eventually { await said.items.count == 1 })
        _ = await d.run(.send(target: "billing", prompt: "y"))
        #expect(await eventually { await said.items.count == 2 })
        #expect(await said.items.last == "Sending to sessions stopped working with this Claude Code version. Background sessions still work.")
        #expect(await d.run(.send(target: "billing", prompt: "z")).line == "Sending to billing service doesn't work with this Claude Code version yet.")
        #expect(await d.run(.send(target: "wedding", prompt: "w")).line == "Sent to wedding.")
        #expect(await runner.argLists.contains(["--resume", "g", "--bg", "w"]))
    }

    @Test func aBackgroundSessionWithoutAProcessResumes() async {
        let (d, runner, _) = make([agent("g", "wedding", pid: nil, kind: "background", status: nil)])
        #expect(await d.run(.send(target: "wedding", prompt: "keep going")).line == "Sent to wedding.")
        #expect(await runner.argLists.contains(["--resume", "g", "--bg", "keep going"]))
        #expect(await transport.sent.isEmpty)
    }

    @Test func unknownCommandSendsNothing() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        #expect(await d.run(.unknown).line == "Sorry, I didn't get that.")
        #expect(await transport.sent.isEmpty)
    }

    // MARK: Receipts and the broken mark

    @Test func missReceiptMissDoesNotMarkBroken() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        _ = await d.run(.send(target: "billing", prompt: "1"))
        #expect(await eventually { await said.items.count == 1 })
        _ = await d.run(.send(target: "billing", prompt: "2"))
        await store.apply(.init(session: "a", state: .working, name: "billing service"))
        try? await Task.sleep(for: .milliseconds(350))
        _ = await d.run(.send(target: "billing", prompt: "3"))
        #expect(await eventually { await said.items.count == 2 })
        #expect(await said.items.last == "Billing service didn't pick it up.")
        _ = await d.run(.send(target: "billing", prompt: "4"))
        #expect(await transport.sent.count == 4)
    }

    @Test func busyAtAPollCountsEvenIfIdleAtTheDeadline() async {
        let (d, runner, _) = make([agent("a", "billing-service")], poll: .milliseconds(50))
        _ = await d.run(.send(target: "billing", prompt: "x"))
        await runner.setAgents([agent("a", "billing-service", status: "busy")])
        try? await Task.sleep(for: .milliseconds(120))
        await runner.setAgents([agent("a", "billing-service")])
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await said.items.isEmpty)
    }

    @Test func aWindowWhereClaudeNeverAnsweredIsNotAMiss() async {
        let (d, runner, _) = make([agent("a", "billing-service")], poll: .milliseconds(50))
        _ = await d.run(.send(target: "billing", prompt: "x"))
        await runner.setFail(true)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await said.items.isEmpty)
    }

    /// The session closed after the send: not a miss, and nothing to say.
    @Test func aSessionGoneAtTheReceiptCheckIsNotAMiss() async {
        let (d, runner, _) = make([agent("a", "billing-service", pid: 10), agent("b", "blog", pid: 11)], poll: .milliseconds(50))
        _ = await d.run(.send(target: "billing", prompt: "x"))
        await runner.setAgents([agent("b", "blog", pid: 11)])
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await said.items.isEmpty)
        _ = await d.run(.send(target: "blog", prompt: "y"))
        #expect(await eventually { await said.items == ["Blog didn't pick it up."] })   // one miss, not two
    }

    /// Receipts say what became of a send, for the line under a reply field.
    @Test func aReceiptSaysTheSessionStartedWorking() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        let got = Collected<Dispatcher.Receipt>()
        let stream = await d.receipts()
        Task { for await r in stream { await got.add(r) } }
        let before = Date()
        _ = await d.send(typed: "run the tests", toSession: "a")
        await store.apply(.init(session: "a", state: .working, name: "billing service"))
        #expect(await eventually { await got.items.count == 1 })
        let r = await got.items.first
        #expect(r?.result == .started)
        #expect(r?.session == "a")
        #expect((r?.sent ?? .distantPast) >= before)
        #expect(r?.line == "Billing service started working.")
        #expect(await said.items.isEmpty)
    }

    @Test func aMissedReceiptIsSaidAndSent() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        let got = Collected<Dispatcher.Receipt>()
        let stream = await d.receipts()
        Task { for await r in stream { await got.add(r) } }
        _ = await d.send(typed: "run the tests", toSession: "a")
        #expect(await eventually { await got.items.count == 1 })
        #expect(await got.items.first?.result == .missed)
        #expect(await got.items.first?.line == "Billing service didn't pick it up.")
        #expect(await said.items == ["Billing service didn't pick it up."])
    }

    @Test func aSessionThatClosedHasAReceiptToo() async {
        let (d, runner, _) = make([agent("a", "billing-service", pid: 10)], poll: .milliseconds(50))
        let got = Collected<Dispatcher.Receipt>()
        let stream = await d.receipts()
        Task { for await r in stream { await got.add(r) } }
        _ = await d.send(typed: "x", toSession: "a")
        await runner.setAgents([])
        #expect(await eventually { await got.items.count == 1 })
        #expect(await got.items.first?.result == .closed)
        #expect(await said.items.isEmpty)
    }

    @Test func noAnswerFromClaudeLeavesTheReceiptUnknown() async {
        let (d, runner, _) = make([agent("a", "billing-service")], poll: .milliseconds(50))
        let got = Collected<Dispatcher.Receipt>()
        let stream = await d.receipts()
        Task { for await r in stream { await got.add(r) } }
        _ = await d.send(typed: "x", toSession: "a")
        await runner.setFail(true)
        #expect(await eventually { await got.items.count == 1 })
        #expect(await got.items.first?.result == .unknown)
        #expect(await got.items.first?.line == nil)
    }

    /// A queued send has no receipt: the session is busy or waits on you.
    @Test func aQueuedSendHasNoReceipt() async {
        let (d, _, _) = make([agent("a", "billing-service", status: "busy")])
        let got = Collected<Dispatcher.Receipt>()
        let stream = await d.receipts()
        Task { for await r in stream { await got.add(r) } }
        #expect(await d.send(typed: "x", toSession: "a").line == "Queued, billing service is busy.")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await got.items.isEmpty)
    }

    @Test func afterTwoMissesTheSocketIsSkippedAndTheBrokenLineIsSaidOnce() async {
        let (d, _, _) = make([agent("a", "billing-service")])
        _ = await d.run(.send(target: "billing", prompt: "1"))
        _ = await d.run(.send(target: "billing", prompt: "2"))
        #expect(await eventually { await said.items.count == 2 })
        _ = await d.run(.send(target: "billing", prompt: "3"))
        try? await Task.sleep(for: .milliseconds(350))
        #expect(await transport.sent.count == 2)
        #expect(await said.items.filter { $0.hasPrefix("Sending to sessions stopped") }.count == 1)
        #expect(await said.items.count == 2)
    }

    @Test func stoppingWhenSendingIsBrokenSaysSo() async {
        let (d, _, _) = make([agent("a", "billing-service"), agent("b", "blog", status: "busy")])
        _ = await d.run(.send(target: "billing", prompt: "1"))
        _ = await d.run(.send(target: "billing", prompt: "2"))
        #expect(await eventually { await said.items.count == 2 })
        #expect(await d.run(.stop(target: "blog", now: false)).line == "Sending to blog doesn't work with this Claude Code version yet.")
    }

    @Test func aSessionWaitingOnYourAnswerIsIdleForSendAndStop() async {
        await store.apply(.init(session: "a", state: .reply, detail: "asked something", name: "billing service"))
        let (d, _, _) = make([agent("a", "billing-service")])
        #expect(await d.run(.send(target: "billing", prompt: "x")).line == "Sent to billing service.")
        #expect(await d.run(.stop(target: "billing", now: false)).line == "Billing service isn't doing anything.")
    }

    @Test func aLateApprovalChoiceSaysNothing() async {
        let (d, _, book) = make([agent("s1", "billing-service"), agent("s2", "docs")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        await book.apply(approval("s2", "2-2-2", "docs"))
        guard let p = await d.run(.answer(allow: true, target: nil)).pending else { Issue.record("no question"); return }
        _ = await book.answer("1-1-1", allow: true)
        _ = await book.answer("2-2-2", allow: true)
        #expect(await d.reply("docs", to: p) == Dispatcher.Outcome())
    }

    @Test func aLateChoiceOfTheClosedPromptSaysNothingAndWritesNothing() async {
        let (d, _, book) = make([agent("s1", "billing-service"), agent("s2", "docs")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        await book.apply(approval("s2", "2-2-2", "docs"))
        guard let p = await d.run(.answer(allow: true, target: nil)).pending else { Issue.record("no question"); return }
        _ = await book.answer("2-2-2", allow: true)
        #expect(await d.reply("docs", to: p) == Dispatcher.Outcome())
        #expect(await book.current.map(\.id) == ["1-1-1"])
        #expect(!FileManager.default.fileExists(atPath: "\(approvalsDir)/answer-s1-1-1-1"))
    }

    // MARK: Status, stop, start

    @Test func statusForEveryoneIsTheRollCall() async {
        let (d, _, _) = make([agent("a", "billing-service", status: "busy"), agent("b", "blog")])
        // Then a closing note, which depends on the hour.
        #expect(await d.run(.status(target: nil)).line?.hasPrefix("Two sessions. Billing service is working. One other is idle. ") == true)
    }

    @Test func statusForOne() async {
        let (d, _, _) = make([agent("a", "billing-service", status: "busy"), agent("b", "blog")])
        let o = await d.run(.status(target: "billing"))
        #expect(o.line == "Billing service is working.")
        #expect(o.spokeAbout == "a")
    }

    @Test func stopAfterTheCurrentStep() async {
        let (d, _, _) = make([agent("a", "billing-service", pid: 10, status: "busy")])
        #expect(await d.run(.stop(target: "billing", now: false)).line == "Billing service will stop after its current step.")
        #expect(await transport.sent == [.init(pid: 10, session: "a", text: Dispatcher.stopText, priority: .now)])
    }

    @Test func quietSaysNothingAndSendsNothing() async {
        let (d, _, _) = make([agent("a", "billing-service", pid: 10, status: "busy")])
        #expect(await d.run(.quiet) == Dispatcher.Outcome())
        #expect(await transport.sent.isEmpty)
    }

    /// Stopping every session asks first, and only a clear yes stops them.
    @Test func stopAllAsksThenStopsWhatIsRunning() async {
        let (d, _, _) = make([agent("a", "billing-service", pid: 10, status: "busy"), agent("b", "blog", pid: 11, status: "busy"),
                              agent("c", "docs", pid: 12)])
        let o = await d.run(.stopAll)
        #expect(o.line == "Stop billing service and blog?")
        #expect(await transport.sent.isEmpty)
        guard let p = o.pending else { Issue.record("no question"); return }
        #expect(await d.reply("Yes.", to: p).line == "Billing service and blog will stop after their current step.")
        #expect(await transport.sent.map(\.pid) == [10, 11])
        #expect(await transport.sent.allSatisfy { $0.text == Dispatcher.stopText })
    }

    @Test func stopAllWithoutAYesStopsNothing() async {
        let (d, _, _) = make([agent("a", "billing-service", pid: 10, status: "busy")])
        let o = await d.run(.stopAll)
        #expect(o.line == "Stop billing service?")
        guard let p = o.pending else { Issue.record("no question"); return }
        #expect(await d.reply("No.", to: p).line == "Okay, I didn't stop anything.")
        #expect(await d.reply("What's the weather", to: p).line == "Okay, I didn't stop anything.")
        #expect(await transport.sent.isEmpty)
    }

    @Test func stopAllWithNothingRunning() async {
        let (d, _, _) = make([agent("c", "docs")])
        #expect(await d.run(.stopAll).line == "Nothing is running.")
        let (none, _, _) = make([])
        #expect(await none.run(.stopAll).line == "No Claude sessions are open.")
    }

    // MARK: Sends heard unclearly

    /// A send heard unclearly is read back, and goes only on a clear yes.
    @Test func anUnclearSendIsReadBackThenSentOnAYes() async {
        let (d, _, _) = make([agent("a", "earshot", pid: 10), agent("b", "blog", pid: 11)])
        let o = await d.run(.confirmSend(target: "earshot", prompt: "what else should we do"))
        #expect(o.line == "Send to earshot: what else should we do?")
        #expect(await transport.sent.isEmpty)
        guard let p = o.pending else { Issue.record("no question"); return }
        #expect(p == .confirmSend(session: "a", prompt: "what else should we do"))
        #expect(await d.reply("Yes.", to: p).line == "Sent to earshot.")
        #expect(await transport.sent == [.init(pid: 10, session: "a", text: "what else should we do", priority: .next)])
    }

    /// A reply typed in the session view goes to that session by its ID.
    @Test func aTypedReplyGoesToThatSession() async {
        let (d, _, _) = make([agent("a", "blog", pid: 10), agent("b", "docs", pid: 11)])
        #expect(await d.send(typed: "  run the tests ", toSession: "b").line == "Sent to docs.")
        #expect(await transport.sent == [.init(pid: 11, session: "b", text: "run the tests", priority: .next)])
        #expect(await d.send(typed: "   ", toSession: "b").line == "")
        #expect(await d.send(typed: "hi", toSession: "gone").line == "That session has closed.")
        #expect(await transport.sent.count == 1)
    }

    @Test func anUnclearSendWithoutAYesSendsNothing() async {
        let (d, _, _) = make([agent("a", "earshot", pid: 10)])
        guard let p = await d.run(.confirmSend(target: "earshot", prompt: "run the tests")).pending else {
            Issue.record("no question"); return
        }
        #expect(await d.reply("No.", to: p).line == "Okay, I didn't send it.")
        #expect(await d.reply("Run the tests", to: p).line == "Okay, I didn't send it.")
        #expect(await transport.sent.isEmpty)
    }

    /// The yes confirms the send. A permission prompt open meanwhile stays open.
    @Test func theYesToAnUnclearSendNeverAnswersAPrompt() async {
        let (d, _, book) = make([agent("a", "earshot", pid: 10)])
        await book.apply(approval("a", "1-1-1", "earshot"))
        guard let p = await d.run(.confirmSend(target: "earshot", prompt: "run the tests")).pending else {
            Issue.record("no question"); return
        }
        _ = await d.reply("Yes.", to: p)
        #expect(await transport.sent.map(\.text) == ["run the tests"])
        #expect(await book.isOpen("1-1-1"))
    }

    @Test func anUnclearSendToANameThatIsGoneIsNotUnderstood() async {
        let (d, _, _) = make([agent("b", "blog")])
        #expect(await d.run(.confirmSend(target: "earshot", prompt: "run the tests")).line == Dispatcher.didntGetIt)
    }

    @Test func whatWasHeardIsSaidBack() {
        #expect(Dispatcher.didntGet("Are the other seconds going?") == "Sorry, I heard: Are the other seconds going.")
        #expect(Dispatcher.didntGet("  ") == Dispatcher.didntGetIt)
        let long = Dispatcher.didntGet("one two three four five six seven eight nine ten eleven twelve thirteen")
        #expect(long == "Sorry, I heard: one two three four five six seven eight nine ten eleven twelve...")
    }

    @Test func stopNowOnABackgroundSessionRunsClaudeStop() async {
        let (d, runner, _) = make([agent("g", "wedding", pid: 20, kind: "background", status: "busy")])
        #expect(await d.run(.stop(target: "wedding", now: true)).line == "Stopped wedding.")
        #expect(await runner.argLists.contains(["stop", "g"]))
        #expect(await transport.sent.isEmpty)
    }

    @Test func stoppingAnIdleSessionDoesNothing() async {
        let (d, _, _) = make([agent("b", "blog")])
        #expect(await d.run(.stop(target: "blog", now: false)).line == "Blog isn't doing anything.")
        #expect(await transport.sent.isEmpty)
    }

    func claudeJSON() throws -> String {
        let path = NSTemporaryDirectory() + "ek-cj-\(UUID().uuidString.prefix(6)).json"
        try #"{"projects":{"/p/blog":{"hasTrustDialogAccepted":true},"/p/secret":{"hasTrustDialogAccepted":false}}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func startRunsClaudeInTheFolder() async throws {
        let (d, runner, _) = make([], claudeJSON: try claudeJSON())
        #expect(await d.run(.start(project: "blog", prompt: "fix the header")).line == "Started a session in blog.")
        let call = await runner.calls.last
        #expect(call?.args == ["--bg", "fix the header"])
        #expect(call?.cwd == "/p/blog")
    }

    @Test func startInAnUntrustedFolderSaysSo() async throws {
        let (d, runner, _) = make([], claudeJSON: try claudeJSON())
        #expect(await d.run(.start(project: "secret", prompt: "x")).line == "Secret isn't trusted yet. Open it in Claude once first.")
        #expect(await runner.argLists.allSatisfy { $0.first != "--bg" })
    }

    @Test func startWithoutAPromptAsksWhatToDo() async throws {
        let (d, runner, _) = make([], claudeJSON: try claudeJSON())
        let o = await d.run(.start(project: "blog", prompt: nil))
        #expect(o.line == "What should the new session in blog do?")
        guard let p = o.pending else { Issue.record("no question"); return }
        #expect(await d.reply("fix the header", to: p).line == "Started a session in blog.")
        #expect(await runner.argLists.contains(["--bg", "fix the header"]))
    }

    @Test func startInAnUnknownFolder() async throws {
        let (d, _, _) = make([], claudeJSON: try claudeJSON())
        #expect(await d.run(.start(project: "payments", prompt: "x")).line == "I don't know a folder called payments.")
    }

    // MARK: Answers

    @Test func answerApprovesTheOnlyPrompt() async throws {
        let (d, _, book) = make([agent("s1", "billing-service")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        let o = await d.run(.answer(allow: true, target: nil))
        #expect(o.line == "Approved.")
        #expect(o.sound)
        #expect(try String(contentsOfFile: "\(approvalsDir)/answer-s1-1-1-1", encoding: .utf8) == "allow \(secret)\n")
    }

    @Test func answerWithTwoOpenAsksWhichOne() async {
        let (d, _, book) = make([agent("s1", "billing-service"), agent("s2", "docs")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        await book.apply(approval("s2", "2-2-2", "docs"))
        let o = await d.run(.answer(allow: false, target: nil))
        #expect(o.line == "Which one, billing service or docs?")
        guard let p = o.pending else { Issue.record("no question"); return }
        let r = await d.reply("docs", to: p)
        #expect(r.line == "Told it no.")
        #expect(await book.current.map(\.id) == ["1-1-1"])
    }

    @Test func answerByName() async {
        let (d, _, book) = make([agent("s1", "billing-service"), agent("s2", "docs")])
        await book.apply(approval("s1", "1-1-1", "billing service"))
        await book.apply(approval("s2", "2-2-2", "docs"))
        #expect(await d.run(.answer(allow: true, target: "billing")).line == "Approved.")
        #expect(await book.current.map(\.id) == ["2-2-2"])
    }

    @Test func answerWhenNothingWaits() async {
        let (d, _, _) = make([agent("s1", "billing-service")])
        #expect(await d.run(.answer(allow: true, target: nil)).line == "Nothing is waiting on your OK.")
    }
}
