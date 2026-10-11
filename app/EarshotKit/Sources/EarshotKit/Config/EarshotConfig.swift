import Foundation

extension URL {
    /// ~/.config/earshot, shared with the plugin.
    public static var earshotDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/earshot")
    }
    public static var earshotConfig: URL { earshotDir.appending(path: "config") }
}

/// The plugin's config file: shell lines `KEY=value` that speak.sh sources.
/// setup.sh writes values with `printf %q`; this reads the forms that produces
/// (plain, backslash escapes, '...', "...", $'...') and writes '...'.
public struct EarshotConfig: Sendable, Equatable {
    public enum Engine: String, Sendable, CaseIterable { case kokoro, elevenlabs, say }

    private var lines: [String]

    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
    }

    public static func load(from url: URL = .earshotConfig) -> EarshotConfig {
        EarshotConfig(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    public func save(to url: URL = .earshotConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        chmod(url.path, 0o600)
    }

    public subscript(_ key: String) -> String? {
        for line in lines.reversed() {
            if let (k, v) = Self.parse(line), k == key { return v }
        }
        return nil
    }

    /// Sets a key in place (every earlier copy is removed), or appends it.
    /// nil removes the key.
    public mutating func set(_ key: String, _ value: String?) {
        let indices = lines.indices.filter { Self.parse(lines[$0])?.0 == key }
        let newLine = value.map { "\(key)=\(Self.quote($0))" }
        if let first = indices.first, let newLine {
            lines[first] = newLine
            for i in indices.dropFirst().reversed() { lines.remove(at: i) }
        } else {
            for i in indices.reversed() { lines.remove(at: i) }
            if let newLine { lines.append(newLine) }
        }
    }

    // MARK: Typed values, with speak.sh's defaults

    public var engine: Engine {
        if let e = self["EARSHOT_ENGINE"], !e.isEmpty { return Engine(rawValue: e) ?? .kokoro }
        return (elevenLabsKey ?? "").isEmpty ? .kokoro : .elevenlabs
    }
    public var level: String { nonEmpty("EARSHOT_LEVEL") ?? "normal" }
    public var style: String { nonEmpty("EARSHOT_STYLE") ?? "plain" }
    public var elevenLabsKey: String? { nonEmpty("EARSHOT_KEY") }
    public var elevenLabsVoice: String? { nonEmpty("EARSHOT_VOICE") }
    public var elevenLabsModel: String { nonEmpty("EARSHOT_MODEL") ?? "eleven_v4_turbo" }
    public var kokoroVoice: String { nonEmpty("EARSHOT_KOKORO_VOICE") ?? "af_heart" }
    public var sayVoice: String? { nonEmpty("EARSHOT_SAY_VOICE") }
    /// App only: lower other apps' audio while Earshot talks.
    public var duckEnabled: Bool { self["EARSHOT_DUCK"] != "off" }
    /// App only: how loud other apps stay, 10 to 90 percent.
    public var duckLevel: Float {
        guard let s = self["EARSHOT_DUCK_LEVEL"], let p = Int(s) else { return 0.3 }
        return Float(min(max(p, 10), 90)) / 100
    }

    private func nonEmpty(_ key: String) -> String? {
        guard let v = self[key], !v.isEmpty else { return nil }
        return v
    }

    // MARK: Shell quoting

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `KEY=value` with the value unquoted the way bash would, for one word.
    static func parse(_ line: String) -> (String, String)? {
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq]
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return (String(key), unquote(line[line.index(after: eq)...]))
    }

    static func unquote(_ s: Substring) -> String {
        var out = ""
        var i = s.startIndex
        func next(_ j: String.Index) -> String.Index { s.index(after: j) }
        while i < s.endIndex {
            let c = s[i]
            if c == "'" {
                i = next(i)
                while i < s.endIndex, s[i] != "'" { out.append(s[i]); i = next(i) }
            } else if c == "$", next(i) < s.endIndex, s[next(i)] == "'" {
                i = s.index(i, offsetBy: 2)
                while i < s.endIndex, s[i] != "'" {
                    if s[i] == "\\", next(i) < s.endIndex {
                        i = next(i)
                        switch s[i] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(s[i])
                        }
                    } else {
                        out.append(s[i])
                    }
                    i = next(i)
                }
            } else if c == "\"" {
                i = next(i)
                while i < s.endIndex, s[i] != "\"" {
                    if s[i] == "\\", next(i) < s.endIndex { i = next(i) }
                    out.append(s[i])
                    i = next(i)
                }
            } else if c == "\\", next(i) < s.endIndex {
                i = next(i)
                out.append(s[i])
            } else if c == " " || c == "\t" {
                break   // the end of the word; anything after is a comment or another command
            } else {
                out.append(c)
            }
            if i < s.endIndex { i = next(i) }
        }
        return out
    }
}
