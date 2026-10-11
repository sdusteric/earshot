import Darwin

/// sockaddr_un for a path. sun_path holds 104 bytes on macOS, the last one the
/// terminating zero.
enum UnixAddress {
    static func fits(_ path: String) -> Bool { path.utf8.count < 104 }

    static func with<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// False when the option could not be set (on macOS, an accepted socket whose client has already hung up).
    @discardableResult
    static func noSigPipe(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func hasNoSigPipe(_ fd: Int32) -> Bool {
        var on: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &len) == 0 && on != 0
    }
}
