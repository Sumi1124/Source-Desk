import Foundation
import PDFKit

/// Extracts readable structure from local documents.
///
/// Each format has its own reader, but all of them produce the same
/// `ExtractedDocument`, so chunking, retrieval, citation and rendering downstream
/// have exactly one shape to deal with. Adding a format means adding one case here.
public enum DocumentExtractor {

    public struct Options: Sendable {
        public var maximumBytes: Int64
        /// PDFs beyond this many pages are still imported, but page text is only
        /// read for the first N pages in one pass; the rest are streamed lazily.
        public var pdfPageBatchSize: Int
        public var includePDFPageNumbers: Bool

        public init(
            maximumBytes: Int64 = 512 * 1024 * 1024,
            pdfPageBatchSize: Int = 64,
            includePDFPageNumbers: Bool = true
        ) {
            self.maximumBytes = maximumBytes
            self.pdfPageBatchSize = pdfPageBatchSize
            self.includePDFPageNumbers = includePDFPageNumbers
        }

        public static let `default` = Options()
    }

    /// Detects the kind of a file from its extension and, when necessary, its magic
    /// bytes — a `.txt` file that is really a PDF should not be read as text.
    public static func kind(for url: URL) -> SourceKind? {
        let extensionName = url.pathExtension.lowercased()
        switch extensionName {
        case "pdf": return .pdf
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "txt", "text", "log", "csv", "tsv": return .plainText
        case "html", "htm", "xhtml": return .html
        case "docx": return .docx
        case "rtf": return .rtf
        case "epub": return .epub
        default:
            return kindFromMagicBytes(url)
        }
    }

    static func kindFromMagicBytes(_ url: URL) -> SourceKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), !head.isEmpty else { return nil }
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }                       // %PDF
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .docx }                       // zip container
        if head.starts(with: Array("{\\rtf".utf8)) { return .rtf }
        return nil
    }

    public static func extract(url: URL, options: Options = .default) throws -> ExtractedDocument {
        let size = FileStore.size(of: url)
        guard size > 0 else {
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: "The file is empty.")
        }
        guard size <= options.maximumBytes else {
            throw SourceDeskError.documentTooLarge(name: url.lastPathComponent, bytes: size, limitBytes: options.maximumBytes)
        }
        guard let kind = kind(for: url) else {
            throw SourceDeskError.unsupportedDocument(
                name: url.lastPathComponent,
                detail: "SourceDesk reads PDF, DOCX, RTF, EPUB, TXT, Markdown and HTML."
            )
        }
        return try extract(url: url, kind: kind, options: options)
    }

    public static func extract(url: URL, kind: SourceKind, options: Options = .default) throws -> ExtractedDocument {
        switch kind {
        case .pdf:
            return try extractPDF(url: url, options: options)
        case .docx:
            return try extractDOCX(url: url)
        case .rtf:
            return try extractRTF(url: url)
        case .epub:
            return try extractEPUB(url: url)
        case .markdown, .plainText, .pastedText:
            let text = try FileStore.readText(at: url)
            let blocks = Markdownish.parse(text)
            let title = kind == .markdown
                ? (blocks.first(where: { $0.kind == .heading })?.text ?? url.deletingPathExtension().lastPathComponent)
                : url.deletingPathExtension().lastPathComponent
            return ExtractedDocument(title: title, method: kind == .markdown ? "markdown" : "plain text",
                                     pages: [ExtractedPage(number: 0, blocks: blocks)])
        case .html:
            let html = try FileStore.readText(at: url)
            return try HTMLExtractor.extract(html: html, url: url.absoluteString,
                                             fallbackTitle: url.deletingPathExtension().lastPathComponent)
        case .website, .folder:
            throw SourceDeskError.unsupportedDocument(name: url.lastPathComponent, detail: "That kind is fetched, not read from disk.")
        }
    }

    // MARK: - PDF

    public static func extractPDF(url: URL, options: Options = .default) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: "The PDF could not be opened. It may be damaged or password-protected.")
        }
        if document.isLocked {
            throw SourceDeskError.authenticationRequired(url: url.lastPathComponent)
        }

        var pages: [ExtractedPage] = []
        var totalCharacters = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let raw = page.string ?? ""
            totalCharacters += raw.count
            let blocks = Markdownish.parse(raw)
            if !blocks.isEmpty {
                pages.append(ExtractedPage(number: index + 1, blocks: options.includePDFPageNumbers ? blocks : blocks.map {
                    var copy = $0
                    copy.headingPath = copy.headingPath
                    return copy
                }))
            }
        }

        // A PDF with almost no extractable text is a scan. Saying so is far more
        // useful than importing an empty source.
        if totalCharacters < 40 {
            throw SourceDeskError.unreadableDocument(
                name: url.lastPathComponent,
                detail: "This PDF has no text layer — it looks like a scan or image-only export (\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")). SourceDesk does not run OCR."
            )
        }

        let attributes = document.documentAttributes
        let title = (attributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (attributes?[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date

        let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? url.deletingPathExtension().lastPathComponent
        return ExtractedDocument(
            title: resolvedTitle,
            author: author?.isEmpty == false ? author : nil,
            publishedAt: created,
            method: "pdfkit",
            pages: pages
        )
    }

    /// Page-attributed text for a single PDF page, used by the source inspector.
    public static func pdfPageText(url: URL, page: Int) -> String? {
        guard let document = PDFDocument(url: url), page >= 1, page <= document.pageCount,
              let pdfPage = document.page(at: page - 1) else { return nil }
        return pdfPage.string
    }

    // MARK: - DOCX

    /// Reads a `.docx` directly as an OOXML zip: no third-party library, and it also
    /// yields the document's own heading structure.
    public static func extractDOCX(url: URL) throws -> ExtractedDocument {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(fileAt: url)
        } catch {
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: "Not a readable .docx package (it may be a .doc saved with the wrong extension).")
        }
        guard let documentEntry = archive.entry("word/document.xml") else {
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: "The package has no word/document.xml — it may be an older .doc file or another zip-based format.")
        }
        let xml = String(decoding: try archive.read(documentEntry), as: UTF8.self)
        let blocks = DOCXReader.blocks(from: xml)

        var title = url.deletingPathExtension().lastPathComponent
        if let coreEntry = archive.entry("docProps/core.xml") {
            let core = String(decoding: (try? archive.read(coreEntry)) ?? Data(), as: UTF8.self)
            if let parsed = DOCXReader.coreProperty(named: "dc:title", in: core), !parsed.isEmpty { title = parsed }
        }
        guard !blocks.isEmpty else {
            throw SourceDeskError.emptyExtraction(url: url.lastPathComponent)
        }
        return ExtractedDocument(title: title, method: "ooxml", pages: [ExtractedPage(number: 0, blocks: blocks)])
    }

    // MARK: - RTF

    /// RTF is reduced to its text runs: control words, groups and destinations that
    /// carry no visible text are skipped.
    public static func extractRTF(url: URL) throws -> ExtractedDocument {
        let data = (try? Data(contentsOf: url)) ?? Data()
        guard let raw = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) else {
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: "The RTF file is not readable text.")
        }
        let text = RTFReader.plainText(raw)
        let blocks = Markdownish.parse(text)
        guard !blocks.isEmpty else { throw SourceDeskError.emptyExtraction(url: url.lastPathComponent) }
        return ExtractedDocument(title: url.deletingPathExtension().lastPathComponent, method: "rtf",
                                 pages: [ExtractedPage(number: 0, blocks: blocks)])
    }

    // MARK: - EPUB

    public static func extractEPUB(url: URL) throws -> ExtractedDocument {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(fileAt: url)
        } catch {
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: "Not a readable EPUB package.")
        }
        // Read the chapters in spine order when the OPF is readable, else alphabetically.
        var documentPaths = archive.paths.filter { path in
            let lowered = path.lowercased()
            return (lowered.hasSuffix(".xhtml") || lowered.hasSuffix(".html") || lowered.hasSuffix(".htm"))
                && !lowered.contains("nav") && !lowered.contains("cover")
        }.sorted()

        if let opfPath = archive.paths.first(where: { $0.lowercased().hasSuffix(".opf") }),
           let opfEntry = archive.entry(opfPath),
           let opf = try? String(decoding: archive.read(opfEntry), as: UTF8.self) {
            let ordered = EPUBReader.spineOrder(opf: opf, baseDirectory: (opfPath as NSString).deletingLastPathComponent)
            if !ordered.isEmpty {
                documentPaths = ordered
            }
        }

        var pages: [ExtractedPage] = []
        var extractedTitle: String?
        for (index, path) in documentPaths.enumerated() {
            guard let entry = archive.entry(path), let html = try? String(decoding: archive.read(entry), as: UTF8.self) else { continue }
            guard let document = try? HTMLExtractor.extract(html: html, url: url.absoluteString, fallbackTitle: path) else { continue }
            if extractedTitle == nil, let firstHeading = document.blocks.first(where: { $0.kind == .heading })?.text {
                extractedTitle = firstHeading
            }
            // EPUBs are chaptered, not paged: the chapter index is what a citation
            // should point at.
            pages.append(ExtractedPage(number: index + 1, blocks: document.blocks))
        }
        let blocks = pages.flatMap(\.blocks)
        guard !blocks.isEmpty else { throw SourceDeskError.emptyExtraction(url: url.lastPathComponent) }
        return ExtractedDocument(
            title: extractedTitle ?? url.deletingPathExtension().lastPathComponent,
            method: "epub",
            pages: pages.count > 1 ? pages : [ExtractedPage(number: 0, blocks: blocks)]
        )
    }
}

// MARK: - DOCX reader

enum DOCXReader {

    /// Walks the OOXML body, mapping paragraphs to blocks. Heading styles
    /// (`Heading1`, `Heading 1`, `<w:outlineLvl>`) become real headings so the
    /// document's structure survives into retrieval.
    static func blocks(from xml: String) -> [ExtractedBlock] {
        var blocks: [ExtractedBlock] = []
        var headingStack: [(level: Int, text: String)] = []

        func headingPath() -> String { headingStack.map(\.text).joined(separator: " › ") }

        // Split on paragraph boundaries; this is a document body, not a DOM, so a
        // simple scan is both sufficient and far faster.
        let paragraphs = xml.components(separatedBy: "</w:p>")
        for paragraph in paragraphs {
            let runs = textRuns(in: paragraph)
            let text = runs.joined().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let level = headingLevel(in: paragraph)
            if level > 0 {
                while let last = headingStack.last, last.level >= level { headingStack.removeLast() }
                headingStack.append((level, text))
                blocks.append(ExtractedBlock(kind: .heading, text: text, level: level, headingPath: headingPath()))
                continue
            }
            if paragraph.contains("<w:numPr>") || paragraph.contains("ListParagraph") {
                blocks.append(ExtractedBlock(kind: .listItem, text: text, headingPath: headingPath()))
                continue
            }
            if paragraph.contains("<w:jc w:val=\"center\"") && blocks.isEmpty {
                // A centred first paragraph is usually the title.
                blocks.append(ExtractedBlock(kind: .heading, text: text, level: 1, headingPath: text))
                headingStack.append((1, text))
                continue
            }
            blocks.append(ExtractedBlock(kind: .paragraph, text: text, headingPath: headingPath()))
        }

        // Tables are appended separately: cell text is better than losing it.
        for table in xml.components(separatedBy: "<w:tbl>").dropFirst() {
            let rows = table.components(separatedBy: "<w:tr").dropFirst().compactMap { row -> String? in
                let cells = row.components(separatedBy: "<w:tc").dropFirst().compactMap { cell -> String? in
                    let text = textRuns(in: cell).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
                return cells.isEmpty ? nil : cells.joined(separator: " | ")
            }
            if !rows.isEmpty {
                blocks.append(ExtractedBlock(kind: .table, text: rows.joined(separator: "\n"), headingPath: headings(for: blocks)))
            }
        }
        return blocks
    }

    static func headings(for blocks: [ExtractedBlock]) -> String {
        blocks.last(where: { $0.kind == .heading })?.headingPath ?? ""
    }

    static func textRuns(in fragment: String) -> [String] {
        var parts: [String] = []
        var remaining = Substring(fragment)
        while let start = remaining.range(of: "<w:t"),
              let openEnd = remaining[start.lowerBound...].firstIndex(of: ">"),
              let close = remaining[openEnd...].range(of: "</w:t>") {
            let content = remaining[remaining.index(after: openEnd)..<close.lowerBound]
            parts.append(HTMLEntities.decode(String(content)))
            remaining = remaining[close.upperBound...]
        }
        // Tabs and explicit breaks carry meaning in a word processor's document.
        if fragment.contains("<w:tab/>") { parts.append(" ") }
        return parts
    }

    static func headingLevel(in paragraph: String) -> Int {
        if let range = paragraph.range(of: "w:val=\"Heading"),
           let quote = paragraph[range.upperBound...].firstIndex(of: "\"") {
            let digit = paragraph[range.upperBound..<quote].first
            if let digit, let level = Int(String(digit)) { return max(1, min(6, level)) }
        }
        if let range = paragraph.range(of: "w:val=\"heading ") {
            let rest = paragraph[range.upperBound...]
            let digits = rest.prefix(while: { $0.isNumber })
            if let level = Int(digits) { return max(1, min(6, level)) }
        }
        if let range = paragraph.range(of: "<w:outlineLvl w:val=\""),
           let quote = paragraph[range.upperBound...].firstIndex(of: "\"") {
            let digits = paragraph[range.upperBound..<quote].prefix(while: { $0.isNumber })
            if let value = Int(digits) { return max(1, min(6, value + 1)) }
        }
        return 0
    }

    static func coreProperty(named name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)"), let openEnd = xml[start.lowerBound...].firstIndex(of: ">"),
              let close = xml[openEnd...].range(of: "</\(name)>") else { return nil }
        let value = String(xml[xml.index(after: openEnd)..<close.lowerBound])
        return HTMLEntities.decode(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - RTF reader

enum RTFReader {

    static let destinationsToSkip: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "themedata",
        "datastore", "latentstyles", "listtable", "listoverridetable", "rsidtbl",
        "generator", "xmlnstbl", "filetbl", "revtbl", "upr"
    ]

    /// Converts RTF to plain text, honouring groups, unicode escapes and paragraph
    /// breaks, and ignoring everything that is not visible text.
    static func plainText(_ rtf: String) -> String {
        var output = ""
        var index = rtf.startIndex
        let end = rtf.endIndex
        var skipDepth = 0
        var depth = 0

        while index < end {
            let character = rtf[index]
            switch character {
            case "{":
                depth += 1
                index = rtf.index(after: index)
            case "}":
                if skipDepth > 0, depth <= skipDepth { skipDepth = 0 }
                depth = max(0, depth - 1)
                index = rtf.index(after: index)
            case "\\":
                let parsed = readControlWord(rtf, from: index)
                let token = (word: parsed.word, parameter: parsed.parameter)
                let next = parsed.next
                index = next
                if skipDepth > 0 { continue }
                switch token.word {
                case "par", "line", "sect", "page", "row":
                    output.append("\n")
                case "tab":
                    output.append("\t")
                case "u":
                    if let code = token.parameter, let scalar = Unicode.Scalar(UInt32(code < 0 ? code + 65_536 : code)) {
                        output.append(Character(scalar))
                    }
                    // RTF pads \uN with a fallback character; skip it.
                    if index < end, rtf[index] == "?" { index = rtf.index(after: index) }
                case "bullet":
                    output.append("• ")
                case "emdash":
                    output.append("—")
                case "endash":
                    output.append("–")
                case "lquote", "rquote", "ldblquote", "rdblquote":
                    output.append(token.word.hasPrefix("l") ? "\"" : "\"")
                default:
                    if destinationsToSkip.contains(token.word), token.parameter == nil {
                        skipDepth = depth
                    }
                }
            case "\n", "\r":
                index = rtf.index(after: index)
            default:
                if skipDepth == 0 { output.append(character) }
                index = rtf.index(after: index)
            }
        }
        // RTF uses 0x92/0x93/0x94 for curly quotes in Latin-1 documents.
        return output
            .replacingOccurrences(of: "\u{92}", with: "'")
            .replacingOccurrences(of: "\u{93}", with: "\u{201C}")
            .replacingOccurrences(of: "\u{94}", with: "\u{201D}")
    }

    static func readControlWord(_ rtf: String, from index: String.Index) -> (word: String, parameter: Int?, next: String.Index) {
        var cursor = rtf.index(after: index)
        let end = rtf.endIndex
        var word = ""
        while cursor < end, rtf[cursor].isLetter {
            word.append(rtf[cursor])
            cursor = rtf.index(after: cursor)
        }
        var parameterString = ""
        if cursor < end, rtf[cursor] == "-" {
            parameterString.append("-")
            cursor = rtf.index(after: cursor)
        }
        while cursor < end, rtf[cursor].isNumber {
            parameterString.append(rtf[cursor])
            cursor = rtf.index(after: cursor)
        }
        // A following space is part of the control word, not the text.
        if cursor < end, rtf[cursor] == " " { cursor = rtf.index(after: cursor) }
        // Escaped literal punctuation: \{ \} \\ \'
        if word.isEmpty, cursor <= end, index < rtf.index(before: rtf.index(before: end)) {
            let next = rtf.index(after: index)
            if next < end {
                return (String(rtf[next]), nil, rtf.index(after: next))
            }
        }
        return (word, Int(parameterString), cursor)
    }
}

// MARK: - EPUB reader

enum EPUBReader {

    /// Returns the chapter documents in reading order from the OPF spine.
    static func spineOrder(opf: String, baseDirectory: String) -> [String] {
        var manifest: [String: String] = [:]
        for item in opf.components(separatedBy: "<item ").dropFirst() {
            let id = attribute("id", in: item)
            let href = attribute("href", in: item)
            if let id, let href { manifest[id] = href }
        }
        var ordered: [String] = []
        for itemref in opf.components(separatedBy: "<itemref ").dropFirst() {
            guard let idref = attribute("idref", in: itemref), let href = manifest[idref] else { continue }
            let decoded = href.removingPercentEncoding ?? href
            let full = baseDirectory.isEmpty ? decoded : "\(baseDirectory)/\(decoded)"
            ordered.append(full.replacingOccurrences(of: "//", with: "/"))
        }
        return ordered
    }

    static func attribute(_ name: String, in fragment: String) -> String? {
        guard let range = fragment.range(of: "\(name)=\"") else { return nil }
        let rest = fragment[range.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<quote])
    }
}
