import Foundation

/// The Mac's own voice, through /usr/bin/say. The text goes in through a file,
/// never the command line.
public struct SayEngine: SpeechEngine {
    public let voice: String?
    public init(voice: String?) { self.voice = voice }

    public var name: String { "say" }
    public var fileExtension: String { "aiff" }
    public func cacheKey(_ text: String) -> String { "say \(voice ?? "") \(text)" }

    public func render(_ text: String, to url: URL) async throws {
        let input = FileManager.default.temporaryDirectory.appending(path: "kobi-say-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        var args = ["-f", input.path, "-o", url.path]
        if let voice { args = ["-v", voice] + args }
        let status = try await Self.run("/usr/bin/say", args)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard status == 0, size > 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func run(_ tool: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
