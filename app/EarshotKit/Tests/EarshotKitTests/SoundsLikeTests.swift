import Testing
@testable import EarshotKit

@Suite struct SoundsLikeTests {
    @Test(arguments: [
        ("sessions", "SXNS"), ("sections", "SKXNS"), ("earshot", "ARXT"), ("your", "AR"), ("shot", "XT"),
        ("phone", "FN"), ("knight", "NT"), ("thing", "0NK"), ("check", "XK"), ("blog", "PLK"), ("2nd", "SKNT"),
    ])
    func keys(_ word: String, _ key: String) {
        #expect(SoundsLike.key(word) == key)
    }

    @Test func misheardWordsSoundAlike() {
        #expect(SoundsLike.similarity("sessions", "sections") >= 0.75)
        #expect(SoundsLike.similarity("going", "gone") >= 0.6)
        #expect(SoundsLike.similarity("sessions", "seconds") >= 0.5)
        #expect(SoundsLike.similarity("earshot", "airshot") >= 0.85)
        #expect(SoundsLike.similarity("Kairos", "kairos") == 1)
    }

    @Test func differentWordsDoNot() {
        #expect(SoundsLike.similarity("blog", "billing") < 0.65)
        #expect(SoundsLike.similarity("sessions", "lunch") < 0.4)
        #expect(SoundsLike.similarity("yes", "no") < 0.4)
    }

    @Test func theEndOfANameCanStandForIt() {
        #expect(SoundsLike.endsName("shot", "earshot"))
        #expect(SoundsLike.endsName("brief", "finebrief"))
        #expect(SoundsLike.endsName("service", "billing service"))
        #expect(!SoundsLike.endsName("log", "blog"))   // too short to be sure
        #expect(!SoundsLike.endsName("earshot", "earshot"))
    }
}
