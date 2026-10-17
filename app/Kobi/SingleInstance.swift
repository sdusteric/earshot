import Darwin
import Foundation

/// One Kobi at a time: a lock that lasts as long as the process does.
enum SingleInstance {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func claim() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Kobi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)   // only you can reach the socket inside
        fd = open(dir.appending(path: "app.lock").path, O_CREAT | O_RDWR, 0o600)
        return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
