import Foundation
import SourceDeskCore

enum ExtractionSuite {

    static var suite: TestSuite {
        TestSuite("3 · HTML extraction", cases: [

            test("keeps the article and drops navigation, adverts and footers") { ctx in
                let html = Fixtures.htmlPage(
                    title: "Why throughput declined",
                    body: "Throughput fell by nineteen percent across all seven regions after the inspection schedule was reorganised in March."
                )
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/news/decline")
                let text = document.plainText

                try ctx.contains(text, "Throughput fell by nineteen percent")
                try ctx.contains(text, "Method", "headings are kept")
                try ctx.contains(text, "inspection logs", "body prose is kept")
                try ctx.doesNotContain(text, "Subscribe now", "navigation link removed")
                try ctx.doesNotContain(text, "Buy our newsletter", "advert removed")
                try ctx.doesNotContain(text, "Privacy", "footer link removed")
                try ctx.doesNotContain(text, "font-family", "CSS removed")
                try ctx.doesNotContain(text, "window.track", "script removed")

                try ctx.equal(document.title, "Why throughput declined")
                try ctx.equal(document.author, "A. Researcher")
                try ctx.equal(document.siteName, "example.com", "site name falls back to host")
                try ctx.notNil(document.publishedAt, "publish date parsed from og/meta")
            },

            test("preserves heading structure as a breadcrumb path") { ctx in
                let html = """
                <html><body><main>
                <h1>Causes</h1><p>Intro paragraph with enough words to be kept as a real block of prose text.</p>
                <h2>Administrative</h2><p>The reorganisation moved inspections to a central office, which delayed every permit.</p>
                <h3>Permits</h3><p>Permit applications took an average of forty one days to process in the following quarter.</p>
                </main></body></html>
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/causes")
                let paragraphs = document.blocks.filter { $0.kind == .paragraph }
                let permitParagraph = try ctx.unwrap(paragraphs.first { $0.text.contains("Permit applications") })
                try ctx.contains(permitParagraph.headingPath, "Causes")
                try ctx.contains(permitParagraph.headingPath, "Administrative")
                try ctx.contains(permitParagraph.headingPath, "Permits")
                let heading = try ctx.unwrap(document.blocks.first { $0.text == "Causes" })
                try ctx.equal(heading.level, 1)
                try ctx.equal(heading.kind, .heading)
            },

            test("extracts tables, quotes, code and list items") { ctx in
                let html = """
                <html><body><article>
                <p>This paragraph contains enough characters to survive the minimum length filter applied during extraction.</p>
                <ul><li>First finding about throughput</li><li>Second finding about permits</li></ul>
                <blockquote>The review board found no single cause.</blockquote>
                <pre>SELECT * FROM inspections WHERE region = 4;</pre>
                <table><tr><th>Region</th><th>Change</th></tr><tr><td>North</td><td>-19%</td></tr></table>
                <img src="/chart.png" alt="Chart showing a decline across all seven regions">
                </article></body></html>
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/data")
                let kinds = Set(document.blocks.map(\.kind))
                try ctx.check(kinds.contains(.listItem), "list items extracted")
                try ctx.check(kinds.contains(.quote), "blockquote extracted")
                try ctx.check(kinds.contains(.code), "code block extracted")
                try ctx.check(kinds.contains(.table), "table extracted")
                try ctx.check(kinds.contains(.caption), "image alt text extracted")

                let table = try ctx.unwrap(document.blocks.first { $0.kind == .table })
                try ctx.contains(table.text, "North | -19%")
                let quote = try ctx.unwrap(document.blocks.first { $0.kind == .quote })
                try ctx.contains(quote.text, "no single cause")
            },

            test("does not duplicate text from nested markup") { ctx in
                let html = """
                <html><body><div class="article"><div class="article-body"><div>
                <p>Duplicate me once. This sentence is long enough to be extracted as a paragraph of prose.</p>
                </div></div></div></body></html>
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/nested")
                let occurrences = document.blocks.filter { $0.text.contains("Duplicate me once") }.count
                try ctx.equal(occurrences, 1, "each sentence appears once, got \(occurrences)")
            },

            test("prefers the longest article over a multi-article index page") { ctx in
                let short = "<article><h2>Brief</h2><p>A short teaser about the decline that is not the main story of this page at all.</p></article>"
                let long = String(repeating: "<p>The long report explains the inspection backlog in detail across many pages of prose and evidence.</p>", count: 12)
                let html = "<html><body><main><div class=\"index\">\(short)\(short)\(short)</div><article class=\"story\">\(long)</article></main></body></html>"
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/index")
                try ctx.contains(document.plainText, "long report explains", "the substantial article wins")
            },

            test("a page with no prose reports an explicit failure, not an empty document") { ctx in
                let html = """
                <html><head><title>App shell</title><script>render()</script></head>
                <body><div id="root"></div><nav><a href="/a">A</a><a href="/b">B</a></nav></body></html>
                """
                let error = try await ctx.expectError("rejects a JS-only page") {
                    try HTMLExtractor.extract(html: html, url: "https://app.example.com/")
                }
                let failure = try ctx.unwrap(error as? HTMLExtractor.Failure, "expected Failure.noReadableContent")
                guard case .noReadableContent(let length) = failure else {
                    throw TestFailure(description: "expected noReadableContent, got \(failure)")
                }
                try ctx.check(length < 200, "reports how little text it found: \(length)")
            },

            test("malformed HTML does not crash and still yields content") { ctx in
                let html = """
                <html><body><div class="post"><p>Unclosed paragraph with plenty of words to be extracted from a broken page.
                <p>Second paragraph <b>bold <i>nested</b> mismatched</i> tail text that continues for a while longer here.
                <div><span>Trailing span text that should still be captured by the tolerant walker of the extractor.
                <table><tr><td>Cell without closing row
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/broken")
                try ctx.contains(document.plainText, "Unclosed paragraph")
                try ctx.contains(document.plainText, "mismatched")
                try ctx.equal(document.title, "broken", "falls back to a path-derived title")
            },

            test("handles attribute quoting variants and self-closing tags") { ctx in
                let html = """
                <html><head><meta name=author content='No Quotes'><meta charset="utf-8"/></head>
                <body><article><p class=body unquoted=yes>This text has attributes with and without quotes around them.</p>
                <br><hr/><img src="a.png" alt="A described picture for accessibility"></article></body></html>
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/attrs")
                try ctx.equal(document.author, "No Quotes")
                try ctx.contains(document.plainText, "attributes with and without quotes")
                try ctx.equal(document.language, "utf-8")
            },

            test("extraction is fast enough for large pages") { ctx in
                var body = ""
                for index in 0..<1_500 {
                    body += "<p>Paragraph \(index) describing inspection throughput in region \(index % 24) with enough words to count as prose.</p>"
                    if index % 50 == 0 { body += "<h2>Section \(index / 50)</h2>" }
                }
                let html = "<html><body><article>\(body)</article></body></html>"
                let start = Date()
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/huge")
                let elapsed = Date().timeIntervalSince(start)
                try ctx.check(document.blocks.count > 1_400, "extracted \(document.blocks.count) blocks")
                try ctx.check(elapsed < 60, "large page extracted in \(String(format: "%.2f", elapsed))s")
                ctx.note("1500-paragraph page in \(String(format: "%.2f", elapsed))s")
            },

            test("markdown, text and HTML sources share one rendering") { ctx in
                let document = ExtractedDocument(
                    title: "T", blocks: [
                        ExtractedBlock(kind: .heading, text: "Title", level: 2),
                        ExtractedBlock(kind: .paragraph, text: "Body text."),
                        ExtractedBlock(kind: .listItem, text: "Item"),
                        ExtractedBlock(kind: .quote, text: "Quote")
                    ], method: "test"
                )
                let rendered = document.plainText
                try ctx.contains(rendered, "## Title")
                try ctx.contains(rendered, "Body text.")
                try ctx.contains(rendered, "- Item")
                try ctx.contains(rendered, "> Quote")
                try ctx.equal(document.pageCount, nil, "unpaginated document has no page count")
                try ctx.equal(document.wordCount, 5)
            }
        ])
    }
}
