import Foundation
import Testing
@testable import EarshotKit

struct ProcessTreeTests {
    @Test func theChainRunsUpToJustBeforeLaunchd() {
        let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 1]
        #expect(ProcessTree.ancestors(of: 500, parent: { parents[$0] }) == [500, 400, 300])
    }

    @Test func aLoopOrALongChainStops() {
        #expect(ProcessTree.ancestors(of: 10, parent: { $0 == 10 ? 11 : 10 }) == [10, 11])
        #expect(ProcessTree.ancestors(of: 1000, limit: 3, parent: { $0 - 1 }).count == 3)
    }

    @Test func thisProcessHasAParent() {
        #expect(ProcessTree.parent(of: getpid()) != nil)
        #expect(ProcessTree.ancestors(of: getpid()).first == getpid())
    }
}
