import Foundation
import Synchronization
import Testing
@testable import KobiKit

/// A home folder with what Earshot left on a Mac, and empty defaults for Kobi.
struct OldHome {
    let home = FileManager.default.temporaryDirectory.appending(path: "kobi-migration-\(UUID().uuidString)")
    let suite = "kobi-migration-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var oldConfig: URL { home.appending(path: ".config/earshot") }
    var oldSupport: URL { home.appending(path: "Library/Application Support/Earshot") }
    var newConfig: URL { home.appending(path: ".config/kobi") }
    var newSupport: URL { home.appending(path: "Library/Application Support/Kobi") }

    func write(_ url: URL, _ text: String, mode: Int = 0o644) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
        chmod(url.path, mode_t(mode))
    }

    func fill() {
        write(oldConfig.appending(path: "config"), "EARSHOT_KEY='sk-secret'\nEARSHOT_LEVEL=quiet\n# EARSHOT_STYLE=cheeky\nOTHER=EARSHOT_X\n", mode: 0o600)
        write(oldConfig.appending(path: "mute"), "")
        write(oldConfig.appending(path: "kokoro/earshot-tts"), "binary", mode: 0o755)
        write(oldConfig.appending(path: "kokoro/source.md5"), "abc\n")
        write(oldConfig.appending(path: "kokoro-build/out/big"), "cache")
        write(oldSupport.appending(path: "history.jsonl"), "{}\n", mode: 0o600)
        write(oldSupport.appending(path: "session-names.json"), "{}", mode: 0o600)
        write(oldSupport.appending(path: "earshot.sock"), "")
        write(oldSupport.appending(path: "app.lock"), "")
        chmod(oldSupport.path, 0o700)
    }

    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func mode(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func migration(old: [String: Any]? = nil) -> Migration { Migration(home: home, defaults: defaults, oldDefaults: { old }) }

    func clean() {
        try? FileManager.default.removeItem(at: home)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@Suite struct MigrationTests {
    @Test func copiesTheConfigAndTheAppFolderAndRenamesTheKeys() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        let report = h.migration().run(quitOld: { false })
        let config = h.newConfig.appending(path: "config")
        #expect(h.text(config) == "KOBI_KEY='sk-secret'\nKOBI_LEVEL=quiet\n# EARSHOT_STYLE=cheeky\nOTHER=EARSHOT_X\n")
        #expect(h.mode(config) == 0o600)
        #expect(h.exists(h.newConfig.appending(path: "mute")))
        #expect(h.mode(h.newConfig.appending(path: "kokoro/kobi-tts")) == 0o755)
        #expect(!h.exists(h.newConfig.appending(path: "kokoro/earshot-tts")))
        #expect(h.text(h.newConfig.appending(path: "kokoro/source.md5")) == "abc\n")
        #expect(!h.exists(h.newConfig.appending(path: "kokoro-build")))
        #expect(h.text(h.newSupport.appending(path: "history.jsonl")) == "{}\n")
        #expect(h.mode(h.newSupport.appending(path: "history.jsonl")) == 0o600)
        #expect(h.mode(h.newSupport) == 0o700)
        #expect(h.exists(h.newSupport.appending(path: "session-names.json")))
        #expect(!h.exists(h.newSupport.appending(path: "earshot.sock")))
        #expect(!h.exists(h.newSupport.appending(path: "kobi.sock")))
        #expect(!h.exists(h.newSupport.appending(path: "app.lock")))
        #expect(report.copied.count == 6)
        #expect(report.copied.allSatisfy { $0.hasPrefix(h.newConfig.path) || $0.hasPrefix(h.newSupport.path) })
        // The old files stay.
        #expect(h.text(h.oldConfig.appending(path: "config"))?.hasPrefix("EARSHOT_KEY=") == true)
        #expect(h.exists(h.oldConfig.appending(path: "kokoro/earshot-tts")))
        #expect(h.exists(h.oldSupport.appending(path: "history.jsonl")))
    }

    @Test func runsOnce() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        #expect(!h.migration().run(quitOld: { false }).copied.isEmpty)
        try? FileManager.default.removeItem(at: h.newConfig)
        let again = h.migration().run(quitOld: { Issue.record("asked to quit again"); return false })
        #expect(again.alreadyDone && again.copied.isEmpty)
        #expect(!h.exists(h.newConfig))
    }

    /// The app's lock is taken before the migration runs: a folder with only it counts as absent.
    @Test func aLockAloneIsNoData() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        h.write(h.newSupport.appending(path: "app.lock"), "")
        h.migration().run(quitOld: { false })
        #expect(h.exists(h.newSupport.appending(path: "history.jsonl")))
    }

    @Test func aNewFolderWithItsOwnFilesIsLeftAlone() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        h.write(h.newConfig.appending(path: "config"), "KOBI_LEVEL=all\n", mode: 0o600)
        let report = h.migration().run(quitOld: { false })
        #expect(h.text(h.newConfig.appending(path: "config")) == "KOBI_LEVEL=all\n")
        #expect(!h.exists(h.newConfig.appending(path: "mute")))
        #expect(h.exists(h.newSupport.appending(path: "history.jsonl")))   // the other folder still moves
        #expect(report.copied.allSatisfy { $0.hasPrefix(h.newSupport.path) })
    }

    @Test func copiesOnlySettingsKobiDoesNotHave() {
        let h = OldHome(); defer { h.clean() }
        h.defaults.set("mine", forKey: "activityOpenExpanded")
        let report = h.migration(old: ["onboarded": true, "orbPosition": [10.0, 20.0], "activityOpenExpanded": "theirs"])
            .run(quitOld: { false })
        #expect(h.defaults.bool(forKey: "onboarded"))
        #expect(h.defaults.array(forKey: "orbPosition") as? [Double] == [10, 20])
        #expect(h.defaults.string(forKey: "activityOpenExpanded") == "mine")
        #expect(report.settings == ["onboarded", "orbPosition"])
    }

    /// What Earshot saves as it quits (the orb's place) is copied too.
    @Test func theSettingsAreReadAgainAfterTheOldAppQuit() {
        let h = OldHome(); defer { h.clean() }
        let quit = Mutex(false)
        let m = Migration(home: h.home, defaults: h.defaults,
                          oldDefaults: { quit.withLock { $0 } ? ["onboarded": true, "orbPosition": [1.0, 2.0]] : ["onboarded": true] })
        let report = m.run(quitOld: { quit.withLock { $0 = true }; return true })
        #expect(report.settings == ["onboarded", "orbPosition"])
    }

    @Test func theOldAppIsAskedToQuitOnlyWhenThereIsSomethingToCopy() {
        let none = OldHome(); defer { none.clean() }
        let quiet = none.migration().run(quitOld: { Issue.record("nothing to copy"); return false })
        #expect(quiet == Migration.Report())
        #expect(none.defaults.bool(forKey: Migration.doneKey))

        let h = OldHome(); h.fill(); defer { h.clean() }
        var asked = false
        let report = h.migration().run(quitOld: { asked = true; return true })
        #expect(asked && report.quitOld)
    }

    @Test func renamesOnlyTheKeys() {
        #expect(Migration.renameKeys("EARSHOT_A=1\n  export EARSHOT_B='EARSHOT_C'\nX=EARSHOT_D\n")
                == "KOBI_A=1\n  export KOBI_B='EARSHOT_C'\nX=EARSHOT_D\n")
        #expect(Migration.renamed("earshot-tts") == "kobi-tts")
        #expect(Migration.renamed("history.jsonl") == "history.jsonl")
    }
}
