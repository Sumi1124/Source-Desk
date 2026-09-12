import Foundation

/// Turns an HTML page into readable content.
///
/// The approach is readability-style scoring: score every candidate container by
/// how much *prose* it holds relative to markup and link text, then keep the best
/// one and walk it in document order. Navigation, advertising, cookie notices and
/// footers lose on their own merits (they are link-dense and text-poor) rather than
/// because of a hard-coded list of class names — which is what makes it work on
/// sites whose chrome is classed `x-nav-2`.
public enum HTMLExtractor {

    public struct Options: Sendable {
        public var includeImageAltText: Bool = true
        public var includeCodeBlocks: Bool = true
        /// Strips a leading navigation/breadcrumb block from the chosen content.
        public var trimBoilerplateHead: Bool = true
        /// Strips a trailing licence/footer block from the chosen content.
        public var trimBoilerplateTail: Bool = true
        /// Below this many characters of prose we assume client-rendered markup
        /// rather than a text-light page, and say so explicitly. Kept deliberately
        /// low: a genuinely short page ("this notice has moved") is still a useful
        /// source, while an app shell has almost no text at all.
        public var minimumTextLength: Int = 80

        public init() {}
    }

    public enum Failure: Error, Equatable {
        case noReadableContent(textLength: Int)
    }

    // MARK: - Entry points

    public static func extract(
        html: String,
        url: String,
        fallbackTitle: String? = nil,
        options: Options = Options()
    ) throws -> ExtractedDocument {
        let tokens = HTMLTokenizer.tokenize(html)
        return try extract(tokens: tokens, url: url, fallbackTitle: fallbackTitle, options: options)
    }

    public static func extract(
        tokens: [HTMLToken],
        url: String,
        fallbackTitle: String? = nil,
        options: Options = Options()
    ) throws -> ExtractedDocument {

        let metadata = MetadataParser.parse(tokens)
        let root = DOMBuilder.build(tokens)
        NodeStats.compute(root)

        let contentRoot = ContentSelector.select(root)
        var blocks = BlockExtractor.blocks(from: contentRoot, options: options)

        // Head first: leading chrome is a long list of labels, and leaving it in place
        // can make the tail trimmer misjudge where the content ends. Both are
        // conservative and neither can empty a document.
        if options.trimBoilerplateHead {
            blocks = BlockExtractor.trimHead(blocks)
        }
        if options.trimBoilerplateTail {
            blocks = BlockExtractor.trimTail(blocks)
        }

        let proseLength = blocks.reduce(0) { $0 + $1.text.count }
        if proseLength < options.minimumTextLength {
            // Distinguish "this page really has almost no text" from "we chose the
            // wrong container but the page was full of prose".
            let fallbackBlocks = BlockExtractor.blocks(from: root, options: options)
            let fallbackLength = fallbackBlocks.reduce(0) { $0 + $1.text.count }
            if fallbackLength > proseLength {
                blocks = fallbackBlocks
            } else if proseLength < options.minimumTextLength {
                throw Failure.noReadableContent(textLength: proseLength)
            }
        }

        return ExtractedDocument(
            title: metadata.title ?? fallbackTitle ?? hostTitle(url),
            author: metadata.author,
            siteName: metadata.siteName ?? hostName(url),
            publishedAt: metadata.publishedAt,
            canonicalURL: metadata.canonicalURL,
            summary: metadata.description,
            language: metadata.language,
            method: "readability",
            pages: [ExtractedPage(number: 0, blocks: blocks)]
        )
    }

    // MARK: - Metadata

    public struct Metadata: Sendable {
        public var title: String?
        public var author: String?
        public var siteName: String?
        public var description: String?
        public var canonicalURL: String?
        public var publishedAt: Date?
        public var language: String?
    }

    enum MetadataParser {

        static func parse(_ tokens: [HTMLToken]) -> Metadata {
            var meta: [String: String] = [:]
            var propertyMeta: [String: String] = [:]
            var documentTitle: String?
            var canonical: String?
            var language: String?
            var inTitle = false
            var titleText = ""

            for token in tokens {
                switch token {
                case .startTag(let name, let attributes, let selfClosing):
                    switch name {
                    case "title":
                        inTitle = !selfClosing
                    case "html":
                        if language == nil { language = attributes["lang"] }
                    case "link":
                        if attributes["rel"]?.lowercased() == "canonical", let href = attributes["href"] { canonical = href }
                    case "meta":
                        if let charset = attributes["charset"], language == nil, charset.count < 12 { language = charset }
                        guard let key = attributes["name"] ?? attributes["property"] ?? attributes["itemprop"],
                              let content = attributes["content"], !content.isEmpty else { continue }
                        let normalized = key.lowercased()
                        if normalized.contains(":") {
                            if propertyMeta[normalized] == nil { propertyMeta[normalized] = content }
                        } else if meta[normalized] == nil {
                            meta[normalized] = content
                        }
                    default:
                        break
                    }
                case .endTag(let name):
                    if name == "title" {
                        inTitle = false
                        let cleaned = HTMLEntities.decode(titleText)
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty { documentTitle = cleaned }
                    }
                case .text(let text):
                    if inTitle { titleText += text }
                default:
                    break
                }
            }

            func firstMeta(_ keys: [String]) -> String? {
                for key in keys {
                    if let value = meta[key] ?? propertyMeta[key], !value.isEmpty { return value }
                }
                return nil
            }

            let siteName = firstMeta(["og:site_name", "application-name", "publisher"])
            var title = firstMeta(["og:title", "twitter:title", "headline"]) ?? documentTitle
            if let raw = title { title = splitTitleFromSiteName(raw, siteName: siteName) }

            return Metadata(
                title: title,
                author: firstMeta(["author", "article:author", "byl", "dc.creator", "citation_author"]),
                siteName: siteName,
                description: firstMeta(["description", "og:description", "twitter:description"]),
                canonicalURL: canonical,
                publishedAt: firstMeta([
                    "article:published_time", "og:published_time", "date", "datepublished",
                    "dc.date", "dc.date.issued", "pubdate", "citation_publication_date"
                ]).flatMap(DateParsing.parse),
                language: firstMeta(["og:locale", "language"])?.components(separatedBy: "_").first ?? language
            )
        }

        /// "Headline — Site Name" is everywhere; recover the headline.
        static func splitTitleFromSiteName(_ title: String, siteName: String?) -> String {
            let separators = [" | ", " — ", " – ", " - ", " · ", " :: ", " » "]
            for separator in separators {
                let parts = title.components(separatedBy: separator)
                guard parts.count >= 2, parts.count <= 4 else { continue }
                if let siteName,
                   let matchIndex = parts.firstIndex(where: { $0.compare(siteName, options: .caseInsensitive) == .orderedSame }) {
                    let remaining = parts.enumerated().filter { $0.offset != matchIndex }.map(\.element)
                    if let best = remaining.max(by: { $0.count < $1.count }), best.count >= 12 {
                        return best.trimmingCharacters(in: .whitespaces)
                    }
                }
                if let first = parts.first, first.count > 12, (parts.last?.count ?? 0) < 30 {
                    return first.trimmingCharacters(in: .whitespaces)
                }
            }
            return title.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Content selection

    enum ContentSelector {

        static func select(_ root: ElementNode) -> ElementNode {
            var best: (node: ElementNode, score: Double)?
            var bestPreferred: (node: ElementNode, score: Double)?

            func visit(_ node: ElementNode) {
                defer { for child in node.children where child.isElement { visit(child) } }
                guard node.isElement, node.stats.textLength > 0 else { return }
                let score = score(node)
                if best == nil || score > best!.score { best = (node, score) }
                if node.name == "article" || node.name == "main" {
                    if bestPreferred == nil || score > bestPreferred!.score { bestPreferred = (node, score) }
                }
            }
            visit(root)

            guard let winner = best else { return root }
            if let preferred = bestPreferred, preferred.score >= winner.score * 0.8 {
                return preferred.node
            }
            // Never return the document root itself: it carries nav and footer.
            return winner.node === root ? root : winner.node
        }

        static func score(_ node: ElementNode) -> Double {
            let text = Double(node.stats.textLength)
            guard text > 0 else { return 0 }
            let linkShare = min(1, Double(node.stats.linkTextLength) / text)
            let punctuationDensity = min(1, Double(node.stats.punctuation) / Double(max(1, node.stats.paragraphCount)))
            var score = text
            if linkShare > 0.5 { score *= 0.15 }
            else if linkShare > 0.3 { score *= 0.45 }
            score *= (0.55 + punctuationDensity * 0.45)
            switch node.name {
            case "article": score *= 1.4
            case "main": score *= 1.25
            case "section": score *= 1.05
            case "div": break
            case "aside", "nav", "footer", "header", "form", "ul", "ol", "select", "figure": score *= 0.2
            case "body", "html": score *= 0.9
            default: score *= 0.6
            }
            let classes = node.classHint
            if classLooksLikeChrome(classes) { score *= 0.12 }
            if classLooksLikeContent(classes) { score *= 1.45 }
            // Depth bonus: an inner container scores better than a wrapper holding
            // sibling articles, which is what keeps multi-article index pages sane.
            score *= (1.0 + min(0.15, Double(node.stats.depth) * 0.01))
            return score
        }

        static func classLooksLikeChrome(_ classes: String) -> Bool {
            let signals = ["nav", "menu", "sidebar", "side-bar", "footer", "header", "masthead", "breadcrumb",
                           "cookie", "consent", "gdpr", "advert", "ads-", "-ads", "promo", "sponsor",
                           "subscribe", "newsletter", "paywall", "share", "social", "related", "recommend",
                           "comment", "disqus", "pagination", "pager", "toolbar", "skip-link", "popup", "modal"]
            return signals.contains { classes.contains($0) }
        }

        static func classLooksLikeContent(_ classes: String) -> Bool {
            let signals = ["article", "post", "entry", "content", "story", "body", "main", "prose", "markdown", "transcript"]
            return signals.contains { classes.contains($0) }
        }
    }

    // MARK: - Block extraction

    enum BlockExtractor {

        static let skipSubtreeTags: Set<String> = ["script", "style", "noscript", "svg", "canvas", "iframe", "form", "button", "select", "input", "template"]
        /// Every element the walker treats as a *block* — its content is emitted as
        /// its own block rather than being merged into surrounding prose.
        static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "li", "ul", "ol", "dl",
                                             "blockquote", "pre", "table", "figure", "hr", "details", "summary",
                                             "img", "h1", "h2", "h3", "h4", "h5", "h6",
                                             "td", "th", "dd", "dt", "figcaption", "caption"]
        static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

        static func blocks(from root: ElementNode, options: Options) -> [ExtractedBlock] {
            var output: [ExtractedBlock] = []
            var headingStack: [(level: Int, text: String)] = []

            func headingPath() -> String { headingStack.map(\.text).joined(separator: " › ") }

            func skip(_ node: ElementNode) -> Bool {
                let tag = node.name
                if skipSubtreeTags.contains(tag) { return true }
                if tag == "footer" || tag == "nav" { return true }
                if node.attributes["aria-hidden"] == "true" { return true }
                if node.attributes["hidden"] != nil { return true }
                let role = node.attributes["role"]
                if role == "navigation" || role == "banner" || role == "complementary" { return true }
                if (node.attributes["style"] ?? "").lowercased().contains("display:none") { return true }
                let classes = node.classHint
                if ContentSelector.classLooksLikeChrome(classes) && node.stats.textLength < 1_500 && tag != "p" { return true }
                return false
            }

            func emitText(_ text: String, kind: ExtractedBlock.Kind, minimum: Int = 2) {
                let cleaned = clean(text)
                guard cleaned.count >= minimum else { return }
                output.append(ExtractedBlock(kind: kind, text: cleaned, headingPath: headingPath()))
            }

            func walk(_ node: ElementNode) {
                guard node.isElement else {
                    // A bare text node: only meaningful if it is a real paragraph.
                    if case .text(let text) = node.token {
                        let cleaned = clean(text)
                        if cleaned.count >= 60 { emitText(cleaned, kind: .paragraph) }
                    }
                    return
                }
                if skip(node) { return }
                let tag = node.name

                if headingTags.contains(tag) {
                    let text = clean(node.flatText)
                    if !text.isEmpty {
                        let level = Int(String(tag.dropFirst())) ?? 2
                        while let last = headingStack.last, last.level >= level { headingStack.removeLast() }
                        headingStack.append((level, text))
                        output.append(ExtractedBlock(kind: .heading, text: text, level: level, headingPath: headingPath()))
                    }
                    return
                }

                if tag == "pre" {
                    let code = node.flatText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if options.includeCodeBlocks, code.count > 8 {
                        output.append(ExtractedBlock(kind: .code, text: code, headingPath: headingPath()))
                    }
                    return
                }

                if tag == "blockquote" {
                    emitText(node.flatText, kind: .quote, minimum: 2)
                    return
                }

                if tag == "img" {
                    if options.includeImageAltText, let alt = node.attributes["alt"],
                       alt.count > 12, !alt.lowercased().hasPrefix("logo") {
                        emitText(alt, kind: .caption, minimum: 12)
                    }
                    return
                }

                if tag == "table" {
                    let rows = node.descendants(named: "tr").compactMap { row -> String? in
                        let cells = row.children.compactMap { child -> String? in
                            guard child.isElement, child.name == "td" || child.name == "th" else { return nil }
                            let value = clean(child.flatText)
                            return value.isEmpty ? nil : value
                        }
                        return cells.isEmpty ? nil : cells.joined(separator: " | ")
                    }
                    if !rows.isEmpty {
                        output.append(ExtractedBlock(kind: .table, text: rows.joined(separator: "\n"), headingPath: headingPath()))
                    }
                    return
                }

                if tag == "li" {
                    let own = clean(ownText(node))
                    if !own.isEmpty, own.count >= 3, node.linkShare < 0.9 {
                        output.append(ExtractedBlock(kind: .listItem, text: own, headingPath: headingPath()))
                    }
                    for child in node.children { walk(child) }
                    return
                }

                if tag == "dd" || tag == "dt" {
                    emitText(node.flatText, kind: .paragraph)
                    return
                }

                if blockTags.contains(tag) {
                    let hasBlockChildren = node.children.contains { $0.isElement && blockTags.contains($0.name) }
                    if !hasBlockChildren {
                        emitText(node.flatText, kind: .paragraph)
                        return
                    }
                    // Mixed content: a container holding both prose and block
                    // children. Inline runs are accumulated and flushed as their own
                    // paragraphs, otherwise text that sits beside a nested <div>
                    // (very common in badly nested pages) would be lost.
                    var run = ""
                    for child in node.children {
                        if child.isElement && blockTags.contains(child.name) {
                            if run.count >= 20 { emitText(run, kind: .paragraph) }
                            run = ""
                            walk(child)
                        } else if child.isElement {
                            if headingTags.contains(child.name) {
                                if run.count >= 20 { emitText(run, kind: .paragraph) }
                                run = ""
                                walk(child)
                            } else {
                                let inline = clean(child.flatText)
                                if !inline.isEmpty { run += (run.isEmpty ? "" : " ") + inline }
                            }
                        } else if case .text(let text) = child.token {
                            let inline = clean(text)
                            if !inline.isEmpty { run += (run.isEmpty ? "" : " ") + inline }
                        }
                    }
                    if run.count >= 20 { emitText(run, kind: .paragraph) }
                    return
                }

                for child in node.children { walk(child) }
            }

            walk(root)
            return dedupe(output)
        }

        /// Text directly owned by a node, so nested lists do not collapse upward.
        static func ownText(_ node: ElementNode) -> String {
            var parts: [String] = []
            for child in node.children {
                if case .text(let text) = child.token { parts.append(text) }
                else if child.isElement, child.name == "img", let alt = child.attributes["alt"] { parts.append(" " + alt + " ") }
            }
            return parts.joined(separator: " ")
        }

        static func clean(_ text: String) -> String {
            HTMLEntities.decode(text)
                .replacingOccurrences(of: "[\\u{00A0}\\u{200B}\\u{FEFF}]", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "[\\t\\r\\n]+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func dedupe(_ blocks: [ExtractedBlock]) -> [ExtractedBlock] {
            var seen = Set<String>()
            var output: [ExtractedBlock] = []
            for block in blocks {
                let key = String(block.text.lowercased().prefix(160))
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                output.append(block)
            }
            return output
        }

        /// Drops *leading* navigation furniture that survives container scoring.
        ///
        /// Wikipedia is the clearest case: its sidebar language list is a single long
        /// paragraph of language names that scores as prose, so it becomes the first
        /// block of the document. The head of a document is exactly what a model weights
        /// most heavily, so leaving it there feeds the model a list of languages before
        /// any actual content — and it pollutes embeddings for the whole source.
        ///
        /// Conservative by construction, because a document's opening paragraph is
        /// usually the most important one. A block is only dropped when it is one of:
        ///
        ///   * a recognised interface string ("move to sidebar hide", "jump to content"),
        ///   * a language-list block (many short capitalised tokens, almost no verbs),
        ///   * a very short block that carries no sentence-ending punctuation,
        ///
        /// and the trimming stops at the first block that looks like real prose. It will
        /// never consume more than a few blocks, and never the whole document.
        static func trimHead(_ blocks: [ExtractedBlock]) -> [ExtractedBlock] {
            guard blocks.count > 3 else { return blocks }

            let interfacePhrases = ["jump to content", "move to sidebar", "move to top", "toggle the table of contents",
                                    "toggle sidebar", "skip to content", "skip to main content", "main menu",
                                    "toggle navigation", "appearance", "from wikipedia, the free encyclopedia",
                                    "edit links", "personal tools", "create account", "log in", "search"]
            let languageNames = ["العربية", "Čeština", "Deutsch", "Ελληνικά", "Español", "Eesti", "Euskara",
                                 "فارسی", "Suomi", "Français", "עברית", "Magyar", "Italiano", "日本語", "한국어",
                                 "Nederlands", "Norsk", "Polski", "Português", "Русский", "Shqip", "Svenska",
                                 "Türkçe", "Українська", "Tiếng Việt", "吴语", "粵語", "中文", "Bahasa", "Dansk",
                                 "हिन्दी", "Bahasa Indonesia", "Norsk bokmål", "Simple English", "srpski"]

            /// Many short tokens and almost no sentence structure: a list of labels.
            func looksLikeLabelList(_ text: String) -> Bool {
                // Count how many of the tokens are language names or single capitals.
                let tokens = text.split(separator: " ")
                guard tokens.count >= 8 else { return false }
                let known = languageNames.reduce(0) { count, name in
                    count + (text.contains(name) ? 1 : 0)
                }
                if known >= 3 { return true }
                // Otherwise: no sentence-ending punctuation across a long span of words is
                // a strong signal that this is a menu, not prose.
                let hasSentencePunctuation = text.contains(". ") || text.hasSuffix(".")
                return !hasSentencePunctuation && tokens.count >= 25
            }

            func isInterface(_ text: String) -> Bool {
                let lowered = text.lowercased()
                return interfacePhrases.contains { lowered.contains($0) }
            }

            func isFurniture(_ block: ExtractedBlock) -> Bool {
                switch block.kind {
                case .heading:
                    return false
                case .listItem:
                    // A leading list is usually a table of contents or a nav list.
                    return block.text.count < 200
                case .paragraph, .quote:
                    if isInterface(block.text) { return true }
                    if looksLikeLabelList(block.text) { return true }
                    // A short fragment with no sentence punctuation.
                    return block.text.count < 120
                        && !block.text.contains(". ")
                        && !block.text.hasSuffix(".")
                        && !block.text.hasSuffix("?")
                        && !block.text.hasSuffix("!")
                default:
                    return false
                }
            }

            var start = 0
            // Never remove more than the first handful of blocks, and never leave the
            // document with fewer than two blocks.
            let limit = min(blocks.count - 2, 6)
            while start < limit, isFurniture(blocks[start]) {
                start += 1
            }

            // Only accept the trim when something substantial remains — otherwise the
            // "furniture" was probably the content itself.
            let remaining = blocks[(start)...].reduce(0) { $0 + $1.text.count }
            let original = blocks.reduce(0) { $0 + $1.text.count }
            guard remaining >= 200, Double(remaining) >= Double(original) * 0.3 else {
                return blocks
            }
            return Array(blocks[start...])
        }

        /// Drops trailing licence/footer/related-content noise that survives scoring.
        ///
        /// Deliberately conservative: a lone short paragraph at the end is usually a
        /// legitimate conclusion, so only a *run* of two or more short/signal blocks
        /// (or an unmistakable footer phrase) is removed.
        static func trimTail(_ blocks: [ExtractedBlock]) -> [ExtractedBlock] {
            let signals = ["all rights reserved", "©", "(c) 20", "share this article", "related articles",
                           "read more", "subscribe to", "sign up for", "follow us on", "privacy policy",
                           "terms of service", "cookie policy", "advertisement", "originally published",
                           "this article was updated", "photo credit", "getty images"]
            func isNoise(_ block: ExtractedBlock) -> (signal: Bool, tiny: Bool) {
                let lowered = block.text.lowercased()
                let signal = signals.contains { lowered.contains($0) }
                let tiny = block.text.count < 90 && (block.kind == .paragraph || block.kind == .listItem)
                return (signal, tiny)
            }

            var end = blocks.count
            while end > 4 {
                let last = isNoise(blocks[end - 1])
                if last.signal {
                    end -= 1
                    continue
                }
                // A short run of tiny blocks at the very end is boilerplate.
                if last.tiny, end > 5 {
                    let previous = isNoise(blocks[end - 2])
                    if previous.signal || previous.tiny {
                        end -= 1
                        continue
                    }
                }
                break
            }
            return Array(blocks[0..<end])
        }
    }

    // MARK: - Helpers

    static func hostName(_ url: String) -> String? {
        guard let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func hostTitle(_ url: String) -> String {
        guard let url = URL(string: url), let host = url.host() else { return url }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return host }
        let last = path.components(separatedBy: "/").last ?? ""
        let readable = last
            .replacingOccurrences(of: ".html", with: "")
            .replacingOccurrences(of: ".htm", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return readable.isEmpty ? host : readable
    }
}

// MARK: - DOM

/// A node used by the extractor. Text nodes are children too, so one tree type
/// covers elements and runs of text.
public final class ElementNode {
    public var name: String
    public var attributes: [String: String]
    public var children: [ElementNode]
    public var token: HTMLToken = .text("")
    public internal(set) var stats = NodeStats()

    public init(name: String, attributes: [String: String], children: [ElementNode]) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    public var isElement: Bool {
        if case .text = token { return false }
        return true
    }

    public var classHint: String {
        ((attributes["class"] ?? "") + " " + (attributes["id"] ?? "") + " " + (attributes["role"] ?? "")).lowercased()
    }

    public var flatText: String {
        var parts: [String] = []
        var stack: [ElementNode] = [self]
        while let node = stack.popLast() {
            if case .text(let text) = node.token { parts.append(text) }
            if let alt = node.attributes["alt"], node.name == "img" { parts.append(" " + alt + " ") }
            if HTMLTokenizer.voidElements.contains(node.name) { parts.append(" ") }
            for child in node.children.reversed() { stack.append(child) }
        }
        return parts.joined(separator: " ")
    }

    public var linkShare: Double {
        let total = stats.textLength
        guard total > 0 else { return 1 }
        return min(1, Double(stats.linkTextLength) / Double(total))
    }

    public func descendants(named target: String) -> [ElementNode] {
        var found: [ElementNode] = []
        var stack: [ElementNode] = [self]
        while let node = stack.popLast() {
            for child in node.children where child.isElement {
                if child.name == target { found.append(child) }
                stack.append(child)
            }
        }
        return found
    }
}

/// Per-node measurements, computed once in a single post-order pass. Scoring and
/// block extraction both read these instead of re-flattening text repeatedly.
public struct NodeStats: Sendable {
    public var textLength: Int = 0
    public var linkTextLength: Int = 0
    public var punctuation: Int = 0
    public var paragraphCount: Int = 0
    public var depth: Int = 0

    public static func compute(_ node: ElementNode, depth: Int = 0) {
        var textLength = 0
        var linkText = 0
        var punctuation = 0
        var paragraphs = 0
        var maxChildDepth = depth

        for child in node.children {
            if case .text(let text) = child.token {
                textLength += text.count
                punctuation += text.reduce(0) { $0 + (".!?,;。！？，、".contains($1) ? 1 : 0) }
            } else {
                compute(child, depth: depth + 1)
                textLength += child.stats.textLength
                punctuation += child.stats.punctuation
                paragraphs += child.stats.paragraphCount
                maxChildDepth = max(maxChildDepth, child.stats.depth)
                if child.name == "a" {
                    linkText += child.stats.textLength
                } else {
                    linkText += child.stats.linkTextLength
                }
            }
        }

        if node.name == "p" || node.name == "li" || node.name == "blockquote" || node.name == "pre" { paragraphs += 1 }
        if node.name == "img", let alt = node.attributes["alt"] { textLength += alt.count }

        node.stats = NodeStats(
            textLength: textLength,
            linkTextLength: linkText,
            punctuation: punctuation,
            paragraphCount: max(1, paragraphs),
            depth: maxChildDepth
        )
    }
}

public enum DOMBuilder {

    /// Tolerant tree construction: unknown or mis-nested tags are closed implicitly
    /// and stray end tags are ignored, so malformed real-world HTML still produces
    /// a usable tree instead of an error.
    public static func build(_ tokens: [HTMLToken]) -> ElementNode {
        let root = ElementNode(name: "document", attributes: [:], children: [])
        root.token = .startTag(name: "document", attributes: [:], selfClosing: false)
        var stack: [ElementNode] = [root]

        for token in tokens {
            switch token {
            case .text(let text):
                guard !text.isEmpty else { continue }
                let node = ElementNode(name: "#text", attributes: [:], children: [])
                node.token = .text(text)
                stack[stack.count - 1].children.append(node)
            case .startTag(let name, let attributes, let selfClosing):
                let node = ElementNode(name: name, attributes: attributes, children: [])
                node.token = token
                stack[stack.count - 1].children.append(node)
                if !selfClosing && !HTMLTokenizer.voidElements.contains(name) {
                    stack.append(node)
                }
            case .endTag(let name):
                guard let position = stack.lastIndex(where: { $0.name == name }), position > 0 else { continue }
                stack.removeSubrange(position...)
            case .comment, .doctype:
                continue
            }
        }
        return root
    }
}

// MARK: - Dates

public enum DateParsing {

    /// Parses the date formats that appear in `<meta>` tags, RSS feeds and JSON APIs.
    public static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. ISO 8601, with and without fractional seconds.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }

        // 2. Common explicit patterns.
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "dd MMM yyyy", "MMMM d, yyyy",
            "MMM d, yyyy", "d MMMM yyyy", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ss", "yyyyMMdd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = formatter.date(from: text) { return date }
        }

        // 3. Anything with a leading year.
        if text.count >= 10 {
            let head = String(text.prefix(10))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: head) { return date }
        }

        // 4. Relative timestamps from JSON feeds ("3 days ago").
        let relative = text.lowercased()
        if relative.contains("ago") {
            let number = Int(relative.components(separatedBy: CharacterSet.decimalDigits.inverted).first(where: { !$0.isEmpty }) ?? "")
            if let number {
                let seconds: TimeInterval
                if relative.contains("minute") { seconds = 60 }
                else if relative.contains("hour") { seconds = 3_600 }
                else if relative.contains("day") { seconds = 86_400 }
                else if relative.contains("week") { seconds = 604_800 }
                else if relative.contains("month") { seconds = 2_592_000 }
                else if relative.contains("year") { seconds = 31_536_000 }
                else { return nil }
                return Date(timeIntervalSinceNow: -Double(number) * seconds)
            }
        }
        return nil
    }
}
