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
    public enum WakeBattery: String, Sendable, CaseIterable { case always, power, lowpower }
    public enum Hotkey: String, Sendable, CaseIterable {
        case rightOption = "right_option", rightCommand = "right_command", off
    }

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
    /// Full screen apps: "quiet" (the default) keeps Earshot's own lines until
    /// you leave full screen; "speak" says them anyway.
    public var quietInFullScreen: Bool { self["EARSHOT_FULLSCREEN"] != "speak" }
    /// App only: how loud other apps stay, 10 to 90 percent.
    public var duckLevel: Float {
        guard let s = self["EARSHOT_DUCK_LEVEL"], let p = Int(s) else { return 0.3 }
        return Float(min(max(p, 10), 90)) / 100
    }
    /// App only: listen for "Hey Earshot". Off until you turn it on.
    public var wakeWord: Bool { self["EARSHOT_WAKE"] == "on" }
    /// App only: on battery, listen always, never (power), or unless Low Power Mode is on.
    public var wakeOnBattery: WakeBattery { nonEmpty("EARSHOT_WAKE_BATTERY").flatMap(WakeBattery.init) ?? .lowpower }
    /// App only: 1 (fewer false wakes) to 10 (fewer missed wakes).
    public var wakeSensitivity: Int {
        guard let s = self["EARSHOT_WAKE_SENSITIVITY"], let v = Int(s) else { return 5 }
        return min(max(v, 1), 10)
    }
    /// App only: the key you hold to talk.
    public var hotkey: Hotkey { nonEmpty("EARSHOT_HOTKEY").flatMap(Hotkey.init) ?? .rightOption }
    /// App only: the mic's Core Audio UID; nil picks one (see MicInput).
    public var inputDevice: String? { nonEmpty("EARSHOT_INPUT") }

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

    /// Works on bytes: bash's $'...' writes non-ASCII text as octal escapes of
    /// its UTF-8 bytes ("Amélie" is $'Am\303\251lie').
    static func unquote(_ s: Substring) -> String {
        let b = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        let quote = UInt8(ascii: "'"), dquote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        while i < b.count {
            let c = b[i]
            if c == quote {
                i += 1
                while i < b.count, b[i] != quote { out.append(b[i]); i += 1 }
                i += 1
            } else if c == UInt8(ascii: "$"), i + 1 < b.count, b[i + 1] == quote {
                i += 2
                while i < b.count, b[i] != quote {
                    if b[i] == backslash, i + 1 < b.count {
                        i += 1
                        i = ansiEscape(b, i, into: &out)
                    } else {
                        out.append(b[i])
                        i += 1
                    }
                }
                i += 1
            } else if c == dquote {
                i += 1
                while i < b.count, b[i] != dquote {
                    if b[i] == backslash, i + 1 < b.count { i += 1 }
                    out.append(b[i])
                    i += 1
                }
                i += 1
            } else if c == backslash, i + 1 < b.count {
                out.append(b[i + 1])
                i += 2
            } else if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") {
                break   // the end of the word; anything after is a comment or another command
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// One escape inside $'...', starting just after the backslash. Returns
    /// the index after it.
    private static func ansiEscape(_ b: [UInt8], _ start: Int, into out: inout [UInt8]) -> Int {
        var i = start
        let c = b[i]
        let simple: [UInt8: UInt8] = [
            UInt8(ascii: "n"): 10, UInt8(ascii: "t"): 9, UInt8(ascii: "r"): 13, UInt8(ascii: "a"): 7,
            UInt8(ascii: "b"): 8, UInt8(ascii: "e"): 27, UInt8(ascii: "E"): 27, UInt8(ascii: "f"): 12,
            UInt8(ascii: "v"): 11,
        ]
        if let v = simple[c] {
            out.append(v)
            return i + 1
        }
        if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(c) {
            var value = 0
            var n = 0
            while n < 3, i < b.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(b[i]) {
                value = value * 8 + Int(b[i] - UInt8(ascii: "0"))
                i += 1
                n += 1
            }
            out.append(UInt8(truncatingIfNeeded: value))
            return i
        }
        if c == UInt8(ascii: "x") {
            i += 1
            var value = 0
            var n = 0
            while n < 2, i < b.count, let d = hexDigit(b[i]) {
                value = value * 16 + d
                i += 1
                n += 1
            }
            if n > 0 { out.append(UInt8(value)) } else { out.append(UInt8(ascii: "x")) }
            return i
        }
        out.append(c)   // \\ \' \" and anything else: the character itself
        return i + 1
    }

    private static func hexDigit(_ c: UInt8) -> Int? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(c - UInt8(ascii: "A")) + 10
        default: nil
        }
    }
}
