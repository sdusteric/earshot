import Testing
@testable import EarshotKit

@Suite struct ModelProgressTests {
    @Test func progressNeverMovesBack() {
        let now = ListenModels.State.downloading(0.5)
        #expect(now.showing(.downloading(0.4)) == .downloading(0.5))
        #expect(now.showing(.downloading(0.6)) == .downloading(0.6))
        #expect(now.showing(.ready) == .ready)
        #expect(now.showing(.failed) == .failed)
        #expect(ListenModels.State.failed.showing(.downloading(0)) == .downloading(0))
    }

    @Test func percentIsWhole() {
        #expect(ListenModels.State.downloading(0.426).percent == "42%")
        #expect(ListenModels.State.ready.percent == nil)
    }
}
