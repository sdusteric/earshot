import Darwin
import Foundation

/// A Unix socket that answers one line with one line. Lines are newline
/// terminated. Each client may send several lines; the handler runs on one
/// serial queue, so lines are handled in the order they arrive.
public final class LineServer: @unchecked Sendable {
    public enum Failure: Error { case pathTooLong, socket(Int32), bind(Int32) }

    private let path: String
    private let handler: @Sendable (Data) -> Data
    private let queue = DispatchQueue(label: "com.earshot.app.lineserver")
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]
    private static let maxLine = 1 << 16

    public init(path: String, handler: @escaping @Sendable (Data) -> Data) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        guard UnixAddress.fits(path) else { throw Failure.pathTooLong }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)   // left by an app that crashed; one instance runs at a time
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        let bound = UnixAddress.with(path) { bind(fd, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            throw Failure.bind(e)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        listenSource = source
        source.resume()
    }

    public func stop() {
        queue.sync {
            for fd in Array(clients.keys) { drop(fd) }
            listenSource?.cancel()
            listenSource = nil
        }
        unlink(path)
    }

    private func acceptAll(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            UnixAddress.noSigPipe(fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readClient(fd) }
            source.setCancelHandler { close(fd) }
            clients[fd] = source
            buffers[fd] = Data()
            source.resume()
        }
    }

    private func readClient(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EAGAIN { return }
        guard n > 0 else { drop(fd); return }
        buffers[fd, default: Data()].append(contentsOf: chunk[0..<n])
        while let buffer = buffers[fd], let nl = buffer.firstIndex(of: 10) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffers[fd] = Data(buffer[buffer.index(after: nl)...])
            var reply = handler(line)
            reply.append(10)
            // Replies are a few bytes, well under the socket buffer.
            _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        if (buffers[fd]?.count ?? 0) > Self.maxLine { drop(fd) }
    }

    private func drop(_ fd: Int32) {
        clients.removeValue(forKey: fd)?.cancel()
        buffers[fd] = nil
    }
}
