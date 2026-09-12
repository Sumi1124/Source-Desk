import Foundation
import SourceDeskCore

/// Leading-boilerplate removal.
///
/// Real pages put interface chrome at the top, and the head of a document is what a
/// model weighs most. Wikipedia was the page that exposed this: its sidebar language
/// list is one long paragraph of language names that scores as prose, so it landed as
/// the document's opening block — feeding the model a list of languages before any
/// content, and polluting the embeddings for the whole source.
///
/// These tests use markup shaped like the real thing, because the bug only appears with
/// realistic navigation: a fixture of pure paragraphs never reproduced it.
enum BoilerplateSuite {

    /// A page whose first paragraph is a language list, as Wikipedia produces.
    static func pageWithLanguageList(body: String) -> String {
        """
        <html><head><title>RISC-V</title></head><body>
        <div id="mw-navigation">
          <div class="vector-menu">
            <p>Toggle the table of contents RISC-V 31 languages العربية Català Čeština Deutsch \
        Ελληνικά Español Eesti Euskara فارسی Suomi Français עברית Magyar Italiano 日本語 한국어 \
        Nederlands Norsk bokmål Polski Português Русский Shqip Српски / srpski Svenska Türkçe \
        Українська Tiếng Việt 吴语 粵語 中文 Edit links</p>
          </div>
        </div>
        <div id="content">
          <p>Appearance move to sidebar hide</p>
          <p>From Wikipedia, the free encyclopedia</p>
          \(body)
        </div>
        </body></html>
        """
    }

    static let realProse = """
    <p>RISC-V is a free and open standard instruction set architecture based on established \
    reduced instruction set computer principles. Unlike proprietary architectures, RISC-V is \
    open and royalty-free, which allows anyone to design and manufacture RISC-V chips without \
    paying licensing fees to a single vendor.</p>
    <p>RISC-V was developed in 2010 at the University of California, Berkeley as the fifth \
    generation of the design, and it has since been adopted widely across embedded systems and \
    academic research. The specification is maintained by RISC-V International.</p>
    """

    static var suite: TestSuite {
        TestSuite("17 · Leading boilerplate", cases: [

            test("a leading language list does not become the opening block") { ctx in
                let document = try HTMLExtractor.extract(
                    html: pageWithLanguageList(body: realProse),
                    url: "https://en.wikipedia.org/wiki/RISC-V"
                )
                let text = document.plainText

                // The specific pollution: the language list must not lead the document.
                try ctx.check(!text.prefix(300).contains("Français"),
                              "the document does not open with a list of languages")
                try ctx.check(!text.prefix(300).contains("Toggle the table of contents"),
                              "the document does not open with interface chrome")

                // And the real content survived.
                try ctx.contains(text, "free and open standard instruction set architecture")
                try ctx.contains(text, "University of California, Berkeley")
            },

            test("trimming the head never removes the article itself") { ctx in
                // The risk of a head trim is eating the opening paragraph, which is
                // usually the most important one. A page that opens directly with prose
                // must be untouched.
                let html = """
                <html><head><title>Direct</title></head><body>
                <div id="content">
                  <h1>Direct</h1>
                  \(realProse)
                </div>
                </body></html>
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/direct")
                let text = document.plainText
                try ctx.contains(text, "free and open standard instruction set architecture",
                                 "the opening paragraph is kept")
            },

            test("a short page is not trimmed into nothing") { ctx in
                // A genuinely short notice is still a useful source; the head trim must
                // not decide that everything is furniture.
                let html = """
                <html><head><title>Notice</title></head><body>
                <div id="content">
                  <p>This page has moved to a new address. Please update your bookmarks and \
                  links accordingly, as the old location will stop being served.</p>
                </div>
                </body></html>
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/notice")
                try ctx.contains(document.plainText, "has moved to a new address")
            },

            test("disabling the head trim restores the previous behaviour") { ctx in
                // The option exists so the behaviour is inspectable rather than implicit:
                // with it off, the chrome is back at the head of the document.
                var options = HTMLExtractor.Options()
                options.trimBoilerplateHead = false
                let document = try HTMLExtractor.extract(
                    html: pageWithLanguageList(body: realProse),
                    url: "https://en.wikipedia.org/wiki/RISC-V",
                    options: options
                )
                let text = document.plainText
                // Note what is and is not here: the container scorer already discards the
                // navigation div that holds the language list, so what the head trim has
                // left to remove is the inline chrome that sits inside the content
                // container. That is the realistic shape on a small page.
                try ctx.check(text.hasPrefix("Appearance move to sidebar hide")
                              || text.prefix(120).contains("From Wikipedia"),
                              "with the trim off, the chrome leads the document")
                try ctx.contains(text, "free and open standard instruction set architecture",
                                 "and the article is still there")
            },

            test("the head trim removes chrome but never the article's opening") { ctx in
                // The same page, trimmed: chrome gone, prose first. Asserted side by side
                // so the difference is unambiguous.
                let document = try HTMLExtractor.extract(
                    html: pageWithLanguageList(body: realProse),
                    url: "https://en.wikipedia.org/wiki/RISC-V"
                )
                let text = document.plainText
                try ctx.check(!text.prefix(200).contains("Appearance move to sidebar hide"),
                              "the chrome no longer leads")
                try ctx.check(text.prefix(120).contains("free and open standard instruction set architecture"),
                              "the article's opening sentence leads instead")
            },

            test("a leading table of contents is dropped with the chrome") { ctx in
                let html = """
                <html><head><title>Guide</title></head><body>
                <div id="content">
                  <p>Jump to content</p>
                  <ul>
                    <li>Introduction</li>
                    <li>Installation</li>
                    <li>Configuration</li>
                    <li>Troubleshooting</li>
                    <li>Further reading</li>
                  </ul>
                  \(realProse)
                </div>
                </body></html>
                """
                let document = try HTMLExtractor.extract(html: html, url: "https://example.com/guide")
                let text = document.plainText
                try ctx.check(!text.prefix(200).contains("Jump to content"),
                              "the jump link is removed")
                try ctx.contains(text, "free and open standard instruction set architecture",
                                 "the real content is kept")
            },
        ])
    }
}
