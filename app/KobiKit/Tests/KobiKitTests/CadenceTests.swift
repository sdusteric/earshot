import Foundation
import Testing
@testable import KobiKit

@Suite struct CadenceTests {
    @Test func theSessionPageReadsOftenOnlyWhileYouLookAtIt() {
        #expect(Cadence.transcriptPoll(.init(visible: true, key: true)) == .seconds(4))
        #expect(Cadence.transcriptPoll(.init(visible: true, key: false)) == .seconds(15))
        #expect(Cadence.transcriptPoll(.init(visible: false, key: false)) == nil)
        // A key window that is fully covered still counts as out of sight.
        #expect(Cadence.transcriptPoll(.init(visible: false, key: true)) == nil)
    }

    @Test func theOrbDrawsOnlyWhereItCanBeSeen() {
        // The floating orb: drawn while active, stopped at rest.
        #expect(!Cadence.orbPaused(active: true, spinsWhenIdle: false, visible: true))
        #expect(Cadence.orbPaused(active: false, spinsWhenIdle: false, visible: true))
        // The Activity window's orb turns at rest, but not out of sight.
        #expect(!Cadence.orbPaused(active: false, spinsWhenIdle: true, visible: true))
        #expect(Cadence.orbPaused(active: false, spinsWhenIdle: true, visible: false))
        // Listening with the orb turned off in Settings: the panel never shows.
        #expect(Cadence.orbPaused(active: true, spinsWhenIdle: false, visible: false))
    }

    @Test func theSessionListWaitsWhileYouAreAway() {
        #expect(Cadence.directoryRefresh(locked: false, asleep: false, lowPower: false) == 60)
        #expect(Cadence.directoryRefresh(locked: false, asleep: false, lowPower: true) == 180)
        #expect(Cadence.directoryRefresh(locked: true, asleep: false, lowPower: false) == nil)
        #expect(Cadence.directoryRefresh(locked: false, asleep: true, lowPower: true) == nil)
    }

    @Test func aCheckIsDueOnceItsWaitHasPassed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func due(_ ago: TimeInterval?, locked: Bool = false, lowPower: Bool = false) -> Bool {
            Cadence.directoryRefreshDue(last: ago.map { now.addingTimeInterval(-$0) }, now: now,
                                        locked: locked, asleep: false, lowPower: lowPower)
        }
        #expect(due(nil))
        #expect(!due(30))
        #expect(due(60))
        #expect(!due(120, lowPower: true))
        #expect(due(180, lowPower: true))
        // Locked: never due, however old the last check; unlocking makes it due at once.
        #expect(!due(nil, locked: true))
        #expect(!due(3600, locked: true))
        #expect(due(3600))
    }
}
