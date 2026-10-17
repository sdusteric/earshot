import AppKit
import Foundation
import os

/// Kobi was called Earshot. On the first launch after the rename, what Earshot kept on
/// this Mac is copied to Kobi's places, once: ~/.config/earshot to ~/.config/kobi (the
/// plugin's config, with the keys renamed EARSHOT_X to KOBI_X), ~/Library/Application
/// Support/Earshot to .../Kobi (history, session names), and the settings in the
/// com.earshot.app defaults that com.kobi.app doesn't have yet. The old files stay where
/// they are. It runs before anything reads the config or the history.
public struct Migration {
    public static let oldBundleID = "com.earshot.app"
    /// Set once the migration ran, whatever it found, so it never runs again.
    public static let doneKey = "migratedFromEarshot"

    /// Never copied: sockets and locks belong to the process that made them, and the
    /// Kokoro build folder is a cache of about a gigabyte that build-tts.sh makes again.
    static let skipped: Set<String> = ["earshot.sock", "kobi.sock", "app.lock", ".DS_Store", "kokoro-build", "kokoro-build.log"]

    /// What the migration did, for the log and the tests.
    public struct Report: Sendable, Equatable {
        /// Files copied, by their new paths.
        public var copied: [String] = []
        /// Settings copied from the old defaults, by key.
        public var settings: [String] = []
        /// The old app was asked to quit.
        public var quitOld = false
        /// It ran before (the marker was set), so it did nothing.
        public var alreadyDone = false
    }

    let home: URL
    let defaults: UserDefaults
    let oldDefaults: () -> [String: Any]?
    private let log = Logger(subsystem: "com.kobi.app", category: "migration")

    /// `oldDefaults` reads Earshot's settings: UserDefaults.standard.persistentDomain(forName:
    /// Migration.oldBundleID) in the app (it is not sandboxed, so it can read them). It is read
    /// again after Earshot quit, so what it saved on the way out is copied too.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard,
                oldDefaults: @escaping () -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: Migration.oldBundleID) }) {
        self.home = home
        self.defaults = defaults
        self.oldDefaults = oldDefaults
    }

    /// The folders to copy, old to new.
    var folders: [(old: URL, new: URL)] {
        [(home.appending(path: ".config/earshot"), home.appending(path: ".config/kobi")),
         (home.appending(path: "Library/Application Support/Earshot"), home.appending(path: "Library/Application Support/Kobi"))]
    }

    /// Copies what there is to copy, once. `quitOld` asks a running Earshot to quit and waits
    /// for it (each app has its own single-instance lock, so both would run); it is called
    /// only when there is something to copy.
    @discardableResult
    public func run(quitOld: () -> Bool = Migration.quitOldApp) -> Report {
        var report = Report()
        if defaults.bool(forKey: Self.doneKey) {
            report.alreadyDone = true
            return report
        }
        defer { defaults.set(true, forKey: Self.doneKey) }
        let fm = FileManager.default
        let todo = folders.filter { isFolder($0.old) && !hasData($0.new) }
        let missing = { (old: [String: Any]?) in (old ?? [:]).filter { self.defaults.object(forKey: $0.key) == nil } }
        guard !todo.isEmpty || !missing(oldDefaults()).isEmpty else { return report }

        report.quitOld = quitOld()
        let settings = missing(oldDefaults())
        for (old, new) in todo {
            report.copied += copyTree(old, to: new, fm: fm)
        }
        let config = home.appending(path: ".config/kobi/config")
        if report.copied.contains(config.path) { renameKeys(in: config) }
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            defaults.set(value, forKey: key)
            report.settings.append(key)
        }
        for path in report.copied { log.notice("copied \(path, privacy: .public)") }
        if !report.settings.isEmpty {
            log.notice("copied \(report.settings.count) settings from \(Self.oldBundleID, privacy: .public)")
        }
        return report
    }

    private func isFolder(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// The new folder has something of its own: more than a lock or a socket (the app's
    /// single-instance lock is taken before the migration runs).
    private func hasData(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { !Self.skipped.contains($0) }
    }

    /// The old name in a file name becomes the new one: earshot-tts is kobi-tts.
    static func renamed(_ name: String) -> String {
        name.replacingOccurrences(of: "earshot", with: "kobi").replacingOccurrences(of: "Earshot", with: "Kobi")
    }

    /// Copies `old` into `new`, keeping each file's permissions, never over a file that is
    /// there already. Returns the new paths of the files copied.
    private func copyTree(_ old: URL, to new: URL, fm: FileManager) -> [String] {
        var copied: [String] = []
        makeFolder(new, like: old, fm: fm)
        guard let items = fm.enumerator(atPath: old.path) else { return [] }
        while let relative = items.nextObject() as? String {
            let item = old.appending(path: relative)
            let type = items.fileAttributes?[.type] as? FileAttributeType
            if Self.skipped.contains(item.lastPathComponent) {
                if type == .typeDirectory { items.skipDescendants() }
                continue
            }
            let target = relative.split(separator: "/").reduce(new) { $0.appending(path: Self.renamed(String($1))) }
            // Never over what is there. A folder that is there already is merged into.
            if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { continue }
            do {
                switch type {
                case .typeSymbolicLink?:
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: item.path))
                case .typeDirectory?:
                    makeFolder(target, like: item, fm: fm)
                case .typeRegular?:
                    // copyItem keeps the permissions (the config is 0600) and clones on APFS.
                    try fm.copyItem(at: item, to: target)
                    copied.append(target.path)
                default:
                    break   // a socket or a pipe stays behind
                }
            } catch {
                log.error("couldn't copy \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return copied
    }

    private func makeFolder(_ url: URL, like old: URL, fm: FileManager) {
        let mode = (try? fm.attributesOfItem(atPath: old.path))?[.posixPermissions] as? Int ?? 0o700
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        chmod(url.path, mode_t(mode))
    }

    /// EARSHOT_X=... becomes KOBI_X=... in the copied config. Values are left as they are
    /// and never logged: one is an API key.
    private func renameKeys(in config: URL) {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return }
        let renamed = Self.renameKeys(text)
        guard renamed != text else { return }
        let mode = (try? FileManager.default.attributesOfItem(atPath: config.path))?[.posixPermissions] as? Int ?? 0o600
        let tmp = config.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: Data(renamed.utf8), attributes: [.posixPermissions: 0o600])
        if rename(tmp.path, config.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            log.error("couldn't rename the keys in the config")
            return
        }
        chmod(config.path, mode_t(mode))
    }

    /// The config's lines with each EARSHOT_ key (after any spaces and `export`) renamed KOBI_.
    static func renameKeys(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: #"^\s*(export\s+)?EARSHOT_"#, options: .regularExpression) else { return s }
            return s.replacingCharacters(in: r, with: s[r].replacingOccurrences(of: "EARSHOT_", with: "KOBI_"))
        }.joined(separator: "\n")
    }

    /// Asks a running Earshot to quit and waits up to five seconds for it. True when one ran.
    public static func quitOldApp() -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID)
        guard !apps.isEmpty else { return false }
        let pids = apps.map(\.processIdentifier)
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        return true
    }
}
