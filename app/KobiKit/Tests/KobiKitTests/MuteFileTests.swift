import Foundation
import Testing
@testable import KobiKit

@Suite struct MuteFileTests {
    let now = Date(timeIntervalSince1970: 1_791_800_000)

    @Test func readsTheFileAsThePluginDoes() {
        #expect(MuteFile.until(nil, now: now) == nil)
        #expect(MuteFile.until("", now: now) == .distantFuture)
        #expect(MuteFile.until("\n", now: now) == .distantFuture)
        #expect(MuteFile.until("1791803600\n", now: now) == Date(timeIntervalSince1970: 1_791_803_600))
        #expect(MuteFile.until("1791799999\n", now: now) == nil)   // ran out
    }

    @Test func writesWholeSeconds() {
        let until = Date(timeIntervalSince1970: 1_791_803_600.75)
        #expect(MuteFile.text(until: until) == "1791803600\n")
        #expect(MuteFile.until(MuteFile.text(until: until), now: now) == Date(timeIntervalSince1970: 1_791_803_600))
    }
}
