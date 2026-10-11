import Darwin
import Foundation

/// Sends one line to a LineServer-style socket and waits for one line back.
public enum LineClient {
    public enum Failure: Error, Equatable { case pathTooLong, connect(Int32), write, timeout, closed }

    public static func send(path: String, line: Data, timeout: TimeInterval) throws(Failure) -> Data {
        guard UnixAddress.fits(path) else { throw .pathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .connect(errno) }
        defer { close(fd) }
        UnixAddress.noSigPipe(fd)
        guard UnixAddress.with(path, { connect(fd, $0, $1) }) == 0 else { throw .connect(errno) }
        var out = line
        out.append(10)
        let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == out.count else { throw .write }
        let deadline = Date().addingTimeInterval(timeout)
        var reply = Data()
        var byte: UInt8 = 0
        while true {
            let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, ms) > 0 else { throw .timeout }
            let n = read(fd, &byte, 1)
            if n <= 0 {
                if reply.isEmpty { throw .closed }
                return reply
            }
            if byte == 10 { return reply }
            reply.append(byte)
        }
    }
}
