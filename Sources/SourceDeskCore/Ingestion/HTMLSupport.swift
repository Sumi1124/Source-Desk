import Foundation

// MARK: - Extraction output

public struct ExtractedBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case heading, paragraph, listItem, quote, code, table, caption, other
    }

    public var kind: Kind
    public var text: String
    /// Heading level (1…6) when `kind == .heading`.
    public var level: Int
    /// Breadcrumb of enclosing headings, e.g. "Findings › Causes".
    public var headingPath: String

    public init(kind: Kind, text: String, level: Int = 0, headingPath: String = "") {
        self.kind = kind
        self.text = text
        self.level = level
        self.headingPath = headingPath
    }
}

public struct ExtractedPage: Codable, Hashable, Sendable {
    /// 1-based page number, or 0 when the document is not paginated (HTML, text).
    public var number: Int
    public var blocks: [ExtractedBlock]

    public init(number: Int, blocks: [ExtractedBlock]) {
        self.number = number
        self.blocks = blocks
    }
}

/// Everything the pipeline needs from a source, independent of where it came from.
public struct ExtractedDocument: Codable, Hashable, Sendable {
    public var title: String
    public var author: String?
    public var siteName: String?
    public var publishedAt: Date?
    public var canonicalURL: String?
    public var summary: String?
    public var language: String?
    /// Which extractor produced this, shown in the inspector so provenance is
    /// never mysterious.
    public var method: String
    public var pages: [ExtractedPage]

    public init(
        title: String,
        author: String? = nil,
        siteName: String? = nil,
        publishedAt: Date? = nil,
        canonicalURL: String? = nil,
        summary: String? = nil,
        language: String? = nil,
        method: String,
        pages: [ExtractedPage]
    ) {
        self.title = title
        self.author = author
        self.siteName = siteName
        self.publishedAt = publishedAt
        self.canonicalURL = canonicalURL
        self.summary = summary
        self.language = language
        self.method = method
        self.pages = pages
    }

    /// Single-page convenience for text-like sources.
    public init(title: String, blocks: [ExtractedBlock], method: String, author: String? = nil) {
        self.init(title: title, author: author, method: method, pages: [ExtractedPage(number: 0, blocks: blocks)])
    }

    public var blocks: [ExtractedBlock] { pages.flatMap(\.blocks) }

    public var plainText: String {
        DocumentText.render(self)
        }

    public var wordCount: Int { TextMath.wordCount(plainText) }

    public var pageCount: Int? {
        let numbered = pages.filter { $0.number > 0 }
        return numbered.isEmpty ? nil : numbered.count
    }

    public var isEmpty: Bool {
        blocks.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Renders blocks back to readable Markdown-ish text. This exact rendering is what
/// gets stored as `content.txt`, embedded, and shown in the inspector — one
/// representation everywhere, so what you read is what was indexed.
public enum DocumentText {

    public static func render(_ document: ExtractedDocument) -> String {
        var lines: [String] = []
        if let summary = document.summary, !summary.isEmpty, document.pages.count <= 1 {
            lines.append("_\(summary)_")
            lines.append("")
        }
        for page in document.pages {
            if document.pageCount != nil && document.pages.count > 1 {
                lines.append("## Page \(page.number)")
                lines.append("")
            }
            lines.append(contentsOf: render(blocks: page.blocks))
        }
        return trimTrailingBlankLines(lines.joined(separator: "\n"))
    }

    public static func render(blocks: [ExtractedBlock]) -> [String] {
        var lines: [String] = []
        for block in blocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch block.kind {
            case .heading:
                lines.append("")
                lines.append(String(repeating: "#", count: max(1, min(6, block.level))) + " " + text)
                lines.append("")
            case .listItem:
                lines.append("- " + text)
            case .quote:
                lines.append("> " + text)
            case .code:
                lines.append("```")
                lines.append(text)
                lines.append("```")
            case .table:
                lines.append(text)
                lines.append("")
            case .caption:
                lines.append("_" + text + "_")
            case .paragraph, .other:
                lines.append("")
                lines.append(text)
                lines.append("")
            }
        }
        return lines
    }

    private static func trimTrailingBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Collapses runs of blank lines: extracted pages frequently have several.
    public static func normalize(_ text: String) -> String {
        var out: [String] = []
        var blankRun = 0
        for line in text.components(separatedBy: "\n") {
            let trimmedRight = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if trimmedRight.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append("") }
            } else {
                blankRun = 0
                out.append(trimmedRight)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HTML tokens

public enum HTMLToken: Equatable {
    case text(String)
    case startTag(name: String, attributes: [String: String], selfClosing: Bool)
    case endTag(name: String)
    case comment(String)
    case doctype(String)

    public var tagName: String? {
        switch self {
        case .startTag(let name, _, _), .endTag(let name): return name
        default: return nil
        }
    }
}

/// A minimal, tolerant HTML tokenizer.
///
/// It is deliberately *not* a full HTML5 parser: it never throws, it never crashes
/// on malformed markup, and it tracks exactly the structure needed to pull readable
/// content out of real-world pages (including the badly nested ones).
public enum HTMLTokenizer {

    /// Elements whose contents are raw text and must not be parsed as markup.
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title", "noscript", "template", "svg", "math"]

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"
    ]

    public static func tokenize(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var index = html.startIndex
        let end = html.endIndex
        var textBuffer = ""

        func flushText() {
            if !textBuffer.isEmpty {
                tokens.append(.text(textBuffer))
                textBuffer.removeAll(keepingCapacity: true)
            }
        }

        while index < end {
            guard let open = html[index...].firstIndex(of: "<") else {
                if index < end { textBuffer += HTMLEntities.decode(String(html[index...])) }
                break
            }
            if open > index {
                textBuffer += String(html[index..<open])
            }
            guard let close = findTagEnd(html, from: open) else {
                // Unterminated '<' — treat the remainder as text.
                textBuffer += String(html[open...])
                break
            }
            let inner = String(html[html.index(after: open)..<close])

            if inner.hasPrefix("!--") {
                flushText()
                var body = inner
                if body.hasSuffix("--") { body = String(body.dropLast(2)) }
                tokens.append(.comment(String(body.dropFirst(3))))
            } else if inner.hasPrefix("!") {
                flushText()
                tokens.append(.doctype(inner))
            } else if inner.hasPrefix("?") || inner.hasPrefix("/!") {
                // Processing instruction / bogus comment — ignored entirely.
            } else if inner.hasPrefix("/") {
                flushText()
                let name = rawTagName(String(inner.dropFirst()))
                if !name.isEmpty { tokens.append(.endTag(name: name)) }
            } else {
                flushText()
                let (name, attributes, selfClosing) = parseStartTag(inner)
                guard !name.isEmpty else {
                    index = html.index(after: close)
                    continue
                }
                tokens.append(.startTag(name: name, attributes: attributes, selfClosing: selfClosing || voidElements.contains(name)))
                // Raw-text elements swallow everything up to their closing tag.
                // The end tag is re-emitted so the DOM builder keeps its stack
                // balanced — otherwise every later element would nest inside the
                // <script> we just skipped.
                if rawTextElements.contains(name) && !selfClosing {
                    if let (raw, nextIndex) = consumeRawText(html, after: close, element: name) {
                        if name == "title" { tokens.append(.text(raw)) }
                        tokens.append(.endTag(name: name))
                        index = nextIndex
                        continue
                    }
                }
            }
            index = html.index(after: close)
        }
        flushText()
        return tokens
    }

    private static func rawTagName(_ source: String) -> String {
        var name = ""
        for character in source {
            if character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_" {
                name.append(character)
            } else { break }
        }
        return name.lowercased()
    }

    static func findTagEnd(_ html: String, from openIndex: String.Index) -> String.Index? {
        var index = html.index(after: openIndex)
        let end = html.endIndex
        var quote: Character?
        while index < end {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    static func parseStartTag(_ inner: String) -> (name: String, attributes: [String: String], selfClosing: Bool) {
        var source = inner
        var selfClosing = false
        if source.hasSuffix("/") {
            selfClosing = true
            source = String(source.dropLast())
        }
        let name = rawTagName(source)
        var attributes: [String: String] = [:]
        var index = source.index(source.startIndex, offsetBy: name.count)
        let end = source.endIndex
        while index < end {
            while index < end, source[index].isWhitespace { index = source.index(after: index) }
            guard index < end else { break }
            var key = ""
            while index < end, !source[index].isWhitespace, source[index] != "=" {
                key.append(source[index])
                index = source.index(after: index)
            }
            while index < end, source[index].isWhitespace { index = source.index(after: index) }
            var value = ""
            if index < end, source[index] == "=" {
                index = source.index(after: index)
                while index < end, source[index].isWhitespace { index = source.index(after: index) }
                if index < end, source[index] == "\"" || source[index] == "'" {
                    let quote = source[index]
                    index = source.index(after: index)
                    while index < end, source[index] != quote {
                        value.append(source[index])
                        index = source.index(after: index)
                    }
                    if index < end { index = source.index(after: index) }
                } else {
                    while index < end, !source[index].isWhitespace {
                        value.append(source[index])
                        index = source.index(after: index)
                    }
                }
            }
            let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespaces)
            if !normalizedKey.isEmpty {
                attributes[normalizedKey] = HTMLEntities.decode(value)
            }
        }
        return (name, attributes, selfClosing)
    }

    /// Reads raw text up to the matching close tag without interpreting markup.
    static func consumeRawText(_ html: String, after closeIndex: String.Index, element: String) -> (String, String.Index)? {
        var searchStart = html.index(after: closeIndex)
        let needle = "</\(element)"
        while let range = html.range(of: needle, options: [.caseInsensitive], range: searchStart..<html.endIndex) {
            // Make sure it is really the close tag and not `</scriptfoo>`.
            if let tagEnd = findTagEnd(html, from: range.lowerBound) {
                let content = String(html[searchStart..<range.lowerBound])
                return (content, html.index(after: tagEnd))
            }
            searchStart = html.index(after: range.lowerBound)
        }
        return nil
    }
}

// MARK: - Entities

public enum HTMLEntities {

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "middot": "·",
        "lsquo": "'", "rsquo": "'", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½",
        "frac14": "¼", "sup2": "²", "sup3": "³", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "dagger": "†",
        "prime": "′", "Prime": "″", "eacute": "é", "egrave": "è", "agrave": "à",
        "ccedil": "ç", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
        "ntilde": "ñ", "aacute": "á", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "minus": "−", "ne": "≠", "le": "≤", "ge": "≥",
        "infin": "∞", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "harr": "↔", "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦",
        "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "", "zwj": "",
        "check": "✓", "cross": "✗", "star": "★", "phone": "☎", "email": "✉"
    ]

    public static func decode(_ source: String) -> String {
        guard source.contains("&") else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        let end = source.endIndex
        while index < end {
            let character = source[index]
            guard character == "&" else {
                result.append(character)
                index = source.index(after: index)
                continue
            }
            // Look ahead for a terminating ';' within a sane window.
            var cursor = source.index(after: index)
            var body = ""
            var steps = 0
            while cursor < end, steps < 12 {
                let candidate = source[cursor]
                if candidate == ";" { break }
                if candidate == "&" || candidate == " " || candidate == "<" { break }
                body.append(candidate)
                cursor = source.index(after: cursor)
                steps += 1
            }
            if cursor < end, source[cursor] == ";" {
                if let replacement = resolve(body) {
                    result.append(replacement)
                    index = source.index(after: cursor)
                    continue
                }
            }
            result.append(character)
            index = source.index(after: index)
        }
        return result
    }

    private static func resolve(_ body: String) -> String? {
        if body.isEmpty { return nil }
        if body.hasPrefix("#") {
            let numeric = body.dropFirst()
            let value: UInt32?
            if numeric.hasPrefix("x") || numeric.hasPrefix("X") {
                value = UInt32(numeric.dropFirst(), radix: 16)
            } else {
                value = UInt32(numeric)
            }
            guard let scalarValue = value, let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return String(Character(scalar))
        }
        if let direct = named[body] { return direct }
        // Case-insensitive fallback for the many pages that shout entity names.
        if let direct = named[body.lowercased()] { return direct }
        return nil
    }
}

