import Foundation
import SourceDeskCore

enum ChunkingSuite {

    static var suite: TestSuite {
        TestSuite("4 · Chunking", cases: [

            test("chunks carry heading paths and page numbers") { ctx in
                let document = ExtractedDocument(
                    title: "Report",
                    method: "test",
                    pages: [
                        ExtractedPage(number: 1, blocks: [
                            ExtractedBlock(kind: .heading, text: "Introduction", level: 1, headingPath: "Introduction"),
                            ExtractedBlock(kind: .paragraph, text: String(repeating: "Inspections fell sharply across the region. ", count: 12), headingPath: "Introduction")
                        ]),
                        ExtractedPage(number: 2, blocks: [
                            ExtractedBlock(kind: .heading, text: "Causes", level: 2, headingPath: "Introduction › Causes"),
                            ExtractedBlock(kind: .paragraph, text: String(repeating: "Budget pressure delayed every permit application. ", count: 12), headingPath: "Introduction › Causes")
                        ])
                    ]
                )
                let chunks = TextChunker.chunk(document: document, sourceID: "s1", notebookID: "n1")
                try ctx.check(chunks.count >= 2, "produced \(chunks.count) chunks")
                try ctx.equal(chunks[0].ordinal, 0, "ordinals start at zero")
                try ctx.check(chunks.map(\.ordinal) == Array(0..<chunks.count), "ordinals are contiguous")

                let pageOne = try ctx.unwrap(chunks.first { $0.pageNumber == 1 })
                try ctx.contains(pageOne.text, "Introduction", "heading context is included")
                let pageTwo = try ctx.unwrap(chunks.first { $0.pageNumber == 2 })
                try ctx.contains(pageTwo.headingPath ?? "", "Causes", "heading path recorded: \(pageTwo.headingPath ?? "nil")")
            },

            test("no chunk exceeds the maximum size") { ctx in
                let paragraph = String(repeating: "The review board collected inspection logs from every regional office. ", count: 400)
                let document = ExtractedDocument(title: "Long", blocks: [
                    ExtractedBlock(kind: .paragraph, text: paragraph)
                ], method: "test")
                let configuration = TextChunker.Configuration(targetTokens: 200, maximumTokens: 300, overlapTokens: 40, minimumCharacters: 10)
                let chunks = TextChunker.chunk(document: document, sourceID: "s", notebookID: "n", configuration: configuration)
                try ctx.check(chunks.count > 3, "long text split into \(chunks.count) chunks")
                for chunk in chunks {
                    try ctx.check(chunk.tokenCount <= 300, "chunk \(chunk.ordinal) is \(chunk.tokenCount) tokens")
                }
                // Nothing is lost: every chunk's text must be found in the original.
                for chunk in chunks {
                    let body = chunk.text.replacingOccurrences(of: "\n", with: " ")
                    let probe = String(body.split(separator: " ").prefix(6).joined(separator: " "))
                    try ctx.contains(paragraph, probe, "chunk text comes from the document")
                }
            },

            test("sentences are not cut mid-clause when splitting") { ctx in
                let text = (1...120).map { "Sentence number \($0) explains the inspection backlog in region \($0 % 9)." }.joined(separator: " ")
                let chunks = TextChunker.chunk(
                    plainText: text, sourceID: "s", notebookID: "n",
                    configuration: TextChunker.Configuration(targetTokens: 120, maximumTokens: 200, overlapTokens: 0, minimumCharacters: 20)
                )
                try ctx.check(chunks.count >= 3, "split into \(chunks.count) chunks")
                for chunk in chunks {
                    let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    try ctx.check(trimmed.hasSuffix("."), "chunk ends at a sentence boundary: …\(trimmed.suffix(40))")
                }
            },

            test("overlap repeats the tail of the previous chunk") { ctx in
                let text = (1...60).map { "Point \($0) about permit backlogs and staffing shortages in the district." }.joined(separator: " ")
                let configuration = TextChunker.Configuration(targetTokens: 100, maximumTokens: 160, overlapTokens: 30, minimumCharacters: 20)
                let chunks = TextChunker.chunk(plainText: text, sourceID: "s", notebookID: "n", configuration: configuration)
                try ctx.check(chunks.count >= 2, "multiple chunks")
                // Some sentence from chunk 0 must also appear in chunk 1.
                let firstSentences = Set(SentenceSplitter.split(chunks[0].text).map { $0.text.trimmingCharacters(in: .whitespaces) })
                let secondBody = chunks[1].text
                let shared = firstSentences.filter { $0.count > 20 && secondBody.contains($0) }
                try ctx.check(!shared.isEmpty, "overlap present between chunk 0 and 1")
            },

            test("tables and code blocks stay whole") { ctx in
                let table = (1...40).map { "Region \($0) | \(-$0)% | note" }.joined(separator: "\n")
                let document = ExtractedDocument(title: "T", blocks: [
                    ExtractedBlock(kind: .table, text: table),
                    ExtractedBlock(kind: .code, text: "SELECT region, count(*) FROM inspections GROUP BY region;")
                ], method: "test")
                let chunks = TextChunker.chunk(document: document, sourceID: "s", notebookID: "n",
                                               configuration: TextChunker.Configuration(targetTokens: 64, maximumTokens: 128, overlapTokens: 0, minimumCharacters: 10))
                let tableChunk = try ctx.unwrap(chunks.first { $0.text.contains("Region 40") })
                try ctx.contains(tableChunk.text, "Region 1 |", "the whole table is in one chunk")
                try ctx.check(chunks.contains { $0.text.contains("GROUP BY") }, "code block preserved")
            },

            test("undersized tail chunks merge into their neighbour") { ctx in
                var blocks: [ExtractedBlock] = []
                for index in 0..<10 {
                    blocks.append(ExtractedBlock(kind: .paragraph, text: String(repeating: "A full paragraph of prose number \(index). ", count: 8), headingPath: "Section"))
                }
                blocks.append(ExtractedBlock(kind: .paragraph, text: "Short tail.", headingPath: "Section"))
                let chunks = TextChunker.chunk(
                    document: ExtractedDocument(title: "T", blocks: blocks, method: "test"),
                    sourceID: "s", notebookID: "n",
                    configuration: TextChunker.Configuration(targetTokens: 300, maximumTokens: 500, overlapTokens: 0, minimumTokens: 60, minimumCharacters: 10)
                )
                try ctx.check(!chunks.contains { $0.text.contains("Short tail.") && $0.tokenCount < 60 },
                              "no tiny standalone chunk survives")
            },

            test("empty and whitespace-only input produces no chunks") { ctx in
                let empty = TextChunker.chunk(plainText: "", sourceID: "s", notebookID: "n")
                try ctx.equal(empty.count, 0)
                let whitespace = TextChunker.chunk(plainText: "   \n\n\t  \n", sourceID: "s", notebookID: "n")
                try ctx.equal(whitespace.count, 0)
            },

            test("a 600-page-style document chunks quickly") { ctx in
                let paragraph = String(repeating: "The committee reviewed inspection throughput across all regions and reported its findings to the board. ", count: 25)
                let blocks = (0..<900).map { index in
                    ExtractedBlock(kind: .paragraph, text: "Section \(index). " + paragraph,
                                   headingPath: "Chapter \(index / 30)")
                }
                let document = ExtractedDocument(title: "Book", method: "test", pages: [ExtractedPage(number: 0, blocks: blocks)])
                let start = Date()
                let chunks = TextChunker.chunk(document: document, sourceID: "s", notebookID: "n")
                let elapsed = Date().timeIntervalSince(start)
                try ctx.check(chunks.count > 1_000, "produced \(chunks.count) chunks")
                // A generous ceiling: this is an unoptimised debug build, and the test
                // exists to catch pathological blow-ups (quadratic splitting, unbounded
                // re-scanning), not to benchmark. It runs in ~3s on an idle machine.
                try ctx.check(elapsed < 45, "chunked in \(String(format: "%.2f", elapsed))s")
                ctx.note("\(chunks.count) chunks from ~900 paragraphs in \(String(format: "%.2f", elapsed))s")
            },

            test("sentence splitting handles abbreviations and decimals") { ctx in
                let text = "Dr. Smith reported 3.5 percent growth in Q1. The review board disagreed. See e.g. Fig. 2 for details. It continued."
                let sentences = SentenceSplitter.split(text).map(\.text)
                try ctx.equal(sentences.count, 4, "got \(sentences.count): \(sentences)")
                try ctx.check(sentences[0].contains("3.5"), "decimal not split")
                try ctx.check(sentences[2].contains("e.g."), "abbreviation not split")
            },

            test("markdown parsing recognises structure") { ctx in
                let markdown = """
                # Title

                An introductory paragraph that is long enough to be kept as a block of prose text.

                ## Section

                - first item
                - second item

                1. numbered item

                > A quotation worth keeping.

                | Col A | Col B |
                | ----- | ----- |
                | one   | two   |

                ```swift
                let x = 1
                ```
                """
                let blocks = Markdownish.parse(markdown)
                try ctx.check(blocks.contains { $0.kind == .heading && $0.text == "Title" }, "h1 found")
                try ctx.check(blocks.contains { $0.kind == .heading && $0.level == 2 }, "h2 found")
                try ctx.check(blocks.filter { $0.kind == .listItem }.count >= 3, "list items found")
                try ctx.check(blocks.contains { $0.kind == .quote }, "quote found")
                try ctx.check(blocks.contains { $0.kind == .code && $0.text.contains("let x = 1") }, "code found")
                let table = try ctx.unwrap(blocks.first { $0.kind == .table })
                try ctx.doesNotContain(table.text, "---", "table separator rows dropped")
                let item = try ctx.unwrap(blocks.first { $0.kind == .listItem })
                try ctx.contains(item.headingPath, "Section", "list items inherit the heading path")
            },

            test("inline markdown is stripped from embedded text") { ctx in
                try ctx.equal(Markdownish.stripInlineMarkup("**bold** text"), "bold text")
                try ctx.equal(Markdownish.stripInlineMarkup("a [link](https://x.com) here"), "a link (https://x.com) here")
                try ctx.equal(Markdownish.stripInlineMarkup("`code` here"), "code here")
                try ctx.equal(Markdownish.stripInlineMarkup("~~struck~~ words"), "struck words")
            }
        ])
    }
}
