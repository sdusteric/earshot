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
}
