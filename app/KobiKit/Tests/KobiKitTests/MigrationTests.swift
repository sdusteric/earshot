import Foundation
import Synchronization
import Testing
@testable import KobiKit

/// A home folder with what Earshot left on a Mac, and empty defaults for Kobi. The defaults are
/// a plist in the temporary home (a suite named by a path), so nothing is written to
/// ~/Library/Preferences, and clean() removes them with the home.
struct OldHome {
    let home = FileManager.default.temporaryDirectory.appending(path: "kobi-migration-\(UUID().uuidString)")
    var suite: String { home.appending(path: "defaults").path }
    var defaults: UserDefaults {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return UserDefaults(suiteName: suite)!
    }
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

    func link(_ url: URL, to destination: String) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }
    func isLink(_ url: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }
    var done: Bool { defaults.bool(forKey: Migration.doneKey) }

    func clean() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }
}

/// The tests never write to the real ~/Library/Preferences.
@Suite struct MigrationDefaultsTests {
    @Test func theTestDefaultsLiveInTheTemporaryHome() {
        let h = OldHome(); defer { h.clean() }
        h.migration(old: ["orbPosition": [1.0, 2.0]]).run(quitOld: { .notRunning })
        #expect(h.suite.hasPrefix(FileManager.default.temporaryDirectory.path))
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: prefs.path)) ?? []
        #expect(!left.contains { $0.contains(h.home.lastPathComponent) })
    }
}

@Suite struct MigrationTests {
    @Test func copiesTheConfigAndTheAppFolderAndRenamesTheKeys() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        let report = h.migration().run(quitOld: { .notRunning })
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
        #expect(!h.migration().run(quitOld: { .notRunning }).copied.isEmpty)
        try? FileManager.default.removeItem(at: h.newConfig)
        let again = h.migration().run(quitOld: { Issue.record("asked to quit again"); return .notRunning })
        #expect(again.alreadyDone && again.copied.isEmpty)
        #expect(!h.exists(h.newConfig))
    }

    /// The app's lock is taken before the migration runs: a folder with only it counts as absent.
    @Test func aLockAloneIsNoData() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        h.write(h.newSupport.appending(path: "app.lock"), "")
        h.migration().run(quitOld: { .notRunning })
        #expect(h.exists(h.newSupport.appending(path: "history.jsonl")))
    }

    @Test func aNewFolderWithItsOwnFilesIsLeftAlone() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        h.write(h.newConfig.appending(path: "config"), "KOBI_LEVEL=all\n", mode: 0o600)
        let report = h.migration().run(quitOld: { .notRunning })
        #expect(h.text(h.newConfig.appending(path: "config")) == "KOBI_LEVEL=all\n")
        #expect(!h.exists(h.newConfig.appending(path: "mute")))
        #expect(h.exists(h.newSupport.appending(path: "history.jsonl")))   // the other folder still moves
        #expect(report.copied.allSatisfy { $0.hasPrefix(h.newSupport.path) })
        #expect(report.skipped == [h.newConfig.path])
        #expect(h.done)
    }

    /// A file that couldn't be copied leaves the marker unset; the next launch copies it, into the
    /// folder this run began (which has files now), and then sets it.
    @Test func theMarkerWaitsForACleanRun() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        chmod(h.oldConfig.appending(path: "config").path, 0)
        let first = h.migration().run(quitOld: { .notRunning })
        #expect(!first.failed.isEmpty)
        #expect(!h.done)
        #expect(h.exists(h.newConfig.appending(path: "mute")))
        chmod(h.oldConfig.appending(path: "config").path, 0o600)
        let second = h.migration().run(quitOld: { .notRunning })
        #expect(second.failed.isEmpty && second.skipped.isEmpty)
        #expect(h.text(h.newConfig.appending(path: "config"))?.hasPrefix("KOBI_KEY='sk-secret'\n") == true)
        #expect(h.done)
    }

    /// Killed after the config was copied but before its keys were renamed: the next launch renames them.
    @Test func aRunCutShortIsFinishedNextLaunch() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        h.write(h.newConfig.appending(path: "config"), "EARSHOT_KEY='sk-secret'\n", mode: 0o600)
        h.defaults.set([h.newConfig.path], forKey: Migration.begunKey)
        h.migration().run(quitOld: { .notRunning })
        #expect(h.text(h.newConfig.appending(path: "config")) == "KOBI_KEY='sk-secret'\n")
        #expect(h.exists(h.newConfig.appending(path: "mute")))
        #expect(h.done)
    }

    /// A config kept in a dotfiles folder and linked: the file it points to is copied, as a file
    /// with its permissions and the keys renamed, and the dotfiles copy is left as it was.
    @Test func aLinkedConfigIsCopiedAsAFile() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        let dotfile = h.home.appending(path: "dotfiles/earshot-config")
        h.write(dotfile, "EARSHOT_KEY='sk-secret'\n", mode: 0o600)
        try! FileManager.default.removeItem(at: h.oldConfig.appending(path: "config"))
        h.link(h.oldConfig.appending(path: "config"), to: dotfile.path)
        h.migration().run(quitOld: { .notRunning })
        let config = h.newConfig.appending(path: "config")
        #expect(!h.isLink(config))
        #expect(h.text(config) == "KOBI_KEY='sk-secret'\n")
        #expect(h.mode(config) == 0o600)
        #expect(h.text(dotfile) == "EARSHOT_KEY='sk-secret'\n")
        #expect(h.done)
    }

    /// ~/.config/earshot itself a link to a dotfiles folder: followed, and the new folder is 0700.
    @Test func aLinkedFolderIsFollowed() {
        let h = OldHome(); defer { h.clean() }
        let dir = h.home.appending(path: "dotfiles/earshot")
        h.write(dir.appending(path: "config"), "EARSHOT_LEVEL=quiet\n", mode: 0o600)
        chmod(dir.path, 0o755)
        h.link(h.oldConfig, to: dir.path)
        h.migration().run(quitOld: { .notRunning })
        #expect(!h.isLink(h.newConfig))
        #expect(h.mode(h.newConfig) == 0o700)
        #expect(h.text(h.newConfig.appending(path: "config")) == "KOBI_LEVEL=quiet\n")
        #expect(h.text(dir.appending(path: "config")) == "EARSHOT_LEVEL=quiet\n")
    }

    /// A relative link to a file that is renamed points at the new name.
    @Test func aRelativeLinkFollowsTheRename() throws {
        let h = OldHome(); h.fill(); defer { h.clean() }
        h.link(h.oldConfig.appending(path: "kokoro/current"), to: "earshot-tts")
        h.migration().run(quitOld: { .notRunning })
        let current = h.newConfig.appending(path: "kokoro/current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == "kobi-tts")
        #expect(h.text(current) == "binary")
    }

    /// Earshot still running after the wait: its history is not copied while it may be writing it,
    /// and the next launch copies it.
    @Test func theHistoryWaitsWhileEarshotStillRuns() {
        let h = OldHome(); h.fill(); defer { h.clean() }
        let first = h.migration().run(quitOld: { .stillRunning })
        #expect(!h.exists(h.newSupport.appending(path: "history.jsonl")))
        #expect(h.exists(h.newConfig.appending(path: "config")))
        #expect(!h.done && first.quitOld)
        h.migration().run(quitOld: { .quit })
        #expect(h.text(h.newSupport.appending(path: "history.jsonl")) == "{}\n")
        #expect(h.done)
    }

    @Test func copiesOnlySettingsKobiDoesNotHave() {
        let h = OldHome(); defer { h.clean() }
        h.defaults.set("mine", forKey: "activityOpenExpanded")
        let report = h.migration(old: ["onboarded": true, "orbPosition": [10.0, 20.0], "activityOpenExpanded": "theirs"])
            .run(quitOld: { .notRunning })
        #expect(h.defaults.object(forKey: "onboarded") == nil)   // the welcome steps ask for the permissions again
        #expect(h.defaults.array(forKey: "orbPosition") as? [Double] == [10, 20])
        #expect(h.defaults.string(forKey: "activityOpenExpanded") == "mine")
        #expect(report.settings == ["orbPosition"])
    }

    /// What Earshot saves as it quits (the orb's place) is copied too.
    @Test func theSettingsAreReadAgainAfterTheOldAppQuit() {
        let h = OldHome(); defer { h.clean() }
        let quit = Mutex(false)
        let m = Migration(home: h.home, defaults: h.defaults,
                          oldDefaults: { quit.withLock { $0 } ? ["hotkeySeen": true, "orbPosition": [1.0, 2.0]] : ["hotkeySeen": true] })
        let report = m.run(quitOld: { quit.withLock { $0 = true }; return .quit })
        #expect(report.settings == ["hotkeySeen", "orbPosition"])
    }

    @Test func theOldAppIsAskedToQuitOnlyWhenThereIsSomethingToCopy() {
        let none = OldHome(); defer { none.clean() }
        let quiet = none.migration().run(quitOld: { Issue.record("nothing to copy"); return .notRunning })
        #expect(quiet == Migration.Report())
        #expect(none.defaults.bool(forKey: Migration.doneKey))

        let h = OldHome(); h.fill(); defer { h.clean() }
        var asked = false
        let report = h.migration().run(quitOld: { asked = true; return .quit })
        #expect(asked && report.quitOld)
    }

    @Test func renamesOnlyTheKeys() {
        #expect(Migration.renameKeys("EARSHOT_A=1\n  export EARSHOT_B='EARSHOT_C'\nX=EARSHOT_D\n")
                == "KOBI_A=1\n  export KOBI_B='EARSHOT_C'\nX=EARSHOT_D\n")
        #expect(Migration.renamed("earshot-tts") == "kobi-tts")
        #expect(Migration.renamed("history.jsonl") == "history.jsonl")
    }
}
