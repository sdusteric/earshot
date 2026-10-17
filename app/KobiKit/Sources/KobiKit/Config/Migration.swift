import AppKit
import Foundation
import os

/// Kobi was called Earshot. On the first launch after the rename, what Earshot kept on
/// this Mac is copied to Kobi's places: ~/.config/earshot to ~/.config/kobi (the
/// plugin's config, with the keys renamed EARSHOT_X to KOBI_X), ~/Library/Application
/// Support/Earshot to .../Kobi (history, session names), and the settings in the
/// com.earshot.app defaults that com.kobi.app doesn't have yet. The old files stay where
/// they are. It runs before anything reads the config or the history, and again at each
/// launch until a run finishes cleanly: copying never overwrites, so a retry only adds
/// what is missing.
public struct Migration {
    public static let oldBundleID = "com.earshot.app"
    /// Set once a run finished with nothing left to copy, so it never runs again.
    public static let doneKey = "migratedFromEarshot"
    /// The new folders a run began copying into. A later run goes on copying into them, though
    /// they have files now; a folder Kobi had files in before is left alone.
    public static let begunKey = "migrationBegun"

    /// Never copied: sockets and locks belong to the process that made them, and the
    /// Kokoro build folder is a cache of about a gigabyte that build-tts.sh makes again.
    static let skipped: Set<String> = ["earshot.sock", "kobi.sock", "app.lock", ".DS_Store", "kokoro-build", "kokoro-build.log"]
    /// Settings never copied: the welcome steps run again, because they ask for the
    /// permissions (microphone, Input Monitoring, notifications), and macOS grants those
    /// to a bundle id, so Kobi has none of Earshot's.
    static let skippedSettings: Set<String> = ["onboarded", "onboardingVersion"]

    /// Whether Earshot was running when Kobi asked it to quit.
    public enum OldApp: Sendable, Equatable {
        case notRunning
        /// It ran, and quit.
        case quit
        /// It ran, and was still running after the wait.
        case stillRunning
    }

    /// What the migration did, for the log and the tests.
    public struct Report: Sendable, Equatable {
        /// Files copied, by their new paths.
        public var copied: [String] = []
        /// Settings copied from the old defaults, by key.
        public var settings: [String] = []
        /// New folders left alone because Kobi had files of its own there.
        public var skipped: [String] = []
        /// Old paths that couldn't be copied (or the config whose keys couldn't be renamed).
        public var failed: [String] = []
        /// The old app was asked to quit.
        public var quitOld = false
        /// It ran before (the marker was set), so it did nothing.
        public var alreadyDone = false
    }

    let home: URL
    let defaults: UserDefaults
    let oldDefaults: () -> [String: Any]?
    private static let log = Logger(subsystem: "com.kobi.app", category: "migration")
    private var log: Logger { Self.log }

    /// `oldDefaults` reads Earshot's settings: UserDefaults.standard.persistentDomain(forName:
    /// Migration.oldBundleID) in the app (it is not sandboxed, so it can read them). It is read
    /// again after Earshot quit, so what it saved on the way out is copied too.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard,
                oldDefaults: @escaping () -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: Migration.oldBundleID) }) {
        self.home = home
        self.defaults = defaults
        self.oldDefaults = oldDefaults
    }

    var oldSupport: URL { home.appending(path: "Library/Application Support/Earshot") }

    /// The folders to copy, old to new.
    var folders: [(old: URL, new: URL)] {
        [(home.appending(path: ".config/earshot"), home.appending(path: ".config/kobi")),
         (oldSupport, home.appending(path: "Library/Application Support/Kobi"))]
    }

    /// Copies what there is to copy, until a run finishes cleanly. `quitOld` asks a running
    /// Earshot to quit and waits for it (each app has its own single-instance lock, so both
    /// would run); it is called only when there is something to copy. Earshot still running
    /// after the wait may be writing its history, so that folder waits for the next launch.
    @discardableResult
    public func run(quitOld: () -> OldApp = Migration.quitOldApp) -> Report {
        var report = Report()
        if defaults.bool(forKey: Self.doneKey) {
            report.alreadyDone = true
            return report
        }
        let fm = FileManager.default
        var begun = defaults.stringArray(forKey: Self.begunKey) ?? []
        let present = folders.filter { isFolder($0.old) }
        let todo = present.filter { begun.contains($0.new.path) || !hasData($0.new) }
        for (_, new) in present where !todo.contains(where: { $0.new == new }) {
            report.skipped.append(new.path)
            log.notice("left \(new.path, privacy: .public) alone: Kobi has files there already")
        }
        let missing = { (old: [String: Any]?) in (old ?? [:]).filter { !Self.skippedSettings.contains($0.key) && self.defaults.object(forKey: $0.key) == nil } }
        guard !todo.isEmpty || !missing(oldDefaults()).isEmpty else {
            finish(report)
            return report
        }

        let old = quitOld()
        report.quitOld = old != .notRunning
        let settings = missing(oldDefaults())
        var waiting = false
        for (oldFolder, new) in todo {
            if old == .stillRunning, oldFolder == oldSupport {
                waiting = true
                log.notice("Earshot is still running: its history is copied at the next launch")
                continue
            }
            if !begun.contains(new.path) {
                begun.append(new.path)
                defaults.set(begun, forKey: Self.begunKey)
            }
            let r = copyTree(oldFolder, to: new, fm: fm)
            report.copied += r.copied
            report.failed += r.failed
        }
        // The keys are renamed whenever the config folder is copied into: the copy may have
        // been made by a run that ended before it got to them.
        let config = home.appending(path: ".config/kobi/config")
        if todo.contains(where: { $0.new.path == config.deletingLastPathComponent().path }),
           fm.fileExists(atPath: config.path), !renameKeys(in: config) {
            report.failed.append(config.path)
        }
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            defaults.set(value, forKey: key)
            report.settings.append(key)
        }
        for path in report.copied { log.notice("copied \(path, privacy: .public)") }
        if !report.settings.isEmpty {
            log.notice("copied \(report.settings.count) settings from \(Self.oldBundleID, privacy: .public)")
        }
        if waiting || !report.failed.isEmpty {
            log.notice("the copy from Earshot isn't finished; it goes on at the next launch")
        } else {
            finish(report)
        }
        return report
    }

    /// A clean run: the marker is set, so it never runs again.
    private func finish(_ report: Report) {
        defaults.set(true, forKey: Self.doneKey)
        defaults.removeObject(forKey: Self.begunKey)
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

    /// A path inside the copied folder, each part renamed.
    static func renamedPath(_ relative: String) -> String {
        relative.split(separator: "/", omittingEmptySubsequences: false).map { renamed(String($0)) }.joined(separator: "/")
    }

    /// Copies `old` into `new`, keeping each file's permissions, never over a file that is
    /// there already. A link is followed when it points out of the folder (a config kept with
    /// the dotfiles): the file it points to is copied as a file, a folder as a folder. A link
    /// inside the folder stays a link, to the renamed name. Returns the new paths of the files
    /// copied, and the old paths that couldn't be.
    private func copyTree(_ old: URL, to new: URL, fm: FileManager, depth: Int = 0) -> (copied: [String], failed: [String]) {
        var copied: [String] = [], failed: [String] = []
        let root = old.resolvingSymlinksInPath()
        makeFolder(new, like: old, fm: fm)
        guard let items = fm.enumerator(atPath: root.path) else { return ([], [old.path]) }
        while let relative = items.nextObject() as? String {
            let item = root.appending(path: relative)
            let type = items.fileAttributes?[.type] as? FileAttributeType
            if Self.skipped.contains(item.lastPathComponent) {
                if type == .typeDirectory { items.skipDescendants() }
                continue
            }
            let target = new.appending(path: Self.renamedPath(relative))
            // Never over what is there. A folder that is there already is merged into.
            if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                if type == .typeSymbolicLink, isFolder(target), depth < 4 {
                    // A linked folder copied into before (a run cut short): go on merging into it.
                    let r = copyTree(item, to: target, fm: fm, depth: depth + 1)
                    copied += r.copied; failed += r.failed
                }
                continue
            }
            do {
                switch type {
                case .typeSymbolicLink?:
                    let destination = try fm.destinationOfSymbolicLink(atPath: item.path)
                    let resolved = URL(fileURLWithPath: destination, relativeTo: item.deletingLastPathComponent())
                        .standardizedFileURL.resolvingSymlinksInPath()
                    var isDir: ObjCBool = false
                    if resolved.path.hasPrefix(root.path + "/") {
                        // Inside the folder: a link again, to the renamed name.
                        let renamed = destination.hasPrefix("/")
                            ? new.appending(path: Self.renamedPath(String(resolved.path.dropFirst(root.path.count + 1)))).path
                            : Self.renamedPath(destination)
                        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: renamed)
                    } else if !fm.fileExists(atPath: resolved.path, isDirectory: &isDir) {
                        // Points at nothing: kept as it is.
                        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
                    } else if isDir.boolValue {
                        guard depth < 4 else { continue }
                        let r = copyTree(item, to: target, fm: fm, depth: depth + 1)
                        copied += r.copied; failed += r.failed
                    } else {
                        try fm.copyItem(at: resolved, to: target)
                        copied.append(target.path)
                    }
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
                failed.append(item.path)
                log.error("couldn't copy \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (copied, failed)
    }

    /// The new folder gets the old one's permissions; 0700 when the old one is a link, whose
    /// own mode says nothing about the folder.
    private func makeFolder(_ url: URL, like old: URL, fm: FileManager) {
        let link = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
        let mode = link ? 0o700 : (try? fm.attributesOfItem(atPath: old.path))?[.posixPermissions] as? Int ?? 0o700
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        chmod(url.path, mode_t(mode))
    }

    /// EARSHOT_X=... becomes KOBI_X=... in the copied config. Values are left as they are
    /// and never logged: one is an API key. False when the file couldn't be rewritten.
    private func renameKeys(in config: URL) -> Bool {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else {
            log.error("couldn't read the config to rename its keys")
            return false
        }
        let renamed = Self.renameKeys(text)
        guard renamed != text else { return true }
        let mode = (try? FileManager.default.attributesOfItem(atPath: config.path))?[.posixPermissions] as? Int ?? 0o600
        let tmp = config.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: Data(renamed.utf8), attributes: [.posixPermissions: 0o600])
        if rename(tmp.path, config.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            log.error("couldn't rename the keys in the config")
            return false
        }
        chmod(config.path, mode_t(mode))
        return true
    }
    /// The config's lines with each EARSHOT_ key (after any spaces and `export`) renamed KOBI_.
    static func renameKeys(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: #"^\s*(export\s+)?EARSHOT_"#, options: .regularExpression) else { return s }
            return s.replacingCharacters(in: r, with: s[r].replacingOccurrences(of: "EARSHOT_", with: "KOBI_"))
        }.joined(separator: "\n")
    }

    /// Asks a running Earshot to quit and waits up to five seconds for it. Kobi calls it at
    /// every launch, since Earshot may start again (its login item, or out of habit), and the
    /// two would both hold the hotkey and both hear "Hey Kobi".
    public static func quitOldApp() -> OldApp {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID)
        guard !apps.isEmpty else { return .notRunning }
        log.notice("Earshot is running; asking it to quit")
        let pids = apps.map(\.processIdentifier)
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        if pids.contains(where: { kill($0, 0) == 0 }) {
            log.error("Earshot is still running after 5 s")
            return .stillRunning
        }
        return .quit
    }

    /// Asks Earshot to quit whenever it starts while Kobi runs. Keep the token as long as Kobi runs.
    public static func quitOldAppWhenItStarts() -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == oldBundleID else { return }
            log.notice("Earshot started; asking it to quit")
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !app.isTerminated { log.error("Earshot is still running 5 s after it was asked to quit") }
            }
        }
    }
}
