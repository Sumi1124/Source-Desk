import Foundation

// MARK: - Identifiers

/// All persisted entities use string identifiers so exports stay portable and
/// human-readable, and so rows can be referenced across tables without pulling in
/// a database-specific key type.
public typealias RecordID = String

/// Identifier factory. Deliberately *not* named `ID`: inside a type that conforms
/// to `Identifiable`, `ID` resolves to the associated type (`String`), which would
/// shadow it.
public enum Identifiers {
    public static func new() -> RecordID { UUID().uuidString.lowercased() }
}

// MARK: - Source taxonomy

/// The kinds of material SourceDesk can ingest. The set is intentionally open:
/// `Sources.KindRegistry` maps each kind to an extractor, so supporting a new
/// document type means registering one more extractor rather than editing the UI.
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case website
    case pdf
    case plainText
    case markdown
    case html
    case docx
    case rtf
    case epub
    case pastedText
    case folder

    public var displayName: String {
        switch self {
        case .website: return L("Website")
        case .pdf: return L("PDF")
        case .plainText: return L("Text")
        case .markdown: return L("Markdown")
        case .html: return L("HTML")
        case .docx: return L("Word")
        case .rtf: return L("Rich Text")
        case .epub: return L("EPUB")
        case .pastedText: return L("Pasted Text")
        case .folder: return L("Folder")
        }
    }

    public var symbolName: String {
        switch self {
        case .website: return "globe"
        case .pdf: return "doc.richtext"
        case .plainText: return "doc.text"
        case .markdown: return "text.alignleft"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .docx: return "doc.fill"
        case .rtf: return "doc.plaintext"
        case .epub: return "book"
        case .pastedText: return "doc.on.clipboard"
        case .folder: return "folder"
        }
    }

    /// Website-backed kinds can be re-fetched; the rest are local files or text.
    public var isRemote: Bool { self == .website }

    public var isTextual: Bool {
        switch self {
        case .plainText, .markdown, .pastedText, .html: return true
        default: return false
        }
    }
}

/// Lifecycle of a source as it moves through the ingestion pipeline.
public enum SourceStatus: String, Codable, Sendable {
    case queued
    case fetching
    case extracting
    case chunking
    case embedding
    case ready
    case partial
    case failed
    case cancelled

    public var isBusy: Bool {
        switch self {
        case .queued, .fetching, .extracting, .chunking, .embedding: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return L("Queued")
        case .fetching: return L("Downloading")
        case .extracting: return L("Extracting")
        case .chunking: return L("Chunking")
        case .embedding: return L("Embedding")
        case .ready: return L("Ready")
        case .partial: return L("Partial")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }
}

/// Where a piece of content is allowed to travel. Surfaced in the UI so the user
/// always knows whether something stays on the Mac or leaves it.
public enum PrivacyLevel: String, Codable, Sendable {
    case local
    case cloud
    case web

    public var label: String {
        switch self {
        case .local: return L("Stays on this Mac")
        case .cloud: return L("Sent to your AI provider")
        case .web: return L("Sent to your search provider")
        }
    }

    public var detail: String {
        switch self {
        case .local: return L("Your source stays on this Mac.")
        case .cloud: return L("This source content may be sent to the selected AI provider.")
        case .web: return L("This query is sent to the selected search provider.")
        }
    }
}

// MARK: - Notebook

public struct Notebook: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var title: String
    public var summary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?
    public var isFavorite: Bool
    public var isArchived: Bool
    public var defaultScope: AnswerScope
    public var accentIndex: Int

    public init(
        id: RecordID = Identifiers.new(),
        title: String,
        summary: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        defaultScope: AnswerScope = .notebookSources,
        accentIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.defaultScope = defaultScope
        self.accentIndex = accentIndex
    }
}

// MARK: - Source

public struct Source: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var notebookID: RecordID
    public var kind: SourceKind
    public var title: String
    public var url: String?
    public var filePath: String?
    public var contentPath: String?
    public var siteName: String?
    public var author: String?
    public var mimeType: String?
    public var plainTextBytes: Int64
    public var originalBytes: Int64
    public var wordCount: Int
    public var pageCount: Int?
    public var chunkCount: Int
    public var status: SourceStatus
    public var statusDetail: String?
    public var errorMessage: String?
    public var errorRecovery: String?
    public var addedAt: Date
    public var updatedAt: Date
    public var publishedAt: Date?
    public var fetchedAt: Date?
    public var checksum: String
    public var tags: [String]
    public var notes: String
    public var extractionMethod: String?
    public var fetchMilliseconds: Int?
    public var includeInRetrieval: Bool

    public init(
        id: RecordID = Identifiers.new(),
        notebookID: RecordID,
        kind: SourceKind,
        title: String,
        url: String? = nil,
        filePath: String? = nil,
        contentPath: String? = nil,
        siteName: String? = nil,
        author: String? = nil,
        mimeType: String? = nil,
        plainTextBytes: Int64 = 0,
        originalBytes: Int64 = 0,
        wordCount: Int = 0,
        pageCount: Int? = nil,
        chunkCount: Int = 0,
        status: SourceStatus = .queued,
        statusDetail: String? = nil,
        errorMessage: String? = nil,
        errorRecovery: String? = nil,
        addedAt: Date = Date(),
        updatedAt: Date = Date(),
        publishedAt: Date? = nil,
        fetchedAt: Date? = nil,
        checksum: String = "",
        tags: [String] = [],
        notes: String = "",
        extractionMethod: String? = nil,
        fetchMilliseconds: Int? = nil,
        includeInRetrieval: Bool = true
    ) {
        self.id = id
        self.notebookID = notebookID
        self.kind = kind
        self.title = title
        self.url = url
        self.filePath = filePath
        self.contentPath = contentPath
        self.siteName = siteName
        self.author = author
        self.mimeType = mimeType
        self.plainTextBytes = plainTextBytes
        self.originalBytes = originalBytes
        self.wordCount = wordCount
        self.pageCount = pageCount
        self.chunkCount = chunkCount
        self.status = status
        self.statusDetail = statusDetail
        self.errorMessage = errorMessage
        self.errorRecovery = errorRecovery
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.checksum = checksum
        self.tags = tags
        self.notes = notes
        self.extractionMethod = extractionMethod
        self.fetchMilliseconds = fetchMilliseconds
        self.includeInRetrieval = includeInRetrieval
    }

    /// Where this source's text came from, for the inspector's provenance line.
    public var locationDescription: String {
        if let url, !url.isEmpty { return url }
        if let filePath, !filePath.isEmpty { return (filePath as NSString).lastPathComponent }
        return kind.displayName
    }

    public var displaySubtitle: String {
        var parts: [String] = [kind.displayName]
        if let siteName, !siteName.isEmpty { parts.append(siteName) }
        // Inflected, because a single-page PDF and a one-word snippet are both real and
        // "1 pages" reads as a defect in a list a user scans constantly.
        if let pageCount, pageCount > 0 {
            parts.append("\(pageCount.formatted()) page\(pageCount == 1 ? "" : "s")")
        } else if wordCount > 0 {
            parts.append("\(wordCount.formatted()) word\(wordCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Chunks and embeddings

public struct SourceChunk: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var sourceID: RecordID
    public var notebookID: RecordID
    public var ordinal: Int
    public var text: String
    public var headingPath: String?
    public var pageNumber: Int?
    public var startOffset: Int
    public var endOffset: Int
    public var charCount: Int
    public var tokenCount: Int

    public init(
        id: RecordID = Identifiers.new(),
        sourceID: RecordID,
        notebookID: RecordID,
        ordinal: Int,
        text: String,
        headingPath: String? = nil,
        pageNumber: Int? = nil,
        startOffset: Int = 0,
        endOffset: Int = 0,
        charCount: Int = 0,
        tokenCount: Int = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.notebookID = notebookID
        self.ordinal = ordinal
        self.text = text
        self.headingPath = headingPath
        self.pageNumber = pageNumber
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.charCount = charCount == 0 ? text.count : charCount
        self.tokenCount = tokenCount == 0 ? TextMath.estimatedTokens(for: text) : tokenCount
    }
}

public struct ChunkEmbedding: Identifiable, Codable, Hashable, Sendable {
    public var chunkID: RecordID
    public var sourceID: RecordID
    public var notebookID: RecordID
    public var model: String
    public var dimensions: Int
    public var vector: [Float]

    public var id: RecordID { chunkID }

    public init(
        chunkID: RecordID,
        sourceID: RecordID,
        notebookID: RecordID,
        model: String,
        vector: [Float]
    ) {
        self.chunkID = chunkID
        self.sourceID = sourceID
        self.notebookID = notebookID
        self.model = model
        self.dimensions = vector.count
        self.vector = vector
    }
}

// MARK: - Chat

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant

    public var symbolName: String {
        switch self {
        case .system: return "gearshape"
        case .user: return "person"
        case .assistant: return "sparkles"
        }
    }
}

/// How far outside the notebook an answer is allowed to reach.
public enum AnswerScope: String, Codable, CaseIterable, Sendable {
    case notebookSources
    case notebookAndWeb
    case webOnly

    public var displayName: String {
        switch self {
        case .notebookSources: return L("Notebook only")
        case .notebookAndWeb: return L("Notebook + Web")
        case .webOnly: return L("Web only")
        }
    }

    public var shortName: String {
        switch self {
        case .notebookSources: return L("Sources")
        case .notebookAndWeb: return L("Sources + Web")
        case .webOnly: return L("Web")
        }
    }

    public var symbolName: String {
        switch self {
        case .notebookSources: return "books.vertical"
        case .notebookAndWeb: return "globe.badge.chevron.backward"
        case .webOnly: return "globe"
        }
    }

    public var explanation: String {
        switch self {
        case .notebookSources:
            return L("Answers use only the sources in this notebook. Nothing is sent anywhere except your selected model.")
        case .notebookAndWeb:
            return L("Answers use this notebook's sources plus live web results. Web results are labelled separately and every query is sent to your search provider.")
        case .webOnly:
            return L("Answers ignore this notebook and use live web results only.")
        }
    }

    public var usesSources: Bool { self != .webOnly }
    public var usesWeb: Bool { self != .notebookSources }
    public var requiresNetwork: Bool { usesWeb }
}

public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var notebookID: RecordID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var scope: AnswerScope
    public var providerID: String?
    public var modelName: String?
    public var isPinned: Bool

    public init(
        id: RecordID = Identifiers.new(),
        notebookID: RecordID,
        title: String = "New research session",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        scope: AnswerScope = .notebookSources,
        providerID: String? = nil,
        modelName: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.notebookID = notebookID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scope = scope
        self.providerID = providerID
        self.modelName = modelName
        self.isPinned = isPinned
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var sessionID: RecordID
    public var notebookID: RecordID
    public var role: MessageRole
    public var content: String
    public var createdAt: Date
    public var citations: [Citation]
    public var retrieval: RetrievalTrace?
    public var providerID: String?
    public var modelName: String?
    public var latencyMilliseconds: Int?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var isError: Bool
    public var errorMessage: String?
    public var errorRecovery: String?

    public init(
        id: RecordID = Identifiers.new(),
        sessionID: RecordID,
        notebookID: RecordID,
        role: MessageRole,
        content: String,
        createdAt: Date = Date(),
        citations: [Citation] = [],
        retrieval: RetrievalTrace? = nil,
        providerID: String? = nil,
        modelName: String? = nil,
        latencyMilliseconds: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        isError: Bool = false,
        errorMessage: String? = nil,
        errorRecovery: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.notebookID = notebookID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.citations = citations
        self.retrieval = retrieval
        self.providerID = providerID
        self.modelName = modelName
        self.latencyMilliseconds = latencyMilliseconds
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.isError = isError
        self.errorMessage = errorMessage
        self.errorRecovery = errorRecovery
    }
}

// MARK: - Citations

public enum CitationKind: String, Codable, Sendable {
    case notebook
    case web

    public var displayName: String {
        switch self {
        case .notebook: return L("Source")
        case .web: return L("Web")
        }
    }

    public var symbolName: String {
        switch self {
        case .notebook: return "doc.text"
        case .web: return "globe"
        }
    }
}

/// A citation as it is attached to an answer. `marker` is what appears inline in
/// the generated text ("[Source 2]" / "[Web 1]"), which is what the UI makes
/// clickable — the model never gets to invent a citation that does not resolve to
/// a real chunk, because unresolved markers are stripped during parsing.
public struct Citation: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var kind: CitationKind
    public var marker: String
    public var sourceID: RecordID?
    public var chunkID: RecordID?
    public var title: String
    public var location: String?
    public var url: String?
    public var pageNumber: Int?
    public var headingPath: String?
    public var excerpt: String
    public var score: Double

    public init(
        id: RecordID = Identifiers.new(),
        kind: CitationKind,
        marker: String,
        sourceID: RecordID? = nil,
        chunkID: RecordID? = nil,
        title: String,
        location: String? = nil,
        url: String? = nil,
        pageNumber: Int? = nil,
        headingPath: String? = nil,
        excerpt: String,
        score: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.marker = marker
        self.sourceID = sourceID
        self.chunkID = chunkID
        self.title = title
        self.location = location
        self.url = url
        self.pageNumber = pageNumber
        self.headingPath = headingPath
        self.excerpt = excerpt
        self.score = score
    }

    /// Human-readable provenance line for the inspector.
    public var provenance: String {
        var parts: [String] = []
        if let pageNumber { parts.append("page \(pageNumber)") }
        if let headingPath, !headingPath.isEmpty { parts.append(headingPath) }
        if let location, !location.isEmpty, !location.hasPrefix("page ") { parts.append(location) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Retrieval trace

/// What retrieval actually did, kept on the message so a user can see *why* an
/// answer looks the way it does — and so failed retrievals are diagnosable
/// instead of mysterious.
public struct RetrievalTrace: Codable, Hashable, Sendable {
    public struct Hit: Codable, Hashable, Sendable {
        public var chunkID: RecordID
        public var sourceID: RecordID
        public var sourceTitle: String
        public var semanticScore: Double
        public var keywordScore: Double
        public var fusedScore: Double
        public var rerankScore: Double?
        public var pageNumber: Int?
        public var headingPath: String?
        public var preview: String
        public var embeddingModel: String?
        public var usedInContext: Bool

        public init(
            chunkID: RecordID,
            sourceID: RecordID,
            sourceTitle: String,
            semanticScore: Double = 0,
            keywordScore: Double = 0,
            fusedScore: Double = 0,
            rerankScore: Double? = nil,
            pageNumber: Int? = nil,
            headingPath: String? = nil,
            preview: String = "",
            embeddingModel: String? = nil,
            usedInContext: Bool = false
        ) {
            self.chunkID = chunkID
            self.sourceID = sourceID
            self.sourceTitle = sourceTitle
            self.semanticScore = semanticScore
            self.keywordScore = keywordScore
            self.fusedScore = fusedScore
            self.rerankScore = rerankScore
            self.pageNumber = pageNumber
            self.headingPath = headingPath
            self.preview = preview
            self.embeddingModel = embeddingModel
            self.usedInContext = usedInContext
        }
    }

    public var query: String
    public var candidateCount: Int
    public var hits: [Hit]
    public var usedTokens: Int
    public var contextBudget: Int
    public var semanticEnabled: Bool
    public var keywordEnabled: Bool
    public var rerankEnabled: Bool
    public var webResultCount: Int
    public var notes: [String]
    public var durationMilliseconds: Int

    public init(
        query: String,
        candidateCount: Int = 0,
        hits: [Hit] = [],
        usedTokens: Int = 0,
        contextBudget: Int = 0,
        semanticEnabled: Bool = false,
        keywordEnabled: Bool = false,
        rerankEnabled: Bool = false,
        webResultCount: Int = 0,
        notes: [String] = [],
        durationMilliseconds: Int = 0
    ) {
        self.query = query
        self.candidateCount = candidateCount
        self.hits = hits
        self.usedTokens = usedTokens
        self.contextBudget = contextBudget
        self.semanticEnabled = semanticEnabled
        self.keywordEnabled = keywordEnabled
        self.rerankEnabled = rerankEnabled
        self.webResultCount = webResultCount
        self.notes = notes
        self.durationMilliseconds = durationMilliseconds
    }
}

// MARK: - Notes

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case manual
    case summary
    case keyPoints
    case timeline
    case faq
    case quiz
    case flashcards
    case studyGuide
    case outline
    case quotations
    case comparison
    case briefing

    public var displayName: String {
        switch self {
        case .manual: return L("Note")
        case .summary: return L("Summary")
        case .keyPoints: return L("Key Points")
        case .timeline: return L("Timeline")
        case .faq: return L("FAQ")
        case .quiz: return L("Quiz")
        case .flashcards: return L("Flashcards")
        case .studyGuide: return L("Study Guide")
        case .outline: return L("Outline")
        case .quotations: return L("Quotations")
        case .comparison: return L("Source Comparison")
        case .briefing: return L("Briefing")
        }
    }

    public var symbolName: String {
        switch self {
        case .manual: return "note.text"
        case .summary: return "text.append"
        case .keyPoints: return "list.bullet.rectangle"
        case .timeline: return "calendar.day.timeline.left"
        case .faq: return "questionmark.bubble"
        case .quiz: return "checklist"
        case .flashcards: return "rectangle.on.rectangle.angled"
        case .studyGuide: return "book.closed"
        case .outline: return "list.bullet.indent"
        case .quotations: return "quote.opening"
        case .comparison: return "rectangle.split.2x1"
        case .briefing: return "doc.text.image"
        }
    }

    public var symbolForStudyTool: String? { self == .manual ? nil : symbolName }
}

public struct NotebookNote: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var notebookID: RecordID
    public var title: String
    public var body: String
    public var kind: NoteKind
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceIDs: [RecordID]
    public var providerID: String?
    public var modelName: String?
    /// Structured side-car for tools that produce data (flashcards, quiz items).
    public var payload: NotePayload?
    public var isPinned: Bool

    public init(
        id: RecordID = Identifiers.new(),
        notebookID: RecordID,
        title: String,
        body: String = "",
        kind: NoteKind = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceIDs: [RecordID] = [],
        providerID: String? = nil,
        modelName: String? = nil,
        payload: NotePayload? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.notebookID = notebookID
        self.title = title
        self.body = body
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceIDs = sourceIDs
        self.providerID = providerID
        self.modelName = modelName
        self.payload = payload
        self.isPinned = isPinned
    }
}

public struct NotePayload: Codable, Hashable, Sendable {
    public var flashcards: [Flashcard]
    public var quizItems: [QuizItem]

    public init(flashcards: [Flashcard] = [], quizItems: [QuizItem] = []) {
        self.flashcards = flashcards
        self.quizItems = quizItems
    }

    public var isEmpty: Bool { flashcards.isEmpty && quizItems.isEmpty }
}

public struct Flashcard: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var front: String
    public var back: String
    public var sourceMarker: String?

    public init(id: RecordID = Identifiers.new(), front: String, back: String, sourceMarker: String? = nil) {
        self.id = id
        self.front = front
        self.back = back
        self.sourceMarker = sourceMarker
    }
}

public struct QuizItem: Identifiable, Codable, Hashable, Sendable {
    public var id: RecordID
    public var question: String
    public var choices: [String]
    public var answerIndex: Int
    public var explanation: String
    public var sourceMarker: String?

    public init(
        id: RecordID = Identifiers.new(),
        question: String,
        choices: [String],
        answerIndex: Int,
        explanation: String = "",
        sourceMarker: String? = nil
    ) {
        self.id = id
        self.question = question
        self.choices = choices
        self.answerIndex = answerIndex
        self.explanation = explanation
        self.sourceMarker = sourceMarker
    }

    public var answer: String { choices.indices.contains(answerIndex) ? choices[answerIndex] : "" }
}

// MARK: - Settings payloads

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var displayName: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

public enum EmbeddingChoice: String, Codable, CaseIterable, Sendable {
    case builtIn
    case ollama
    case disabled

    public var displayName: String {
        switch self {
        case .builtIn: return L("Built-in (hashing)")
        case .ollama: return L("Local model (Ollama)")
        case .disabled: return L("Off (keyword search only)")
        }
    }

    public var explanation: String {
        switch self {
        case .builtIn:
            return L("Deterministic 384-dimension lexical vectors computed on this Mac. No model download, instant, and never leaves the machine.")
        case .ollama:
            return L("Uses an embedding model served by your local Ollama install, for example nomic-embed-text. Better semantic recall, needs the model pulled once.")
        case .disabled:
            return L("Only keyword and metadata search run. Answers still work; recall is narrower.")
        }
    }
}

public enum RerankStrategy: String, Codable, CaseIterable, Sendable {
    case none
    case lexical
    case model

    public var displayName: String {
        switch self {
        case .none: return L("Off")
        case .lexical: return L("Lexical (built-in)")
        case .model: return L("Cross-encoder (local model)")
        }
    }

    public var explanation: String {
        switch self {
        case .none: return L("Use fused retrieval order as-is. Fastest.")
        case .lexical: return L("Re-scores the top candidates using term coverage and phrase proximity. No model needed.")
        case .model: return L("Asks the selected local chat model to rank candidates. Slowest, best precision. Falls back to lexical if the model is offline.")
        }
    }
}

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case off, error, info, debug

    public var displayName: String { rawValue.capitalized }
}
