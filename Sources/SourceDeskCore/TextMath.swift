import Foundation

// MARK: - Small text/vector helpers used across the core

public enum TextMath {

    /// Rough token estimate. Swift has no tokenizer for arbitrary models, and
    /// every provider counts differently, so SourceDesk uses a conservative
    /// character-based estimate (`chars / 4` for Latin script, weighted for CJK)
    /// and always leaves headroom in the context budget rather than pretending to
    /// be exact.
    public static func estimatedTokens(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        // CJK scripts run roughly one token per character; Latin ~4 chars/token.
        return cjk + Int(ceil(Double(other) / 4.0)) + 1
    }

    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // kana
             0x3400...0x4DBF,   // CJK ext A
             0x4E00...0x9FFF,   // CJK unified
             0xF900...0xFAFF,   // compatibility ideographs
             0xAC00...0xD7AF,   // hangul
             0x1100...0x11FF:   // hangul jamo
            return true
        default:
            return false
        }
    }

    /// Compact preview used in citation lists and retrieval traces.
    public static func preview(_ text: String, limit: Int = 220) -> String {
        let flattened = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        let cut = flattened.index(flattened.startIndex, offsetBy: limit)
        let head = String(flattened[..<cut])
        if let lastSpace = head.lastIndex(of: " ") {
            return String(head[..<lastSpace]) + "…"
        }
        return head + "…"
    }

    public static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Lowercased, punctuation-stripped token list. Used by keyword scoring,
    /// lexical reranking and the built-in embedder so all three agree on what a
    /// term is.
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(text.count / 5 + 1)
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || isCJKCharacter(ch) {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    public static func isCJKCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return isCJK(scalar)
    }

    /// Very small English-centric stop list. Not used to remove terms from the
    /// index — only to keep keyword ranking from being dominated by "the".
    public static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has",
        "have", "he", "her", "his", "i", "if", "in", "into", "is", "it", "its", "of",
        "on", "or", "she", "so", "such", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "to", "was", "we", "were", "what",
        "when", "which", "who", "will", "with", "would", "you", "your", "not", "no",
        "do", "does", "did", "been", "being", "can", "could", "should", "may",
        "might", "must", "about", "over", "under", "more", "most", "other", "also"
    ]

    /// Crude stemmer: enough to make "decline"/"declines"/"declining" collide in
    /// keyword scoring without pulling in a full Porter implementation.
    ///
    /// Suffixes are stripped repeatedly (up to three passes) so plural and
    /// derivative forms converge: "inspections" → "inspection" → "inspect" matches
    /// "inspection" → "inspect".
    public static func stem(_ token: String) -> String {
        var t = token
        var passes = 0
        while passes < 3 {
            let before = t
            // Plurals that change the stem's final letter are handled first.
            if t.hasSuffix("ies"), t.count >= 5 {
                t = String(t.dropLast(3)) + "y"
            } else if t.hasSuffix("sses") {
                t = String(t.dropLast(2))
            } else {
                for suffix in ["izations", "isations", "ations", "ization", "isation", "ationally", "ation",
                               "ings", "ing", "edly", "ed", "es", "s", "ion"] {
                    if t.hasSuffix(suffix), t.count - suffix.count >= 4 {
                        t = String(t.dropLast(suffix.count))
                        break
                    }
                }
            }
            if t == before { break }
            passes += 1
        }
        return t
    }
}

// MARK: - Vector math

public enum VectorMath {

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        var i = 0
        while i < n {
            sum += a[i] * b[i]
            i += 1
        }
        return sum
    }

    public static func magnitude(_ v: [Float]) -> Float {
        var sum: Float = 0
        for x in v { sum += x * x }
        return sqrt(sum)
    }

    public static func normalize(_ v: [Float]) -> [Float] {
        let m = magnitude(v)
        guard m > 0 else { return v }
        return v.map { $0 / m }
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let ma = magnitude(a)
        let mb = magnitude(b)
        guard ma > 0, mb > 0 else { return 0 }
        return Double(dot(a, b) / (ma * mb))
    }
}

// MARK: - Hashing

public enum StableHash {
    /// FNV-1a: stable across runs and platforms, unlike Swift's `hashValue`.
    /// Needed because chunk IDs and embedding features must not change between
    /// launches of the app.
    public static func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    public static func fnv1a(_ string: String) -> UInt64 {
        fnv1a(string.utf8)
    }

    public static func hex(_ string: String) -> String {
        String(fnv1a(string), radix: 16)
    }
}
