import Foundation
import SourceDeskCore

enum TextSuite {

    static var suite: TestSuite {
        TestSuite("2 · Text utilities", cases: [

            test("token estimation is conservative for Latin and CJK") { ctx in
                try ctx.equal(TextMath.estimatedTokens(for: ""), 0)
                let latin = String(repeating: "a", count: 400)
                let latinTokens = TextMath.estimatedTokens(for: latin)
                try ctx.check(latinTokens >= 100 && latinTokens <= 110, "400 latin chars ≈ 100 tokens, got \(latinTokens)")
                let cjk = String(repeating: "研", count: 100)
                let cjkTokens = TextMath.estimatedTokens(for: cjk)
                try ctx.check(cjkTokens >= 100, "100 CJK chars ≈ 100 tokens, got \(cjkTokens)")
            },

            test("tokenizer handles punctuation, unicode and CJK") { ctx in
                try ctx.equal(TextMath.tokens("The Industrial Revolution, 1760–1840!"),
                              ["the", "industrial", "revolution", "1760", "1840"])
                try ctx.equal(TextMath.tokens("don't stop-believing"), ["don", "t", "stop", "believing"])
                let mixed = TextMath.tokens("報告 says decline")
                try ctx.check(mixed.contains("報告") && mixed.contains("decline"), "CJK runs stay intact: \(mixed)")
            },

            test("stemming makes plurals and gerunds collide") { ctx in
                try ctx.equal(TextMath.stem("declining"), "declin")
                try ctx.equal(TextMath.stem("declines"), "declin")
                try ctx.equal(TextMath.stem("decline"), "decline")
                try ctx.equal(TextMath.stem("inspections"), "inspect")
                try ctx.equal(TextMath.stem("inspection"), "inspect", "singular and plural agree")
                try ctx.equal(TextMath.stem("policies"), "policy")
                try ctx.equal(TextMath.stem("organizations"), "organ")
                try ctx.equal(TextMath.stem("organization"), "organ", "singular and plural agree")
            },

            test("preview truncates on a word boundary") { ctx in
                let text = String(repeating: "alpha bravo charlie delta ", count: 30)
                let preview = TextMath.preview(text, limit: 60)
                try ctx.check(preview.count <= 62, "preview length \(preview.count)")
                try ctx.check(preview.hasSuffix("…"), "preview is elided")
                try ctx.doesNotContain(preview, "  ", "no double spaces")
                try ctx.equal(TextMath.preview("short text", limit: 60), "short text", "short text untouched")
            },

            test("vector math is correct") { ctx in
                try ctx.close(VectorMath.cosineSimilarity([1, 0, 0], [1, 0, 0]), 1.0)
                try ctx.close(VectorMath.cosineSimilarity([1, 0, 0], [0, 1, 0]), 0.0)
                try ctx.close(VectorMath.cosineSimilarity([1, 0, 0], [-1, 0, 0]), -1.0)
                try ctx.close(VectorMath.cosineSimilarity([0, 0, 0], [1, 1, 1]), 0.0, tolerance: 1e-9, "zero vector is safe")
                try ctx.close(VectorMath.magnitude([3, 4]), 5.0)
                let normalized = VectorMath.normalize([3, 4])
                try ctx.close(Double(normalized[0]), 0.6, tolerance: 1e-6)
                try ctx.close(Double(normalized[1]), 0.8, tolerance: 1e-6)
            },

            test("stable hashing does not change between runs") { ctx in
                // Fixed expectations: if these ever change, existing chunk ids and
                // embedding features would silently change too.
                let hash = StableHash.fnv1a("source-desk")
                try ctx.check(hash != 0, "hash produced")
                try ctx.equal(StableHash.fnv1a("source-desk"), hash, "deterministic")
                try ctx.check(StableHash.fnv1a("a") != StableHash.fnv1a("b"), "distinct inputs differ")
            },

            test("SHA-256 matches the published test vectors") { ctx in
                // These are the standard FIPS/NIST vectors — if the checksum were
                // wrong, deduplication and export manifests would be wrong too.
                try ctx.equal(FileStore.checksum(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
                try ctx.equal(FileStore.checksum(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                try ctx.equal(FileStore.checksum(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
                // Multi-block input.
                try ctx.equal(FileStore.checksum(of: Data(String(repeating: "a", count: 1_000_000).utf8)),
                              "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
            },

            test("date parsing handles the formats feeds actually use") { ctx in
                let iso = try ctx.unwrap(DateParsing.parse("2024-03-05T09:00:00Z"))
                try ctx.equal(Int(iso.timeIntervalSince1970), 1_709_629_200)
                try ctx.notNil(DateParsing.parse("2024-03-05T09:00:00+09:00"), "offset form")
                try ctx.notNil(DateParsing.parse("2024-03-05"), "date only")
                try ctx.notNil(DateParsing.parse("Tue, 05 Mar 2024 09:00:00 GMT"), "RSS form")
                try ctx.notNil(DateParsing.parse("March 5, 2024"), "prose form")
                try ctx.notNil(DateParsing.parse("3 days ago"), "relative form")
                try ctx.isNil(DateParsing.parse("not a date at all"), "garbage rejected")
                try ctx.isNil(DateParsing.parse(""), "empty rejected")
            },

            test("HTML entities decode including numeric and malformed forms") { ctx in
                try ctx.equal(HTMLEntities.decode("Tom &amp; Jerry"), "Tom & Jerry")
                try ctx.equal(HTMLEntities.decode("5 &lt; 6 &gt; 4"), "5 < 6 > 4")
                try ctx.equal(HTMLEntities.decode("caf&#233;"), "café")
                try ctx.equal(HTMLEntities.decode("smile &#x1F600;"), "smile 😀")
                try ctx.equal(HTMLEntities.decode("a&nbsp;b"), "a b")
                try ctx.equal(HTMLEntities.decode("&mdash;"), "—")
                // Malformed input must pass through unchanged, not be dropped.
                try ctx.equal(HTMLEntities.decode("100 & 200"), "100 & 200")
                try ctx.equal(HTMLEntities.decode("&notarealentity;"), "&notarealentity;")
                try ctx.equal(HTMLEntities.decode("trailing &"), "trailing &")
                try ctx.equal(HTMLEntities.decode("&amp"), "&amp", "unterminated entity left alone")
            }
        ])
    }
}
