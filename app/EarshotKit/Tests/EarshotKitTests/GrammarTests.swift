import Testing
@testable import EarshotKit

@Suite struct GrammarTests {
    static let known = ["billing service", "blog", "earshot", "refund rounding"]

    @Test(arguments: [
        // Status, everyone
        ("What's everyone doing?", Command.status(target: nil)),
        ("what is everyone doing", .status(target: nil)),
        ("Um, what's everybody doing?", .status(target: nil)),
        ("Roll call.", .status(target: nil)),
        ("Hey, how are you doing?", .greet),
        ("How's it going?", .greet),
        ("What's up?", .greet),
        ("Hello.", .greet),
        ("Status.", .status(target: nil)),
        ("What's going on?", .status(target: nil)),
        ("Can you give me a status update?", .status(target: nil)),
        ("How's everything going?", .status(target: nil)),
        // Status, one session
        ("What's billing doing?", .status(target: "billing")),
        ("What is billing service doing?", .status(target: "billing service")),
        ("How's the blog going?", .status(target: "the blog")),
        ("How is earshot doing", .status(target: "earshot")),
        ("Status of refund rounding.", .status(target: "refund rounding")),
        ("What's the status of billing?", .status(target: "billing")),
        ("What's up with blog?", .status(target: "blog")),
        ("Where's billing at?", .status(target: "billing")),
        ("Check on the blog.", .status(target: "the blog")),
        ("Billing status.", .status(target: "Billing")),
        ("What's everyone working on?", .status(target: nil)),
        ("What is everyone working on?", .status(target: nil)),
        ("What's billing working on?", .status(target: "billing")),
        ("What's blog up to?", .status(target: "blog")),
        ("Is blog done?", .status(target: "blog")),
        ("Is billing finished?", .status(target: "billing")),
        ("Is everyone done?", .status(target: nil)),
        ("How's it going with blog?", .status(target: "blog")),
        // What needs you: the roll call, which says those first
        ("Who needs me?", .status(target: nil)),
        ("Does anything need me?", .status(target: nil)),
        ("Is anyone waiting on me?", .status(target: nil)),
        // Greetings
        ("How ya doing?", .greet),
        ("How you doing today?", .greet),
        ("Good morning.", .greet),
        // Nothing to do
        ("Thanks.", .quiet),
        ("Thank you.", .quiet),
        ("Okay, thanks.", .quiet),
        ("Never mind.", .quiet),
        // Earshot's last line again
        ("Repeat that.", .repeatLast),
        ("Say that again.", .repeatLast),
        ("Can you repeat that?", .repeatLast),
        ("What was that?", .repeatLast),
        // Send
        ("Tell billing service to run the tests.", .send(target: "billing service", prompt: "run the tests")),
        ("tell billing to run the tests", .send(target: "billing", prompt: "run the tests")),
        ("Can you tell blog to fix the RSS feed?", .send(target: "blog", prompt: "fix the RSS feed")),
        ("Ask earshot to summarize what it did.", .send(target: "earshot", prompt: "summarize what it did")),
        ("Ask billing what it's working on.", .send(target: "billing", prompt: "what it's working on")),
        ("Ask the blog why the build failed", .send(target: "the blog", prompt: "why the build failed")),
        ("Tell it to keep going.", .send(target: nil, prompt: "keep going")),
        ("Tell them to commit the changes.", .send(target: nil, prompt: "commit the changes")),
        ("Get billing to push the branch.", .send(target: "billing", prompt: "push the branch")),
        ("In billing service, run the tests.", .send(target: "billing service", prompt: "run the tests")),
        ("in billing service run the tests", .send(target: "billing service", prompt: "run the tests")),
        ("On the blog, set the timeout to 2.5 seconds.", .send(target: "the blog", prompt: "set the timeout to 2.5 seconds")),
        ("For earshot: open a PR.", .send(target: "earshot", prompt: "open a PR")),
        ("Please tell blog to deploy, thanks.", .send(target: "blog", prompt: "deploy")),
        ("Send run the linter to billing.", .send(target: "billing", prompt: "run the linter")),
        ("Tell the newer blog session to deploy.", .send(target: "the newer blog session", prompt: "deploy")),
        // A session named first
        ("Blog, run the tests.", .send(target: "Blog", prompt: "run the tests")),
        ("Billing service, update the readme.", .send(target: "Billing service", prompt: "update the readme")),
        ("Billing, deploy.", .send(target: "Billing", prompt: "deploy")),
        ("Okay, blog: fix the RSS feed.", .send(target: "blog", prompt: "fix the RSS feed")),
        ("Blog, yes.", .answer(allow: true, target: "Blog")),
        ("Tell refund rounding to add a test for zero.", .send(target: "refund rounding", prompt: "add a test for zero")),
        // Stop
        ("Stop billing.", .stop(target: "billing", now: false)),
        ("stop billing service now", .stop(target: "billing service", now: true)),
        ("Stop the blog right now.", .stop(target: "the blog", now: true)),
        ("Halt earshot immediately.", .stop(target: "earshot", now: true)),
        ("Tell billing to stop.", .stop(target: "billing", now: false)),
        ("Tell billing to stop now.", .stop(target: "billing", now: true)),
        ("Pause blog.", .stop(target: "blog", now: false)),
        ("Stop the older blog session.", .stop(target: "the older blog session", now: false)),
        ("Blog, stop.", .stop(target: "Blog", now: false)),
        ("Tell it to stop.", .stop(target: nil, now: false)),
        // A bare stop is for Earshot's own voice: it never reaches a session.
        ("Stop.", .quiet),
        ("Stop it.", .quiet),
        ("Stop that.", .quiet),
        ("Stop it now.", .quiet),
        ("Quiet.", .quiet),
        ("Be quiet.", .quiet),
        ("Shut up.", .quiet),
        ("Stop talking.", .quiet),
        ("Okay, stop.", .quiet),
        ("Earshot, stop.", .quiet),
        // Every session at once: Earshot asks first.
        ("Stop everything.", .stopAll),
        ("Stop all.", .stopAll),
        ("Stop all sessions.", .stopAll),
        ("Tell everyone to stop.", .stopAll),
        // Start
        ("Start a session in blog.", .start(project: "blog", prompt: nil)),
        ("Start a new session in blog to fix the header.", .start(project: "blog", prompt: "fix the header")),
        ("Open a new session in billing service and write the changelog.",
         .start(project: "billing service", prompt: "write the changelog")),
        ("New session in earshot to look at the logs.", .start(project: "earshot", prompt: "look at the logs")),
        ("Start a session for the wedding site.", .start(project: "the wedding site", prompt: nil)),
        // Answers
        ("Yes.", .answer(allow: true, target: nil)),
        ("Yes, please.", .answer(allow: true, target: nil)),
        ("Allow it.", .answer(allow: true, target: nil)),
        ("No.", .answer(allow: false, target: nil)),
        ("Yeah billing.", .answer(allow: true, target: "billing")),
        ("Yes billing.", .answer(allow: true, target: "billing")),
        ("Approve billing service.", .answer(allow: true, target: "billing service")),
        ("Allow the blog.", .answer(allow: true, target: "the blog")),
        ("No to billing.", .answer(allow: false, target: "billing")),
        ("Deny earshot.", .answer(allow: false, target: "earshot")),
        ("Yes to blog.", .answer(allow: true, target: "blog")),
        // A bare "how's X", and how it gets misheard
        ("How's the blog?", .status(target: "blog")),
        ("How is billing service", .status(target: "billing service")),
        ("How you blog", .status(target: "blog")),
        ("How's your earshot", .status(target: "earshot")),
        // Matched a shape, nothing to send
        ("Tell billing to", .unknown),
        ("Tell billing to um", .unknown),
        ("um", .unknown),
        ("", .unknown),
    ] as [(String, Command)])
    func phrasing(_ said: String, _ expected: Command) {
        #expect(Grammar.parse(said, known: Self.known) == expected)
    }

    @Test(arguments: [
        "Run the tests.",                          // no target named: the model decides
        "Could billing maybe look at the flaky test",
        "Let's have the blog rewrite the intro",
        "How's the weather",                       // not a session: the model decides
        "How are you feeling about the deploy",
    ])
    func unmatchedGoesToTheModel(_ said: String) {
        #expect(Grammar.parse(said, known: Self.known) == nil)
    }

    /// Real session names are often plain words. A name said first must be a whole known
    /// name (or the start of one), so ordinary sentences still reach the model.
    static let plainNames = ["wedding", "What's next", "Plugin", "Projects", "earshot", "blog"]

    @Test(arguments: [
        ("Wedding, send the invites.", Command.send(target: "Wedding", prompt: "send the invites")),
        ("Plugin, update the readme.", .send(target: "Plugin", prompt: "update the readme")),
        ("Projects, list the folders.", .send(target: "Projects", prompt: "list the folders")),
        ("What's wedding up to?", .status(target: "wedding")),
        ("Is plugin done?", .status(target: "plugin")),
    ] as [(String, Command)])
    func plainWordNamesWhereANameIsNeeded(_ said: String, _ expected: Command) {
        #expect(Grammar.parse(said, known: Self.plainNames) == expected)
    }

    @Test(arguments: [
        "What's next, run the tests",       // a name that starts like a question is never said first
        "Blog post, write it up",           // more than the name
        "Earshot, run the tests",           // Earshot itself, not a session
        "So, what's next?",
        "Is the build done?",
        "What's the plan?",
        "Yeah, the wedding is next week",
        "Okay, so the wedding, it's next week",
    ])
    func plainSentencesWithNameWordsGoToTheModel(_ said: String) {
        #expect(Grammar.parse(said, known: Self.plainNames) == nil)
    }

    @Test func emptyPromptIsNoCommand() {
        #expect(Grammar.parse("tell billing to") == .unknown)
        #expect(Grammar.parse("in billing service,") == .unknown)
    }

    /// In an approval window: a yes or no word, alone or with a short tail.
    @Test(arguments: [
        ("yes", true), ("Yeah.", true), ("yep", true), ("Allow it.", true), ("approve", true), ("Go ahead.", true),
        ("Do it.", true), ("sure", true), ("OK.", true), ("Okay", true), ("yes please", true),
        ("Okay, go ahead.", true), ("Yes, do it.", true), ("Yep, do it.", true), ("Sure thing.", true),
        ("Allow once.", true), ("Um, yes.", true), ("Go for it.", true),
        ("no", false), ("Nope.", false), ("deny", false), ("Don't.", false), ("stop", false), ("cancel", false),
        ("no thanks", false), ("No, don't.", false), ("No way.", false), ("Nope, don't.", false),
        ("Don't do that.", false),
    ] as [(String, Bool)])
    func windowAnswers(_ said: String, _ allow: Bool) {
        #expect(Grammar.windowAnswer(said) == allow)
    }

    /// Only a clear answer counts: a sentence with other content, or both yes and no, is no answer.
    @Test(arguments: ["yes but use the other file", "no idea", "sure, after you run the tests", "", "maybe", "hmm",
                      "Yeah, no.", "Okay, stop.", "No, wait, yes", "Yes, don't delete it"])
    func otherSentencesAreNoAnswer(_ said: String) {
        #expect(Grammar.windowAnswer(said) == nil)
    }

    /// Outside a window a short noise is often heard as "Okay." or "Yeah.":
    /// only yes, allow or approve answers a prompt there, or a word with a session name.
    /// A lone okay is quiet; "go ahead" was meant as an answer, so it is not understood.
    @Test(arguments: [("Okay.", Command.quiet), ("OK", .quiet), ("Sure.", .quiet), ("Yeah.", .quiet), ("Yep.", .quiet),
                      ("Sure thing.", .quiet), ("Do it.", .unknown), ("Go ahead.", .unknown), ("Yeah, go ahead.", .unknown)])
    func fillerWordsDoNotApproveOutsideAWindow(_ said: String, _ expected: Command) {
        #expect(Grammar.parse(said, known: Self.known) == expected)
    }

    // Round 1 (G1): a question or negation before "to" is not a send.
    @Test(arguments: [
        "Tell billing not to deploy",
        "Ask billing how to run the tests",
        "Ask earshot what to do next",
        "Tell billing service how to deploy",
    ])
    func questionsAndNegationsGoToTheModel(_ said: String) {
        #expect(Grammar.parse(said, known: Self.known) == nil)
    }

    // Round 1 (G2): a target must look like a known session when names are known.
    @Test(arguments: [
        ("billing", true), ("billing service", true), ("the blog", true), ("blog", true),
        ("billing not", false), ("the meantime", false), ("using mocks", false),
    ] as [(String, Bool)])
    func looksKnownMatchesNames(_ target: String, _ expected: Bool) {
        #expect(Grammar.looksKnown(target, known: Self.known) == expected)
    }

    @Test func looksKnownWithNoNamesKeepsTheTarget() {
        #expect(Grammar.looksKnown("anything at all", known: []))
    }

    @Test(arguments: [
        "In the meantime, tell billing to deploy",
        "On the other hand, run it",
        "For example, do this",
        "Stop using mocks",
    ])
    func unknownTargetsGoToTheModel(_ said: String) {
        #expect(Grammar.parse(said, known: Self.known) == nil)
    }

    @Test func itIsAStatusPronoun() {
        #expect(Grammar.parse("How's it doing", known: Self.known) == .status(target: nil))
        // Asked of Earshot, "how's it going" is a greeting.
        #expect(Grammar.parse("How's it going", known: Self.known) == .greet)
    }

    // Round 1 (G3): an answer's target must look like a known session.
    @Test(arguments: [
        "Yes but use file", "Yes, run the tests", "Yes, delete everything",
        "Approve the deploy to production", "No idea",
    ])
    func answersWithTrailingContentGoToTheModel(_ said: String) {
        #expect(Grammar.parse(said, known: Self.known) == nil)
    }

    // Round 1 (G4): trailing please and thanks go only after a comma; prompts keep their words.
    @Test func promptsKeepTheirOwnWords() {
        #expect(Grammar.parse("Tell billing to say thanks", known: Self.known) == .send(target: "billing", prompt: "say thanks"))
        #expect(Grammar.parse("Tell billing to like the post", known: Self.known) == .send(target: "billing", prompt: "like the post"))
        #expect(Grammar.parse("Tell billing to the", known: Self.known) == .unknown)
    }
}
