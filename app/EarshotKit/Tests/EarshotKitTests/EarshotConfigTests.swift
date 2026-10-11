import Foundation
import Testing
@testable import EarshotKit

@Suite struct EarshotConfigTests {
    @Test func readsPlainQuotedAndPrintfQValues() {
        let c = EarshotConfig(text: """
        # comment stays
        EARSHOT_ENGINE=elevenlabs
        EARSHOT_KEY='sk_abc'
        EARSHOT_VOICE="v1"
        EARSHOT_SAY_VOICE=Samantha\\ \\(Enhanced\\)
        EARSHOT_STYLE=$'cheeky'
        """)
        #expect(c["EARSHOT_ENGINE"] == "elevenlabs")
        #expect(c["EARSHOT_KEY"] == "sk_abc")
        #expect(c["EARSHOT_VOICE"] == "v1")
        #expect(c["EARSHOT_SAY_VOICE"] == "Samantha (Enhanced)")
        #expect(c["EARSHOT_STYLE"] == "cheeky")
    }

    /// What setup.sh really writes for non-ASCII values: bash's printf %q.
    @Test func readsBashPrintfQForNonASCII() throws {
        for value in ["Amélie", "Jorge (Español)", "tab\there", "it's", "日本"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "printf 'EARSHOT_SAY_VOICE=%q\\n' \"$1\"", "_", value]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run(); p.waitUntilExit()
            let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(EarshotConfig(text: line)["EARSHOT_SAY_VOICE"] == value, "bash wrote \(line)")
        }
    }

    @Test func lastLineWins() {
        let c = EarshotConfig(text: "EARSHOT_LEVEL=quiet\nEARSHOT_LEVEL=all\n")
        #expect(c.level == "all")
    }

    @Test func setReplacesInPlaceAndKeepsOtherLines() {
        var c = EarshotConfig(text: "# keep me\nEARSHOT_LEVEL=quiet\nEARSHOT_STYLE=plain\n")
        c.set("EARSHOT_LEVEL", "all")
        c.set("EARSHOT_DUCK", "off")
        c.set("EARSHOT_STYLE", nil)
        #expect(c.text == "# keep me\nEARSHOT_LEVEL='all'\nEARSHOT_DUCK='off'\n")
    }

    @Test func quotesValuesForBash() throws {
        var c = EarshotConfig(text: "")
        c.set("EARSHOT_SAY_VOICE", "it's")
        #expect(c.text == "EARSHOT_SAY_VOICE='it'\\''s'\n")
        let url = FileManager.default.temporaryDirectory.appending(path: "ek-conf-\(UUID().uuidString)")
        try c.save(to: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", ". \"$1\"; printf %s \"$EARSHOT_SAY_VOICE\"", "_", url.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "it's")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(EarshotConfig.load(from: url)["EARSHOT_SAY_VOICE"] == "it's")
    }

    @Test func engineRuleMatchesSpeakSh() {
        #expect(EarshotConfig(text: "").engine == .kokoro)
        #expect(EarshotConfig(text: "EARSHOT_KEY=k").engine == .elevenlabs)
        #expect(EarshotConfig(text: "EARSHOT_KEY=k\nEARSHOT_ENGINE=say").engine == .say)
        #expect(EarshotConfig(text: "EARSHOT_ENGINE=banjo").engine == .kokoro)
    }

    @Test func defaults() {
        let c = EarshotConfig(text: "")
        #expect(c.level == "normal" && c.style == "plain")
        #expect(c.kokoroVoice == "af_heart" && c.elevenLabsModel == "eleven_v4_turbo")
        #expect(c.duckEnabled && c.duckLevel == 0.3)
        #expect(EarshotConfig(text: "EARSHOT_DUCK=off\nEARSHOT_DUCK_LEVEL=5").duckEnabled == false)
        #expect(EarshotConfig(text: "EARSHOT_DUCK_LEVEL=5").duckLevel == 0.1)
        #expect(EarshotConfig(text: "EARSHOT_DUCK_LEVEL=50").duckLevel == 0.5)
    }

    @Test func missingFileIsEmpty() {
        #expect(EarshotConfig.load(from: URL(fileURLWithPath: "/nonexistent/config")).text == "")
    }
}
