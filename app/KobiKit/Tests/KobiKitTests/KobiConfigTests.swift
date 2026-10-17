import Foundation
import Testing
@testable import KobiKit

@Suite struct KobiConfigTests {
    @Test func readsPlainQuotedAndPrintfQValues() {
        let c = KobiConfig(text: """
        # comment stays
        KOBI_ENGINE=elevenlabs
        KOBI_KEY='sk_abc'
        KOBI_VOICE="v1"
        KOBI_SAY_VOICE=Samantha\\ \\(Enhanced\\)
        KOBI_STYLE=$'cheeky'
        """)
        #expect(c["KOBI_ENGINE"] == "elevenlabs")
        #expect(c["KOBI_KEY"] == "sk_abc")
        #expect(c["KOBI_VOICE"] == "v1")
        #expect(c["KOBI_SAY_VOICE"] == "Samantha (Enhanced)")
        #expect(c["KOBI_STYLE"] == "cheeky")
    }

    /// What setup.sh really writes for non-ASCII values: bash's printf %q.
    @Test func readsBashPrintfQForNonASCII() throws {
        for value in ["Amélie", "Jorge (Español)", "tab\there", "it's", "日本"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "printf 'KOBI_SAY_VOICE=%q\\n' \"$1\"", "_", value]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run(); p.waitUntilExit()
            let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(KobiConfig(text: line)["KOBI_SAY_VOICE"] == value, "bash wrote \(line)")
        }
    }

    @Test func lastLineWins() {
        let c = KobiConfig(text: "KOBI_LEVEL=quiet\nKOBI_LEVEL=all\n")
        #expect(c.level == "all")
    }

    @Test func setReplacesInPlaceAndKeepsOtherLines() {
        var c = KobiConfig(text: "# keep me\nKOBI_LEVEL=quiet\nKOBI_STYLE=plain\n")
        c.set("KOBI_LEVEL", "all")
        c.set("KOBI_DUCK", "off")
        c.set("KOBI_STYLE", nil)
        #expect(c.text == "# keep me\nKOBI_LEVEL='all'\nKOBI_DUCK='off'\n")
    }

    @Test func quotesValuesForBash() throws {
        var c = KobiConfig(text: "")
        c.set("KOBI_SAY_VOICE", "it's")
        #expect(c.text == "KOBI_SAY_VOICE='it'\\''s'\n")
        let url = FileManager.default.temporaryDirectory.appending(path: "ek-conf-\(UUID().uuidString)")
        try c.save(to: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", ". \"$1\"; printf %s \"$KOBI_SAY_VOICE\"", "_", url.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "it's")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(KobiConfig.load(from: url)["KOBI_SAY_VOICE"] == "it's")
    }

    @Test func engineRuleMatchesSpeakSh() {
        #expect(KobiConfig(text: "").engine == .kokoro)
        #expect(KobiConfig(text: "KOBI_KEY=k").engine == .elevenlabs)
        #expect(KobiConfig(text: "KOBI_KEY=k\nKOBI_ENGINE=say").engine == .say)
        #expect(KobiConfig(text: "KOBI_ENGINE=banjo").engine == .kokoro)
    }

    @Test func defaults() {
        let c = KobiConfig(text: "")
        #expect(c.level == "normal" && c.style == "plain")
        #expect(c.kokoroVoice == "af_heart" && c.elevenLabsModel == "eleven_v4_turbo")
        #expect(c.duckEnabled && c.duckLevel == 0.3)
        #expect(KobiConfig(text: "KOBI_DUCK=off\nKOBI_DUCK_LEVEL=5").duckEnabled == false)
        #expect(KobiConfig(text: "KOBI_DUCK_LEVEL=5").duckLevel == 0.1)
        #expect(KobiConfig(text: "KOBI_DUCK_LEVEL=50").duckLevel == 0.5)
    }

    @Test func recapAndBannerAreOnUnlessTurnedOff() {
        let c = KobiConfig(text: "")
        #expect(c.recap && c.banner)
        #expect(KobiConfig(text: "KOBI_RECAP=on\nKOBI_BANNER=on").recap)
        #expect(KobiConfig(text: "KOBI_RECAP=on\nKOBI_BANNER=on").banner)
        #expect(!KobiConfig(text: "KOBI_RECAP=off").recap)
        #expect(!KobiConfig(text: "KOBI_BANNER=off").banner)
    }

    @Test func missingFileIsEmpty() {
        #expect(KobiConfig.load(from: URL(fileURLWithPath: "/nonexistent/config")).text == "")
    }

    @Test func listeningDefaults() {
        let c = KobiConfig(text: "")
        #expect(c.wakeWord == false)
        #expect(c.wakeOnBattery == .lowpower)
        #expect(c.wakeSensitivity == 5)
        #expect(c.hotkey == .rightOption)
        #expect(c.inputDevice == nil)
    }

    @Test func listeningValues() {
        let c = KobiConfig(text: """
        KOBI_WAKE=on
        KOBI_WAKE_BATTERY=power
        KOBI_WAKE_SENSITIVITY=12
        KOBI_HOTKEY=right_command
        KOBI_INPUT='BuiltInMicrophoneDevice'
        """)
        #expect(c.wakeWord)
        #expect(c.wakeOnBattery == .power)
        #expect(c.wakeSensitivity == 10)   // clamped
        #expect(c.hotkey == .rightCommand)
        #expect(c.inputDevice == "BuiltInMicrophoneDevice")
    }

    @Test func unknownListeningValuesFallBack() {
        let c = KobiConfig(text: "KOBI_WAKE_BATTERY=sometimes\nKOBI_HOTKEY=fn\nKOBI_WAKE_SENSITIVITY=x\n")
        #expect(c.wakeOnBattery == .lowpower)
        #expect(c.hotkey == .rightOption)
        #expect(c.wakeSensitivity == 5)
    }
}
