import Testing
@testable import EarshotKit

@Suite struct ListenPolicyTests {
    /// Everything allows listening; each test changes one thing.
    var ok: ListenInputs {
        var i = ListenInputs()
        i.micAllowed = true; i.modelsReady = true; i.wakeWord = true; i.liveSessions = 1
        return i
    }

    @Test func allClear() {
        #expect(ListenPolicy.wakeBlock(ok) == nil)
        #expect(ListenPolicy.commandBlock(ok) == nil)
        #expect(ListenPolicy.canListen(ok))
    }

    @Test func oneThingBlocksTheWakeWord() {
        let cases: [(WritableKeyPath<ListenInputs, Bool>, Bool, ListenBlock)] = [
            (\.micAllowed, false, .micPermission),
            (\.wakeWord, false, .wakeOff),
            (\.asleep, true, .asleep),
            (\.locked, true, .locked),
            (\.micInUse, true, .micInUse),
            (\.lowPower, true, .lowPower),
        ]
        for (key, value, block) in cases {
            var i = ok
            i[keyPath: key] = value
            #expect(ListenPolicy.wakeBlock(i) == block)
        }
    }

    @Test func modelsBlockWithProgress() {
        var i = ok
        i.modelsReady = false; i.modelProgress = 0.4
        #expect(ListenPolicy.wakeBlock(i) == .models(0.4))
        #expect(ListenPolicy.commandBlock(i) == .models(0.4))
        #expect(ListenPolicy.menuLine(.models(0.4)) == "Listening starts when the speech models finish downloading (40%).")
    }

    @Test func noSessionsBlocksOnlyTheWakeWord() {
        var i = ok
        i.liveSessions = 0
        #expect(ListenPolicy.wakeBlock(i) == .noSessions)
        #expect(ListenPolicy.commandBlock(i) == nil)   // "start a session in blog" still works
    }

    @Test func batteryRules() {
        var i = ok
        i.onBattery = true
        i.battery = .always
        #expect(ListenPolicy.wakeBlock(i) == nil)
        i.battery = .power
        #expect(ListenPolicy.wakeBlock(i) == .battery)
        i.battery = .lowpower
        #expect(ListenPolicy.wakeBlock(i) == nil)
        i.lowPower = true
        #expect(ListenPolicy.wakeBlock(i) == .lowPower)
        i.battery = .always
        #expect(ListenPolicy.wakeBlock(i) == nil)
        // "Only on power" ignores Low Power Mode: it is the battery rule that counts.
        i.battery = .power
        i.onBattery = false
        #expect(ListenPolicy.wakeBlock(i) == nil)
        i.onBattery = true
        #expect(ListenPolicy.wakeBlock(i) == .battery)
    }

    /// The hotkey and voice answers do not follow the wake word's rules, but
    /// they never take the mic from a call, and never while the Mac is locked.
    @Test func commandsFollowFewerRules() {
        var i = ok
        i.wakeWord = false; i.lowPower = true; i.onBattery = true; i.battery = .power
        #expect(ListenPolicy.commandBlock(i) == nil)
        i.micInUse = true
        #expect(ListenPolicy.commandBlock(i) == .micInUse)
        i.micInUse = false; i.locked = true
        #expect(ListenPolicy.commandBlock(i) == .locked)
    }

    @Test func canListenNeedsATrigger() {
        var i = ok
        i.wakeWord = false; i.hotkey = .off
        #expect(!ListenPolicy.canListen(i))
        i.hotkey = .rightCommand
        #expect(ListenPolicy.canListen(i))
    }

    @Test func everyBlockHasAMenuLineWithoutEmDashes() {
        let all: [ListenBlock] = [.micPermission, .models(nil), .models(0.5), .wakeOff, .asleep, .locked, .micInUse,
                                  .lowPower, .battery, .noSessions]
        for b in all {
            let line = ListenPolicy.menuLine(b)
            #expect(!line.isEmpty)
            #expect(!line.contains("\u{2014}"))
        }
    }
}
