import Foundation

/// Generates study material from a notebook's sources.
///
/// Every tool runs the same way: retrieve the material that fits the tool's focus,
/// build a prompt from the material alone, generate, validate citations, and hand
/// back both a rendered Markdown note and (for flashcards and quizzes) a structured
/// payload the UI can drive.
public struct StudyToolsService: Sendable {

    public struct Configuration: Sendable {
        public var providerID: String
        public var modelName: String
        public var retrieval: RetrievalConfiguration
        public var temperature: Double
        public var localOnlyMode: Bool
        public var cloudConsentGranted: Bool

        public init(
            providerID: String,
            modelName: String,
            retrieval: RetrievalConfiguration = .default,
            temperature: Double = 0.3,
            localOnlyMode: Bool = false,
            cloudConsentGranted: Bool = false
        ) {
            self.providerID = providerID
            self.modelName = modelName
            self.retrieval = retrieval
            self.temperature = temperature
            self.localOnlyMode = localOnlyMode
            self.cloudConsentGranted = cloudConsentGranted
        }
    }

    let store: NotebookStore
    let providers: ProviderRegistry
    let retrieval: RetrievalEngine
    let configuration: Configuration
    let networkIsOnline: @Sendable () -> Bool

    public init(
        store: NotebookStore,
        providers: ProviderRegistry,
        embedder: EmbeddingProvider?,
        configuration: Configuration,
        networkIsOnline: @escaping @Sendable () -> Bool = { true }
    ) {
        self.store = store
        self.providers = providers
        self.retrieval = RetrievalEngine(store: store, embedder: embedder)
        self.configuration = configuration
        self.networkIsOnline = networkIsOnline
    }

    /// Every tool the notebook offers. Order is deliberate: the things people reach
    /// for most are first.
    public static let availableTools: [NoteKind] = [
        .summary, .keyPoints, .flashcards, .quiz, .studyGuide,
        .outline, .faq, .timeline, .quotations, .comparison, .briefing
    ]

    public struct Outcome: Sendable {
        public var note: NotebookNote
        public var citations: [Citation]
        public var notices: [String]
        public var usage: ChatUsage
        public var latencyMilliseconds: Int
        public var retrievedChunkCount: Int
    }

    public enum Event: Sendable {
        case stage(String)
        case delta(String)
        case finished(Outcome)
        case failed(SourceDeskError)
    }

    /// Runs a study tool. `sourceIDs` restricts the material (for "compare two
    /// sources", pass exactly two).
    public func generate(
        tool: NoteKind,
        notebookID: RecordID,
        sourceIDs: [RecordID]? = nil,
        focus: String? = nil,
        title: String? = nil
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let outcome = try await run(
                        tool: tool, notebookID: notebookID, sourceIDs: sourceIDs,
                        focus: focus, title: title, emit: { continuation.yield($0) }
                    )
                    continuation.yield(.finished(outcome))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch let error as SourceDeskError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(.providerUnavailable(provider: configuration.providerID, reason: error.localizedDescription)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateOnce(
        tool: NoteKind,
        notebookID: RecordID,
        sourceIDs: [RecordID]? = nil,
        focus: String? = nil,
        title: String? = nil
    ) async throws -> Outcome {
        try await run(tool: tool, notebookID: notebookID, sourceIDs: sourceIDs, focus: focus, title: title, emit: { _ in })
    }

    // MARK: - Pipeline

    private func run(
        tool: NoteKind,
        notebookID: RecordID,
        sourceIDs: [RecordID]?,
        focus: String?,
        title: String?,
        emit: @Sendable (Event) -> Void
    ) async throws -> Outcome {
        let started = Date()
        emit(.stage("Preparing"))

        guard let provider = providers.provider(id: configuration.providerID) else {
            throw SourceDeskError.providerUnavailable(provider: configuration.providerID, reason: "that provider is not registered in this build")
        }
        if configuration.localOnlyMode && !provider.isLocal {
            throw SourceDeskError.cloudDisabled(reason: "“\(provider.displayName)” is a cloud provider and Local-Only Mode is on in Settings → Privacy.")
        }
        if !provider.isLocal {
            if !networkIsOnline() { throw SourceDeskError.offline(feature: "\(provider.displayName) needs an internet connection") }
            if !provider.isConfigured { throw SourceDeskError.missingAPIKey(provider: provider.displayName) }
            if !configuration.cloudConsentGranted {
                throw SourceDeskError.cloudDisabled(reason: "Sending source text to \(provider.displayName) needs a one-time confirmation in the cloud banner.")
            }
        }

        let sources = try store.sources(notebookID: notebookID)
            .filter { $0.includeInRetrieval && $0.status != .failed }
        let selected = sourceIDs.map { ids in sources.filter { ids.contains($0.id) } } ?? sources
        guard !selected.isEmpty else {
            throw SourceDeskError.noSources(notebook: (try? store.notebook(id: notebookID))?.title ?? "This notebook")
        }
        if tool == .comparison && selected.count < 2 {
            throw SourceDeskError.insufficientContext(question: "comparing sources requires at least two sources in this notebook")
        }

        // Retrieve the material that best serves this tool.
        emit(.stage("Searching your sources"))
        var retrievalConfiguration = configuration.retrieval
        retrievalConfiguration.sourceIDs = selected.map(\.id)
        retrievalConfiguration.semanticEnabled = configuration.retrieval.semanticEnabled
        switch tool {
        case .summary, .studyGuide, .outline, .briefing:
            // Whole-document tools need breadth, not precision.
            retrievalConfiguration.resultCount = max(retrievalConfiguration.resultCount, 16)
            retrievalConfiguration.maxChunksPerSource = max(retrievalConfiguration.maxChunksPerSource, 10)
            retrievalConfiguration.minimumScore = 0
        case .comparison:
            retrievalConfiguration.resultCount = max(retrievalConfiguration.resultCount, 14)
            retrievalConfiguration.maxChunksPerSource = max(retrievalConfiguration.maxChunksPerSource, 8)
            retrievalConfiguration.minimumScore = 0
        case .flashcards, .quiz, .quotations, .keyPoints, .timeline, .faq:
            retrievalConfiguration.minimumScore = 0
        case .manual:
            break
        }
        if tool == .comparison {
            // Ensure both sources are represented rather than one dominating.
            retrievalConfiguration.maxChunksPerSource = max(4, retrievalConfiguration.resultCount / max(1, selected.count))
        }

        let query = focus?.isEmpty == false
            ? focus!
            : Self.retrievalQuery(for: tool, sourceTitles: selected.map(\.title))

        let retrieved = try await retrieval.retrieve(
            query: query,
            notebookID: notebookID,
            configuration: retrievalConfiguration
        )
        if retrieved.hits.isEmpty {
            throw SourceDeskError.insufficientContext(question: query)
        }

        let contextBudget = provider.isLocal ? 6_000 : configuration.retrieval.contextTokenBudget
        let assembled = ContextAssembler.assemble(hits: retrieved.hits, tokenBudget: contextBudget)

        // Generate.
        emit(.stage("Writing"))
        let grounding = PromptBuilder.Grounding(
            notebookAvailable: true,
            webAvailable: false,
            sourceCount: selected.count,
            scope: .notebookSources,
            cloudProviderName: provider.isLocal ? nil : provider.displayName
        )
        let system = PromptBuilder.studyToolSystemPrompt(tool: tool, grounding: grounding)
        var user = "MATERIAL\n\(assembled.text)\n\n"
        if let focus, !focus.isEmpty {
            user += "FOCUS\nThe user asked for this specifically: \(focus)\n\n"
        }
        user += "Produce the \(tool.displayName.lowercased()) now."

        let request = AIRequest(
            messages: [.user(user)],
            model: configuration.modelName,
            temperature: configuration.temperature,
            maxTokens: tool == .quiz || tool == .flashcards ? 2_400 : 2_000,
            systemPrompt: system
        )

        var accumulated = ""
        var usage = ChatUsage()
        var notices: [String] = retrieved.notices
        var modelName = configuration.modelName

        for try await event in provider.stream(request) {
            if Task.isCancelled { throw SourceDeskError.cancelled }
            switch event {
            case .delta(let piece):
                accumulated += piece
                emit(.delta(piece))
            case .finished(let response):
                usage = response.usage
                modelName = response.model
                if response.text.count > accumulated.count { accumulated = response.text }
            case .failed(let error):
                if accumulated.isEmpty { throw error }
                notices.append(error.errorDescription ?? "The model stopped early.")
            default:
                break
            }
        }

        guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceDeskError.providerRejected(provider: provider.displayName, status: 0,
                                                   message: "the model returned an empty document")
        }

        // Validate citations and strip anything the model invented.
        let resolution = CitationResolver.resolve(answer: accumulated, context: assembled)
        if !resolution.hallucinatedMarkers.isEmpty {
            notices.append("Removed \(resolution.hallucinatedMarkers.count) citation marker(s) that referred to material that was not supplied.")
        }
        let body = resolution.cleanedAnswer.isEmpty ? accumulated : resolution.cleanedAnswer

        // Build the note, including structured payloads where the tool produces them.
        var payload: NotePayload?
        switch tool {
        case .flashcards:
            let cards = Self.parseFlashcards(body)
            if cards.isEmpty {
                notices.append("No cards could be parsed in the expected Q:/A: format, so the raw text was saved instead.")
            } else {
                payload = NotePayload(flashcards: cards)
            }
        case .quiz:
            let items = Self.parseQuiz(body)
            if items.isEmpty {
                notices.append("No questions could be parsed in the expected format, so the raw text was saved instead.")
            } else {
                payload = NotePayload(quizItems: items)
            }
        default:
            break
        }

        let note = NotebookNote(
            notebookID: notebookID,
            title: title ?? Self.defaultTitle(for: tool, sources: selected),
            body: body,
            kind: tool,
            sourceIDs: selected.map(\.id),
            providerID: provider.identifier,
            modelName: modelName,
            payload: payload
        )
        try store.upsert(note: note)
        try? store.touchNotebook(id: notebookID)

        emit(.stage("Done"))
        return Outcome(
            note: note,
            citations: resolution.cited,
            notices: notices,
            usage: usage,
            latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            retrievedChunkCount: retrieved.hits.count
        )
    }

    // MARK: - Titles and queries

    public static func defaultTitle(for tool: NoteKind, sources: [Source]) -> String {
        let scope: String
        if sources.count == 1 {
            scope = sources[0].title
        } else if sources.count == 2, tool == .comparison {
            scope = "\(sources[0].title) vs \(sources[1].title)"
        } else {
            scope = "\(sources.count) sources"
        }
        return "\(tool.displayName) · \(scope)"
    }

    /// A retrieval query tuned per tool: a summary wants the document's spine, a
    /// timeline wants dates, quotations want claims.
    public static func retrievalQuery(for tool: NoteKind, sourceTitles: [String]) -> String {
        switch tool {
        case .timeline:
            return "date year month period chronology sequence then after before"
        case .quotations:
            return "argue claim conclude state found reported evidence"
        case .keyPoints:
            return "key point finding result important significant evidence"
        case .summary:
            return "overview purpose main argument conclusion findings"
        case .faq:
            return "question why how what cause reason effect"
        case .quiz, .flashcards, .studyGuide:
            return "definition concept term process cause effect mechanism"
        case .outline:
            return "section chapter introduction background method results conclusion"
        case .comparison:
            return sourceTitles.prefix(4).joined(separator: " ")
        case .briefing:
            return "summary status risk decision recommendation finding"
        case .manual:
            return sourceTitles.prefix(4).joined(separator: " ")
        }
    }

    // MARK: - Parsers

    /// Parses the `Q:` / `A:` flashcard contract. Deliberately tolerant of leading
    /// bullets, numbering, bold markers and blank lines.
    public static func parseFlashcards(_ text: String) -> [Flashcard] {
        var cards: [Flashcard] = []
        var currentQuestion: String?
        var currentAnswer = ""
        var currentMarker: String?

        func commit() {
            defer { currentQuestion = nil; currentAnswer = ""; currentMarker = nil }
            guard let question = currentQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else { return }
            let answer = currentAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return }
            cards.append(Flashcard(front: clean(question), back: clean(answer), sourceMarker: currentMarker))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let stripped = stripLeadingMarkers(line)
            let lowered = stripped.lowercased()
            if lowered.hasPrefix("q:") || lowered.hasPrefix("question:") {
                commit()
                let split = stripped.split(separator: ":", maxSplits: 1)
                currentQuestion = split.count == 2 ? String(split[1]) : stripped
            } else if lowered.hasPrefix("a:") || lowered.hasPrefix("answer:") {
                let split = stripped.split(separator: ":", maxSplits: 1)
                currentAnswer = split.count == 2 ? String(split[1]) : stripped
                currentMarker = CitationResolver.matches(of: CitationResolver.markerPattern, in: currentAnswer).first
            } else if currentQuestion != nil {
                // Continuation of the answer (cards sometimes wrap).
                currentAnswer += " " + stripped
            }
        }
        commit()
        return cards
    }

    /// Parses the numbered multiple-choice contract.
    public static func parseQuiz(_ text: String) -> [QuizItem] {
        var items: [QuizItem] = []
        var question: String?
        var choices: [String] = []
        var answerIndex: Int?
        var explanation = ""
        var marker: String?

        func commit() {
            defer { question = nil; choices = []; answerIndex = nil; explanation = ""; marker = nil }
            guard let rawQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines), !rawQuestion.isEmpty,
                  choices.count >= 2, let index = answerIndex, index < choices.count else { return }
            items.append(QuizItem(
                question: clean(rawQuestion),
                choices: choices.map(clean),
                answerIndex: index,
                explanation: clean(explanation),
                sourceMarker: marker
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let stripped = stripLeadingMarkers(line)
            let lowered = stripped.lowercased()

            if let parsed = parseChoiceLine(stripped) {
                choices.append(parsed.text)
                continue
            }
            if lowered.hasPrefix("answer:") || lowered.hasPrefix("correct:") {
                let value = stripped.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                answerIndex = choiceIndex(from: value, choiceCount: choices.count)
                continue
            }
            if lowered.hasPrefix("why:") || lowered.hasPrefix("explanation:") {
                explanation = stripped.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                marker = CitationResolver.matches(of: CitationResolver.markerPattern, in: explanation).first
                continue
            }
            if looksLikeQuestion(stripped) {
                commit()
                question = stripQuestionNumber(stripped)
                continue
            }
            if question != nil, choices.isEmpty {
                question! += " " + stripped
            }
        }
        commit()
        return items
    }

    static func parseChoiceLine(_ line: String) -> (letter: String, text: String)? {
        guard line.count > 3 else { return nil }
        let characters = Array(line)
        guard characters[0].isLetter, characters[1] == "." || characters[1] == ")" || characters[1] == ":" else { return nil }
        let letter = String(characters[0]).uppercased()
        guard "ABCDEFGH".contains(letter) else { return nil }
        let text = String(characters.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (letter, text)
    }

    static func choiceIndex(from value: String, choiceCount: Int) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()
        if let first = trimmed.first, first.isLetter, let ascii = first.asciiValue {
            return Int(ascii - Character("A").asciiValue!)
        }
        // "Answer: 2" may be 1-based or a zero-based index; 1-based is the norm.
        if let number = Int(trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).first(where: { !$0.isEmpty }) ?? "") {
            if number >= 1 && number <= choiceCount { return number - 1 }
            if number >= 0 && number < choiceCount { return number }
        }
        return nil
    }

    static func looksLikeQuestion(_ line: String) -> Bool {
        if line.hasSuffix("?") { return true }
        // "1. Something" at the start of a question block.
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        if index > 0, index < characters.count, characters[index] == "." || characters[index] == ")" {
            let rest = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
            return rest.count > 10 && !rest.lowercased().hasPrefix("answer")
        }
        return false
    }

    static func stripQuestionNumber(_ line: String) -> String {
        var characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        if index > 0, index < characters.count, characters[index] == "." || characters[index] == ")" {
            characters = Array(characters[(index + 1)...])
        }
        return String(characters).trimmingCharacters(in: .whitespaces)
    }

    static func stripLeadingMarkers(_ line: String) -> String {
        var text = line
        for marker in ["- ", "* ", "• ", "> "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }
        // Remove markdown emphasis around the Q:/A: prefixes.
        text = text.replacingOccurrences(of: "^\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "^[*_]{1,3}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_]{1,3}$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
