import Foundation

/// How alike two words sound, for words a quiet or gated mic garbled
/// ("seconds" for "sessions", "your shot" for "earshot").
public enum SoundsLike {
    /// A rough sound key, in the spirit of Metaphone: consonant sounds in
    /// order, vowels dropped after the first letter, a word that starts with
    /// a vowel sound starting with "A", and repeats collapsed.
    /// "sessions" is SXNS, "sections" SKXNS, "earshot" ARXT, "your shot" ARXT.
    public static func key(_ word: String) -> String {
        let w = Array(spelledOut(word.lowercased()).filter { $0.isLetter && $0.isASCII })
        guard !w.isEmpty else { return "" }
        var out: [Character] = []
        func at(_ i: Int) -> Character? { i >= 0 && i < w.count ? w[i] : nil }
        func vowel(_ c: Character?) -> Bool { c.map { "aeiou".contains($0) } ?? false }
        var i = 0
        if vowel(w[0]) || (["y", "w"].contains(w[0]) && vowel(at(1))) || (w[0] == "h" && vowel(at(1))) {
            out.append("A")
            i = w[0] == "h" || w[0] == "y" || w[0] == "w" ? 1 : 0
            while vowel(at(i)) { i += 1 }
        } else if w.starts(with: Array("kn")) || w.starts(with: Array("wr")) || w.starts(with: Array("gn")) {
            i = 1
        }
        while i < w.count {
            let c = w[i], n = at(i + 1), n2 = at(i + 2)
            var sound: String
            var skip = 1
            switch c {
            case "a", "e", "i", "o", "u", "y", "w", "h": sound = ""
            case "b": sound = "P"
            case "c":
                if n == "h" { sound = "X"; skip = 2 } else if n == "k" { sound = "K"; skip = 2 }
                else if ["e", "i", "y"].contains(n) { sound = "S" } else { sound = "K" }
            case "d": sound = n == "g" && ["e", "i", "y"].contains(n2) ? "J" : "T"; if sound == "J" { skip = 2 }
            case "g":
                if n == "h" { sound = ""; skip = 2 } else { sound = "K" }
            case "j": sound = "J"
            case "p": if n == "h" { sound = "F"; skip = 2 } else { sound = "P" }
            case "q": sound = "K"
            case "s":
                if n == "h" { sound = "X"; skip = 2 }
                else if n == "i", n2 == "o" || n2 == "a" { sound = "X"; skip = 2 }
                else { sound = "S" }
            case "t":
                if n == "h" { sound = "0"; skip = 2 }
                else if n == "i", n2 == "o" || n2 == "a" { sound = "X"; skip = 2 }
                else if n == "c", n2 == "h" { sound = "X"; skip = 3 }
                else { sound = "T" }
            case "v": sound = "F"
            case "x": sound = "KS"
            case "z": sound = "S"
            default: sound = String(c).uppercased()
            }
            for s in sound where out.last != s { out.append(s) }
            i += skip
        }
        return String(out)
    }

    /// Digits as words, so "2nd" and "second" compare.
    static func spelledOut(_ w: String) -> String {
        let ordinals = ["1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth", "5th": "fifth"]
        if let o = ordinals[w] { return o }
        let digits = ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six",
                      "7": "seven", "8": "eight", "9": "nine"]
        return digits[w] ?? w
    }

    /// 0 to 1: how alike two words are, by sound and by spelling, the two
    /// averaged: sound keys alone are short, so "blog" and "billing" would pass.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let la = letters(a), lb = letters(b)
        return similarity(la, key(la), lb, key(lb))
    }

    /// The same, for letters and sound keys already worked out.
    static func similarity(_ la: String, _ ka: String, _ lb: String, _ kb: String) -> Double {
        guard !la.isEmpty, !lb.isEmpty else { return 0 }
        if la == lb { return 1 }
        let bySound = ka.isEmpty || kb.isEmpty ? 0 : ratio(Array(ka), Array(kb))
        return (bySound + ratio(Array(la), Array(lb))) / 2
    }

    /// The word as compared: lowercase letters and digits, an apostrophe's "s" kept ("what's" is "whats").
    static func letters(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The heard words may be the end of the name: a gate that opened late cut
    /// its start ("shot" for "earshot", "service" for "billing service").
    public static func endsName(_ heard: String, _ name: String) -> Bool {
        let h = letters(heard), n = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard h.count >= 4, h.count < n.count else { return false }
        return n.hasSuffix(h)
    }

    static func ratio(_ a: [Character], _ b: [Character]) -> Double {
        max(0, 1 - Double(NameMatch.levenshtein(a, b)) / Double(max(a.count, b.count)))
    }
}
