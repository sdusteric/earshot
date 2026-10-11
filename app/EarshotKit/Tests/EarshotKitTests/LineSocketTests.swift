import Darwin
import Foundation
import Testing
@testable import EarshotKit

@Suite(.serialized) struct LineSocketTests {
    func tempPath() -> String { "/tmp/ek-\(UUID().uuidString.prefix(8)).sock" }

    @Test func answersEachLine() throws {
        let path = tempPath()
        let server = LineServer(path: path) { Data("echo:".utf8) + $0 }
        try server.start(); defer { server.stop() }
        let reply = try LineClient.send(path: path, line: Data("hi".utf8), timeout: 1)
        #expect(String(decoding: reply, as: UTF8.self) == "echo:hi")
    }

    @Test func socketIsPrivate() throws {
        let path = tempPath()
        let server = LineServer(path: path) { $0 }
        try server.start(); defer { server.stop() }
        var st = stat()
        #expect(stat(path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
    }

    @Test func manyClientsInARow() throws {
        let path = tempPath()
        let server = LineServer(path: path) { $0 }
        try server.start(); defer { server.stop() }
        for i in 0..<50 {
            let r = try LineClient.send(path: path, line: Data("n\(i)".utf8), timeout: 1)
            #expect(String(decoding: r, as: UTF8.self) == "n\(i)")
        }
    }

    @Test func missingSocketFailsFast() {
        #expect(throws: LineClient.Failure.self) {
            try LineClient.send(path: "/tmp/ek-missing.sock", line: Data("x".utf8), timeout: 1)
        }
    }

    @Test func silentServerTimesOut() throws {
        let path = tempPath()
        let server = LineServer(path: path) { _ in Thread.sleep(forTimeInterval: 1); return Data() }
        try server.start(); defer { server.stop() }
        let start = Date()
        #expect(throws: LineClient.Failure.timeout) {
            try LineClient.send(path: path, line: Data("x".utf8), timeout: 0.2)
        }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func stopRemovesTheSocket() throws {
        let path = tempPath()
        let server = LineServer(path: path) { $0 }
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    /// A client that writes a line and hangs up before the server accepts it must not
    /// kill the process (the reply write would raise SIGPIPE on macOS).
    @Test func aClientThatHangsUpFirstDoesNotKillTheProcess() throws {
        let path = tempPath()
        let server = LineServer(path: path) { $0 }
        try server.start(); defer { server.stop() }
        var hungUp = 0, attempts = 0
        while hungUp < 200 && attempts < 5000 {
            attempts += 1
            if Self.hangUp(path, line: "hi \(hungUp)") { hungUp += 1 } else { usleep(500) }
        }
        #expect(hungUp == 200)
        let reply = try LineClient.send(path: path, line: Data("last".utf8), timeout: 5)
        #expect(String(decoding: reply, as: UTF8.self) == "last")
    }

    /// Connects, writes one line and closes at once, without reading the reply.
    static func hangUp(_ path: String, line: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        UnixAddress.noSigPipe(fd)
        guard UnixAddress.with(path, { connect(fd, $0, $1) }) == 0 else { return false }
        let out = Array((line + "\n").utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return true
    }
}
