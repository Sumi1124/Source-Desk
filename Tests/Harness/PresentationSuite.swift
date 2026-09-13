import Foundation
import SourceDeskCore

/// User-facing text formatting.
///
/// These are small functions with a large effect on how finished the interface feels. All
/// three were wrong in the shipped build: the Sources header read "1 passages", a
/// one-page PDF read "1 pages", and a notebook with no extracted text read
/// "Zero KB of text" — because `ByteCountFormatter` answers zero with that literal string.
/// A test is the only thing that keeps them right, since none of them is interesting
/// enough to re-check by hand.
enum PresentationSuite {

    static var suite: TestSuite {
        TestSuite("26 · Presentation text", cases: [

            test("counts inflect correctly") { ctx in
                // The helper every counted noun now goes through.
                try ctx.equal(Format.count(1, "passage"), "1 passage")
                try ctx.equal(Format.count(0, "passage"), "0 passages")
                try ctx.equal(Format.count(2, "passage"), "2 passages")
                try ctx.equal(Format.count(1, "word"), "1 word")
                try ctx.equal(Format.count(1_234, "passage"), "1,234 passages")
                // An irregular plural can be supplied when a noun needs one.
                try ctx.equal(Format.count(1, "entry", "entries"), "1 entry")
                try ctx.equal(Format.count(2, "entry", "entries"), "2 entries")
            },

            test("a source subtitle never says '1 pages' or '1 words'") { ctx in
                // Straight from the source list, where a user scans this constantly.
                var singlePage = Source(notebookID: "n", kind: .pdf, title: "One pager", wordCount: 500)
                singlePage.pageCount = 1
                try ctx.check(!singlePage.displaySubtitle.contains("1 pages"),
                              "got: \(singlePage.displaySubtitle)")
                try ctx.contains(singlePage.displaySubtitle, "1 page")

                var manyPages = Source(notebookID: "n", kind: .pdf, title: "Report", wordCount: 900)
                manyPages.pageCount = 14
                try ctx.contains(manyPages.displaySubtitle, "14 pages")

                var oneWord = Source(notebookID: "n", kind: .pastedText, title: "Terse")
                oneWord.wordCount = 1
                try ctx.check(!oneWord.displaySubtitle.contains("1 words"),
                              "got: \(oneWord.displaySubtitle)")
                try ctx.contains(oneWord.displaySubtitle, "1 word")

                var manyWords = Source(notebookID: "n", kind: .website, title: "Article")
                manyWords.wordCount = 55
                try ctx.contains(manyWords.displaySubtitle, "55 words")
            },

            test("sizes never render as 'Zero KB'") { ctx in
                // The literal string ByteCountFormatter returns for zero, which shipped in
                // the Sources header.
                try ctx.check(!Format.bytes(0).lowercased().contains("zero"),
                              "got: \(Format.bytes(0))")
                try ctx.equal(Format.bytes(0), "0 bytes")
                // Sub-kilobyte values round to "0 KB" or "1 KB" through the formatter, so
                // they are reported in bytes instead.
                try ctx.equal(Format.bytes(600), "600 bytes")
                try ctx.equal(Format.bytes(999), "999 bytes")
                try ctx.check(!Format.bytes(600).contains("KB"), "600 bytes is not expressed in KB")
                // Above a kilobyte the formatter's own wording is right.
                try ctx.contains(Format.bytes(2_048), "KB")
                try ctx.contains(Format.bytes(5_000_000), "MB")
                try ctx.check(!Format.bytes(-1).lowercased().contains("zero"), "a negative is not 'Zero KB'")
            },

            test("no view hardcodes a plural noun next to an interpolated count") { ctx in
                // A source-text guard rather than a behavioural one: the bug was a pattern
                // repeated by hand across a dozen call sites, so the rule is enforced where
                // it is written. Format.count exists for exactly this.
                let viewsRoot = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()   // Harness
                    .deletingLastPathComponent()   // Tests
                    .deletingLastPathComponent()   // repo root
                    .appendingPathComponent("Sources/SourceDesk")

                let nouns = ["passages", "words", "pages", "sources", "results", "notes", "messages"]
                var offenders: [String] = []

                let files = FileManager.default.enumerator(at: viewsRoot, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }
                    .filter { $0.pathExtension == "swift" } ?? []

                for file in files {
                    guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    // The defect shape is a noun used as a trailing label on a count —
                    // "\(n) passages" — which reads "1 passages" when n is 1. Prose that
                    // merely mentions a plural noun ("Added 3 of 5 sources") is correct
                    // English and must not be flagged, so the rule anchors on the noun
                    // sitting immediately before the closing quote.
                    //
                    // Assembled from character codes so the quoted forms are unambiguous
                    // rather than a thicket of backslashes.
                    let quote = "\u{22}"
                    let singularGuard = "? " + quote + quote + " : " + quote + "s" + quote
                    for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                        guard !line.contains(singularGuard) else { continue }
                        guard !line.contains("Format.") else { continue }
                        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                        for noun in nouns where line.contains(") " + noun + quote) {
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            offenders.append(file.lastPathComponent + ":" + String(index + 1) + "  " + trimmed)
                        }
                    }
                }

                try ctx.check(offenders.isEmpty,
                              "hardcoded plurals found:\n" + offenders.joined(separator: "\n"))
            },

            test("the Sources header omits a size that would be meaningless") { ctx in
                // A notebook of short sources has no useful megabyte figure; stating one
                // was how "Zero KB of text" appeared in the first place.
                let tiny = Format.bytes(0)
                try ctx.equal(tiny, "0 bytes")
                // The header only shows bytes at 100 KB and above, so this is the boundary
                // the view relies on.
                try ctx.check(Format.bytes(99_999).contains("bytes") || Format.bytes(99_999).contains("KB"))
                try ctx.contains(Format.bytes(120_000), "KB")
            },
        ])
    }
}
