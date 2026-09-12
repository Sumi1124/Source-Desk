import Foundation

/// Splits an extracted document into retrievable chunks.
///
/// Two properties matter for answer quality more than anything else here:
///
/// 1. **Heading and page provenance are preserved.** A chunk knows which section it
///    came from and which page of a PDF it was on, because that is what makes a
///    citation useful rather than decorative.
/// 2. **Chunks break on sentence boundaries**, with a configurable overlap, so a
///    retrieved chunk reads as prose instead of starting mid-clause.
public enum TextChunker {

    public struct Configuration: Sendable {
        /// Target chunk size in estimated tokens.
        public var targetTokens: Int
        /// Maximum size before a hard split, even mid-sentence.
        public var maximumTokens: Int
        /// Tokens repeated from the previous chunk to preserve context across seams.
        public var overlapTokens: Int
        /// Chunks smaller than this are merged into their neighbour.
        public var minimumTokens: Int
        /// Chunks below this many characters are dropped as noise.
        public var minimumCharacters: Int
        /// Headings are prepended to each chunk so the model sees section context.
        public var includeHeadingContext: Bool

        public init(
            targetTokens: Int = 320,
            maximumTokens: Int = 480,
            overlapTokens: Int = 60,
            minimumTokens: Int = 24,
            minimumCharacters: Int = 40,
            includeHeadingContext: Bool = true
        ) {
            self.targetTokens = targetTokens
            self.maximumTokens = maximumTokens
            self.overlapTokens = overlapTokens
            self.minimumTokens = minimumTokens
            self.minimumCharacters = minimumCharacters
            self.includeHeadingContext = includeHeadingContext
        }

        public static let `default` = Configuration()

        /// Small chunks suit precise retrieval; large chunks suit narrative answers.
        public static let precise = Configuration(targetTokens: 220, maximumTokens: 340, overlapTokens: 40)
        public static let broad = Configuration(targetTokens: 520, maximumTokens: 780, overlapTokens: 110)

        public func validated() -> Configuration {
            var copy = self
            copy.targetTokens = max(64, min(4_000, targetTokens))
            copy.maximumTokens = max(copy.targetTokens, min(8_000, maximumTokens))
            copy.overlapTokens = max(0, min(copy.targetTokens / 2, overlapTokens))
            copy.minimumTokens = max(4, min(copy.targetTokens / 2, minimumTokens))
            return copy
        }
    }

    /// Splits a document, returning chunks in reading order.
    public static func chunk(
        document: ExtractedDocument,
        sourceID: RecordID,
        notebookID: RecordID,
        configuration rawConfiguration: Configuration = .default
    ) -> [SourceChunk] {
        let configuration = rawConfiguration.validated()
        var builder = Builder(configuration: configuration, sourceID: sourceID, notebookID: notebookID)
        for page in document.pages {
            builder.append(page: page)
        }
        return builder.finish()
    }

    /// Convenience for plain text with no structure (pasted text, TXT files).
    public static func chunk(
        plainText: String,
        sourceID: RecordID,
        notebookID: RecordID,
        configuration: Configuration = .default
    ) -> [SourceChunk] {
        let blocks = Markdownish.parse(plainText)
        let document = ExtractedDocument(
            title: "Text",
            method: "plain-text",
            pages: [ExtractedPage(number: 0, blocks: blocks)]
        )
        return chunk(document: document, sourceID: sourceID, notebookID: notebookID, configuration: configuration)
    }

    // MARK: - Builder

    private struct Pending {
        var text: String
        var headingPath: String
        var pageNumber: Int
    }

    private struct Builder {
        let configuration: Configuration
        let sourceID: RecordID
        let notebookID: RecordID

        var chunks: [SourceChunk] = []
        var ordinal = 0
        var pendingText = ""
        var pendingHeading = ""
        var pendingPage = 0
        var pendingOffset = 0
        var runningOffset = 0
        /// Sentences carried over as overlap into the next chunk.
        var overlapCarry: [String] = []

        init(configuration: Configuration, sourceID: RecordID, notebookID: RecordID) {
            self.configuration = configuration
            self.sourceID = sourceID
            self.notebookID = notebookID
        }

        mutating func append(page: ExtractedPage) {
            for block in page.blocks {
                switch block.kind {
                case .heading:
                    flush(reason: .headingChange)
                    pendingHeading = block.headingPath
                    pendingPage = page.number
                case .table, .code:
                    // Tables and code are kept whole: splitting them destroys meaning.
                    flush(reason: .blockBoundary)
                    let whole = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if whole.count >= configuration.minimumCharacters {
                        emit(text: whole, heading: block.headingPath, page: page.number)
                    }
                default:
                    let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if page.number != pendingPage && !pendingText.isEmpty {
                        flush(reason: .pageChange)
                    }
                    pendingPage = page.number
                    let headingPath = block.headingPath.isEmpty ? pendingHeading : block.headingPath
                    appendProse(text: text, heading: headingPath, page: page.number)
                }
            }
        }

        mutating func finish() -> [SourceChunk] {
            flush(reason: .end)
            // Merge any undersized stragglers into the previous chunk when they
            // share a heading — a two-line orphan chunk retrieves poorly.
            var merged: [SourceChunk] = []
            for chunk in chunks {
                if var last = merged.last,
                   chunk.tokenCount < configuration.minimumTokens,
                   last.headingPath == chunk.headingPath,
                   last.pageNumber == chunk.pageNumber,
                   last.tokenCount + chunk.tokenCount <= configuration.maximumTokens {
                    last.text += "\n" + chunk.text
                    last.charCount = last.text.count
                    last.tokenCount = TextMath.estimatedTokens(for: last.text)
                    last.endOffset = chunk.endOffset
                    merged[merged.count - 1] = last
                } else {
                    merged.append(chunk)
                }
            }
            // Re-number after merging so ordinals stay contiguous.
            for index in merged.indices { merged[index].ordinal = index }
            return merged
        }

        private enum FlushReason { case size, headingChange, pageChange, blockBoundary, end }

        private mutating func appendProse(text: String, heading: String, page: Int) {
            let sentences = SentenceSplitter.split(text)
            for sentence in sentences {
                let candidateTokens = TextMath.estimatedTokens(for: pendingText + " " + sentence.text)
                if candidateTokens > configuration.maximumTokens && !pendingText.isEmpty {
                    flush(reason: .size)
                }
                if !pendingText.isEmpty && heading != pendingHeading {
                    flush(reason: .headingChange)
                }
                if pendingText.isEmpty {
                    pendingHeading = heading
                    pendingPage = page
                    pendingOffset = sentence.offset
                    // Restore overlap carried from the previous chunk.
                    if !overlapCarry.isEmpty {
                        pendingText = overlapCarry.joined(separator: " ")
                    }
                }
                pendingText += (pendingText.isEmpty ? "" : " ") + sentence.text
            }
        }

        private mutating func flush(reason: FlushReason) {
            let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText = ""
            // Overlap is recomputed below for the reasons that continue a document;
            // for every other reason it must not carry across the seam.
            overlapCarry = []
            guard text.count >= configuration.minimumCharacters || (reason != .size && text.count > 0) else { return }
            guard !text.isEmpty else { return }
            emit(text: text, heading: pendingHeading, page: pendingPage)

            // Prepare overlap for the next chunk.
            if configuration.overlapTokens > 0, reason == .size || reason == .pageChange {
                overlapCarry = tailSentences(of: text, tokenBudget: configuration.overlapTokens)
            }
        }

        private func tailSentences(of text: String, tokenBudget: Int) -> [String] {
            let sentences = SentenceSplitter.split(text).map(\.text)
            var chosen: [String] = []
            var tokens = 0
            for sentence in sentences.reversed() {
                let cost = TextMath.estimatedTokens(for: sentence)
                if tokens + cost > tokenBudget && !chosen.isEmpty { break }
                chosen.insert(sentence, at: 0)
                tokens += cost
            }
            return chosen
        }

        private mutating func emit(text: String, heading: String, page: Int) {
            var body = text
            if configuration.includeHeadingContext, !heading.isEmpty {
                body = heading + "\n" + text
            }
            let chunk = SourceChunk(
                sourceID: sourceID,
                notebookID: notebookID,
                ordinal: ordinal,
                text: body,
                headingPath: heading.isEmpty ? nil : heading,
                pageNumber: page > 0 ? page : nil,
                startOffset: pendingOffset,
                endOffset: pendingOffset + text.count,
                charCount: body.count,
                tokenCount: TextMath.estimatedTokens(for: body)
            )
            ordinal += 1
            runningOffset = chunk.endOffset
            chunks.append(chunk)
        }
    }
}

// MARK: - Sentence splitting

public enum SentenceSplitter {

    public struct Sentence {
        public var text: String
        public var offset: Int
    }

    /// Abbreviations that must not end a sentence. Without these, "Dr. Smith" and
    /// "e.g. this" produce fragments that read badly in citations.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie",
        "fig", "figs", "no", "vol", "pp", "ed", "eds", "al", "approx", "dept",
        "inc", "ltd", "co", "corp", "univ", "govt", "jan", "feb", "mar", "apr",
        "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "min", "max"
    ]

    public static func split(_ text: String) -> [Sentence] {
        var sentences: [Sentence] = []
        var current = ""
        var sentenceStart = 0
        var offset = 0
        let characters = Array(text)
        var index = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(Sentence(text: trimmed, offset: sentenceStart)) }
            current = ""
            sentenceStart = offset
        }

        while index < characters.count {
            let character = characters[index]
            current.append(character)
            offset += 1

            let isTerminator = character == "." || character == "!" || character == "?"
                || character == "。" || character == "！" || character == "？"
            guard isTerminator else {
                if current.count == 1 { sentenceStart = offset - 1 }
                index += 1
                continue
            }

            if character == "." {
                // Decimal numbers, ellipses and known abbreviations continue.
                let previous = index > 0 ? characters[index - 1] : " "
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if previous.isNumber && next.isNumber { index += 1; continue }
                if next == "." { index += 1; continue }
                let word = trailingWord(current)
                if abbreviations.contains(word.lowercased()) { index += 1; continue }
                // A single capital letter is an initial: "J. Smith".
                if word.count == 1, let first = word.first, first.isUppercase { index += 1; continue }
            }

            // Consume following closing quotes/brackets, then require whitespace.
            var lookahead = index + 1
            while lookahead < characters.count,
                  ["\"", "'", "”", "’", ")", "]", "】", "」"].contains(characters[lookahead]) {
                current.append(characters[lookahead])
                offset += 1
                lookahead += 1
                index += 1
            }
            if lookahead >= characters.count || characters[lookahead].isWhitespace || characters[lookahead].isNewline {
                flush()
                index = lookahead
                // Skip the whitespace so the next sentence starts cleanly.
                while index < characters.count, characters[index].isWhitespace {
                    offset += 1
                    index += 1
                }
                sentenceStart = offset
                continue
            }
            index += 1
        }
        flush()
        return sentences
    }

    private static func trailingWord(_ text: String) -> String {
        var word = ""
        for character in text.reversed() {
            if character.isLetter || character.isNumber { word.insert(character, at: word.startIndex) }
            else if character == "." { continue }
            else { break }
        }
        return word
    }
}

// MARK: - Markdown-ish parsing (for TXT and MD sources)

public enum Markdownish {

    /// Parses Markdown or plain text into the same block model the HTML extractor
    /// produces, so chunking, retrieval and rendering have exactly one path.
    public static func parse(_ text: String) -> [ExtractedBlock] {
        var blocks: [ExtractedBlock] = []
        var headingStack: [(level: Int, text: String)] = []
        var paragraph: [String] = []
        var listRun: [String] = []
        var inCode = false
        var codeLines: [String] = []
        var tableRun: [String] = []

        func headingPath() -> String { headingStack.map(\.text).joined(separator: " › ") }

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard joined.count >= 2 else { return }
            blocks.append(ExtractedBlock(kind: .paragraph, text: joined, headingPath: headingPath()))
        }

        func flushList() {
            for item in listRun {
                let cleaned = item.trimmingCharacters(in: .whitespaces)
                if cleaned.count >= 2 {
                    blocks.append(ExtractedBlock(kind: .listItem, text: cleaned, headingPath: headingPath()))
                }
            }
            listRun = []
        }

        func flushTable() {
            guard tableRun.count >= 2 else { tableRun = []; return }
            let rows = tableRun
                .filter { !$0.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).replacingOccurrences(of: " | ", with: " | ") }
            if !rows.isEmpty {
                blocks.append(ExtractedBlock(kind: .table, text: rows.joined(separator: "\n"), headingPath: headingPath()))
            }
            tableRun = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    let code = codeLines.joined(separator: "\n")
                    if code.count > 8 { blocks.append(ExtractedBlock(kind: .code, text: code, headingPath: headingPath())) }
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph(); flushList(); flushTable()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph(); flushList(); flushTable()
                continue
            }

            // Heading: ATX, or underlined with === / ---.
            if let heading = parseATXHeading(trimmed) {
                flushParagraph(); flushList(); flushTable()
                while let last = headingStack.last, last.level >= heading.level { headingStack.removeLast() }
                headingStack.append((heading.level, heading.text))
                blocks.append(ExtractedBlock(kind: .heading, text: heading.text, level: heading.level, headingPath: headingPath()))
                continue
            }

            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 2 {
                flushParagraph(); flushList()
                tableRun.append(trimmed)
                continue
            }
            if !tableRun.isEmpty { flushTable() }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                let quote = trimmed.drop(while: { $0 == ">" }).trimmingCharacters(in: .whitespaces)
                if quote.count >= 2 { blocks.append(ExtractedBlock(kind: .quote, text: quote, headingPath: headingPath())) }
                continue
            }

            if let item = parseListItem(trimmed) {
                flushParagraph()
                listRun.append(item)
                continue
            }
            if !listRun.isEmpty { flushList() }

            paragraph.append(stripInlineMarkup(trimmed))
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(ExtractedBlock(kind: .code, text: codeLines.joined(separator: "\n"), headingPath: headingPath()))
        }
        flushParagraph(); flushList(); flushTable()
        return blocks
    }

    static func parseATXHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[index...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return text.isEmpty ? nil : (level, stripInlineMarkup(text))
    }

    static func parseListItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : stripInlineMarkup(text)
        }
        // Ordered lists: "1. ", "12) "
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
            if digits.count > 3 { return nil }
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
        let rest = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : stripInlineMarkup(rest)
    }

    /// Removes emphasis, link syntax and code ticks while keeping the words, so
    /// embedded text contains no markup noise.
    public static func stripInlineMarkup(_ text: String) -> String {
        var result = text
        // [label](url) -> label (url)
        result = result.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\(([^)]*)\\)",
            with: "$1 ($2)",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "[*_]{1,3}([^*_]+)[*_]{1,3}", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "~~([^~]+)~~", with: "$1", options: .regularExpression)
        return result
    }
}
