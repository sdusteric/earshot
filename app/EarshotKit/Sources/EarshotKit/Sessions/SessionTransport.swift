import Darwin
import Foundation

public enum Priority: String, Sendable {
    /// Before anything else, after the current tool call.
    case now
    case next
}

public protocol SessionTransport: Sendable {
    /// One prompt line to the session. False when its socket is gone or the write failed.
    func send(pid: Int32, sessionID: String, text: String, priority: Priority) async -> Bool
}

/// Claude Code's messaging socket, /tmp/cc-socks/<pid>.sock (see the spike
/// notes). The session drops a line whose session_id is not its own, so a
/// reused pid never gets a command meant for another session.
public struct CCSocketTransport: SessionTransport {
    let dir: String

    public init(dir: String = "/tmp/cc-socks") { self.dir = dir }

    public static func line(sessionID: String, text: String, priority: Priority) -> Data {
        let o: [String: Any] = ["type": "user", "from": "earshot", "session_id": sessionID, "priority": priority.rawValue,
                                "message": ["role": "user", "content": text]]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    public func send(pid: Int32, sessionID: String, text: String, priority: Priority) async -> Bool {
        let path = "\(dir)/\(pid).sock"
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid(), UnixAddress.fits(path)
        else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        UnixAddress.noSigPipe(fd)
        guard UnixAddress.with(path, { connect(fd, $0, $1) }) == 0 else { return false }
        var out = Self.line(sessionID: sessionID, text: text, priority: priority)
        out.append(10)
        return out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == out.count
    }
}
