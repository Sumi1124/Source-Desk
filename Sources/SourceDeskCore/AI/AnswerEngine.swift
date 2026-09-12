import Foundation

/// The end-to-end "ask a question" pipeline.
///
/// Source → retrieval → context → model → validated, cited answer.
///
/// This type holds the whole flow in one place so the UI layer only has to observe
/// events. It is deliberately usable from a command-line harness as well as from the
/// app, which is how its behaviour is verified.
public struct AnswerEngine: Sendable {

    public let store: NotebookStore
    public let providers: ProviderRegistry
    public let retrieval: RetrievalEngine
    public let search: WebSearchService?
    public let embedder: EmbeddingProvider?
    public let configuration: ResearchConfiguration
    public let networkIsOnline: @Sendable () -> Bool

    public struct ResearchConfiguration: Sendable {
        public var providerID: String
        public var modelName: String
        public var scope: AnswerScope
        public var retrieval: RetrievalConfiguration
        public var temperature: Double
        public var maxTokens: Int?
        public var localOnlyMode: Bool
        public var systemPromptOverride: String?
        /// Whether the user has already agreed to send source text to a cloud
        /// provider for this notebook.
        public var cloudConsentGranted: Bool

        public init(
            providerID: String,
            modelName: String,
            scope: AnswerScope = .notebookSources,
            retrieval: RetrievalConfiguration = .default,
            temperature: Double = 0.2,
            maxTokens: Int? = nil,
            localOnlyMode: Bool = false,
            systemPromptOverride: String? = nil,
            cloudConsentGranted: Bool = false
        ) {
            self.providerID = providerID
            self.modelName = modelName
            self.scope = scope
            self.retrieval = retrieval
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.localOnlyMode = localOnlyMode
            self.systemPromptOverride = systemPromptOverride
            self.cloudConsentGranted = cloudConsentGranted
        }
    }

    public init(
        store: NotebookStore,
        providers: ProviderRegistry,
        embedder: EmbeddingProvider?,
        search: WebSearchService?,
        configuration: ResearchConfiguration,
        networkIsOnline: @escaping @Sendable () -> Bool = { true }
    ) {
        self.store = store
        self.providers = providers
        self.retrieval = RetrievalEngine(store: store, embedder: embedder)
        self.search = search
        self.embedder = embedder
        self.configuration = configuration
        self.networkIsOnline = networkIsOnline
    }

    // MARK: - Events

    public enum Event: Sendable {
        case stage(Stage)
        /// Incremental answer text as the model produces it.
        case delta(String)
        /// Provider reasoning/thinking stream, shown separately.
        case reasoning(String)
        /// Web search happened; carries how many results came back.
        case webSearchCompleted(count: Int)
        case finished(AnswerOutcome)
        case failed(SourceDeskError)
    }

    public enum Stage: Sendable, Equatable {
        case preparing
        case searchingWeb
        case retrieving
        case reranking
        case generating
        case validating

        public var displayName: String {
            switch self {
            case .preparing: return "Preparing"
            case .searchingWeb: return "Searching the web"
            case .retrieving: return "Searching your sources"
            case .reranking: return "Ranking passages"
            case .generating: return "Writing the answer"
            case .validating: return "Checking citations"
            }
        }
    }

    public struct AnswerOutcome: Sendable {
        public var answer: String
        public var citations: [Citation]
        public var resolution: CitationResolution
        public var trace: RetrievalTrace
        public var provider: String
        public var model: String
        public var usage: ChatUsage
        public var latencyMilliseconds: Int
        public var wasTruncated: Bool
        /// Notices the UI should show alongside the answer (degraded retrieval,
        /// missing web search, and so on).
        public var notices: [String]
        /// The user should be offered a way to add material.
        public var suggestsMoreSources: Bool
        public var promptTokensEstimated: Int
        public var privacyLevel: PrivacyLevel
    }

    // MARK: - Asking

    /// Runs the full pipeline as an event stream.
    public func answer(
        question: String,
        notebookID: RecordID,
        sessionID: RecordID?,
        history: [ChatMessage] = [],
        provider overrideProvider: AIProvider? = nil
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let outcome = try await run(
                        question: question,
                        notebookID: notebookID,
                        history: history,
                        provider: overrideProvider
                    ) { event in
                        continuation.yield(event)
                    }
                    continuation.yield(.finished(outcome))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch let error as SourceDeskError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(.providerRejected(
                        provider: configuration.providerID,
                        status: 0,
                        message: error.localizedDescription
                    )))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience used by tests and by scripted flows.
    public func answerOnce(
        question: String,
        notebookID: RecordID,
        history: [ChatMessage] = [],
        provider overrideProvider: AIProvider? = nil
    ) async throws -> AnswerOutcome {
        try await run(question: question, notebookID: notebookID, history: history, provider: overrideProvider, emit: { _ in })
    }

    // MARK: - Pipeline

    private func run(
        question: String,
        notebookID: RecordID,
        history: [ChatMessage],
        provider overrideProvider: AIProvider?,
        emit: @Sendable (Event) -> Void
    ) async throws -> AnswerOutcome {
        let started = Date()
        emit(.stage(.preparing))
        var notices: [String] = []

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            throw SourceDeskError.providerRejected(provider: configuration.providerID, status: 0, message: "the question was empty")
        }

        // 1. Resolve the provider, and refuse cloud providers when appropriate —
        //    with a reason the user can act on.
        let provider = try resolveProvider(override: overrideProvider)

        // 2. Determine what material is allowed.
        let sources = try store.sources(notebookID: notebookID)
        let usableSources = sources.filter { $0.includeInRetrieval && $0.status != .failed }
        let scope = configuration.scope

        if scope.usesSources && usableSources.isEmpty && !scope.usesWeb {
            throw SourceDeskError.noSources(notebook: (try? store.notebook(id: notebookID))?.title ?? "This notebook")
        }
        if scope.usesSources && usableSources.isEmpty && scope.usesWeb {
            notices.append("This notebook has no usable sources yet, so this answer comes from the web only.")
        }

        // 3. Retrieval over the notebook.
        var hits: [RetrievedChunk] = []
        var retrievalNotices: [String] = []
        var trace = RetrievalTrace(query: trimmedQuestion)

        if scope.usesSources && !usableSources.isEmpty {
            emit(.stage(.retrieving))
            let previousUser = history.last(where: { $0.role == .user })?.content
            let previousAssistant = history.last(where: { $0.role == .assistant && !$0.isError })?.content
            let retrievalQuery = PromptBuilder.retrievalQuery(
                question: trimmedQuestion,
                previousUserMessage: previousUser,
                previousAssistantMessage: previousAssistant
            )

            var retrievalConfiguration = configuration.retrieval
            retrievalConfiguration.contextTokenBudget = min(
                retrievalConfiguration.contextTokenBudget,
                contextBudget(for: provider, model: configuration.modelName)
            )
            if configuration.retrieval.rerank == .model {
                emit(.stage(.reranking))
            }

            let reranker: (@Sendable (String, [RetrievedChunk]) async -> [Double])?
            if configuration.retrieval.rerank == .model {
                reranker = { query, candidates in
                    await self.modelRerank(query: query, candidates: candidates, provider: provider)
                }
            } else {
                reranker = nil
            }

            let outcome = try await retrieval.retrieve(
                query: retrievalQuery,
                notebookID: notebookID,
                configuration: retrievalConfiguration,
                reranker: reranker
            )
            hits = outcome.hits
            trace = outcome.trace
            retrievalNotices = outcome.notices

            if hits.isEmpty {
                notices.append("Nothing in your sources matched this question closely enough.")
            }
        } else if scope.usesSources {
            retrievalNotices.append("No sources were eligible for retrieval in this notebook.")
        }

        // 4. Web search, when allowed and possible.
        var webResults: [WebSearchResult] = []
        if scope.usesWeb {
            if let search {
                if !networkIsOnline() {
                    notices.append("Web search was skipped: this Mac is offline.")
                } else {
                    emit(.stage(.searchingWeb))
                    do {
                        let webOutcome = try await search.search(query: trimmedQuestion, limit: 6)
                        webResults = webOutcome.results
                        if let notice = webOutcome.notice { notices.append(notice) }
                        emit(.webSearchCompleted(count: webResults.count))
                    } catch let error as SourceDeskError {
                        notices.append(error.errorDescription ?? "Web search failed.")
                    }
                }
            } else {
                notices.append("Web search is switched off in Settings → Search, so only your sources were used.")
            }
        }

        if scope.usesSources && hits.isEmpty && webResults.isEmpty {
            throw SourceDeskError.insufficientContext(question: trimmedQuestion)
        }

        // 5. Build the prompt.
        let grounding = PromptBuilder.Grounding(
            notebookAvailable: !hits.isEmpty,
            webAvailable: !webResults.isEmpty,
            sourceCount: usableSources.count,
            scope: scope,
            cloudProviderName: provider.isLocal ? nil : provider.displayName
        )
        let contextBudget = contextBudget(for: provider, model: configuration.modelName)
        let assembled = ContextAssembler.assemble(hits: hits, webResults: webResults, tokenBudget: contextBudget)
        let historySummary = PromptBuilder.historySummary(history)

        let systemPrompt = configuration.systemPromptOverride?.isEmpty == false
            ? configuration.systemPromptOverride!
            : PromptBuilder.researchSystemPrompt(grounding)
        let userPrompt = PromptBuilder.researchUserPrompt(
            question: trimmedQuestion,
            context: assembled,
            historySummary: historySummary
        )

        var request = AIRequest(
            messages: [.user(userPrompt)],
            model: configuration.modelName,
            temperature: configuration.temperature,
            maxTokens: configuration.maxTokens,
            systemPrompt: systemPrompt
        )

        // Fail before spending a request when the model clearly cannot hold it.
        let estimatedPromptTokens = TextMath.estimatedTokens(for: systemPrompt + "\n" + userPrompt)
        let modelLimit = modelContextLimit(for: provider)
        if let modelLimit, estimatedPromptTokens + (configuration.maxTokens ?? 1_024) > modelLimit {
            throw SourceDeskError.contextTooLarge(
                model: "\(provider.displayName) · \(configuration.modelName)",
                neededTokens: estimatedPromptTokens,
                limitTokens: modelLimit
            )
        }

        // 6. Generate.
        emit(.stage(.generating))
        let answerText: String
        var usage = ChatUsage(promptTokens: estimatedPromptTokens)
        var finishReason: String?
        var modelName = configuration.modelName

        do {
            let response = try await stream(from: provider, request: &request, emit: emit)
            answerText = response.text
            usage = ChatUsage(
                promptTokens: response.usage.promptTokens ?? estimatedPromptTokens,
                completionTokens: response.usage.completionTokens ?? TextMath.estimatedTokens(for: response.text)
            )
            finishReason = response.finishReason
            modelName = response.model
        } catch is CancellationError {
            throw SourceDeskError.cancelled
        }

        // 7. Validate citations against exactly what was supplied.
        emit(.stage(.validating))
        let resolution = CitationResolver.resolve(answer: answerText, context: assembled)
        if !resolution.hallucinatedMarkers.isEmpty {
            notices.append("The model referenced \(resolution.hallucinatedMarkers.count) place(s) that were not in the retrieved material. Those markers were removed.")
        }
        if resolution.reportedInsufficientEvidence {
            notices.append("The model reported that the material does not answer this question.")
        }
        if !assembled.citations.isEmpty && resolution.cited.isEmpty && !resolution.reportedInsufficientEvidence {
            notices.append("The answer cited none of the retrieved passages. Verify it against your sources before relying on it.")
        }

        trace.notes.append(contentsOf: retrievalNotices)
        trace.webResultCount = webResults.count
        trace.usedTokens = assembled.usedTokens

        return AnswerOutcome(
            answer: resolution.cleanedAnswer.isEmpty ? answerText : resolution.cleanedAnswer,
            citations: resolution.cited,
            resolution: resolution,
            trace: trace,
            provider: provider.identifier,
            model: modelName,
            usage: usage,
            latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            wasTruncated: finishReason?.lowercased() == "length" || finishReason?.lowercased() == "max_tokens",
            notices: notices,
            suggestsMoreSources: resolution.reportedInsufficientEvidence || (hits.isEmpty && scope.usesSources),
            promptTokensEstimated: estimatedPromptTokens,
            privacyLevel: provider.isLocal ? .local : ((assembled.hasNotebookMaterial || assembled.hasWebMaterial) ? .cloud : .cloud)
        )
    }

    // MARK: - Helpers

    private func resolveProvider(override: AIProvider?) throws -> AIProvider {
        if let override { return override }
        guard let provider = providers.provider(id: configuration.providerID) else {
            throw SourceDeskError.providerUnavailable(
                provider: configuration.providerID,
                reason: "that provider is not registered in this build"
            )
        }
        if configuration.localOnlyMode && !provider.isLocal {
            throw SourceDeskError.cloudDisabled(
                reason: "“\(provider.displayName)” is a cloud provider and Local-Only Mode is on in Settings → Privacy."
            )
        }
        if !provider.isLocal {
            if !networkIsOnline() {
                throw SourceDeskError.offline(feature: "\(provider.displayName) requires an internet connection")
            }
            if !provider.isConfigured {
                throw SourceDeskError.missingAPIKey(provider: provider.displayName)
            }
            if !configuration.cloudConsentGranted {
                throw SourceDeskError.cloudDisabled(
                    reason: "Sending source text to \(provider.displayName) needs a one-time confirmation. Approve it in the cloud banner above the composer."
                )
            }
        }
        if configuration.modelName.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SourceDeskError.noLocalModelConfigured
        }
        return provider
    }

    /// Streams from the provider, emitting deltas. Falls back to a non-streaming
    /// call when the provider reports it cannot stream.
    private func stream(
        from provider: AIProvider,
        request: inout AIRequest,
        emit: @Sendable (Event) -> Void
    ) async throws -> AIResponse {
        var accumulated = ""
        var finalResponse: AIResponse?
        var streamedAny = false

        do {
            for try await event in provider.stream(request) {
                if Task.isCancelled { throw SourceDeskError.cancelled }
                switch event {
                case .started:
                    break
                case .delta(let piece):
                    streamedAny = true
                    accumulated += piece
                    emit(.delta(piece))
                case .reasoning(let text):
                    emit(.reasoning(text))
                case .finished(let response):
                    finalResponse = response
                case .failed(let error):
                    // If nothing streamed yet, surface the provider's error;
                    // otherwise keep the partial answer, which is more useful.
                    if !streamedAny { throw error }
                    finalResponse = AIResponse(
                        text: accumulated,
                        model: request.model,
                        usage: ChatUsage(),
                        finishReason: "incomplete: \(error.errorDescription ?? "stream failed")"
                    )
                }
            }
        } catch let error as SourceDeskError {
            if !streamedAny { throw error }
            finalResponse = AIResponse(text: accumulated, model: request.model)
        } catch is CancellationError {
            throw SourceDeskError.cancelled
        } catch {
            if !streamedAny { throw error }
            finalResponse = AIResponse(text: accumulated, model: request.model)
        }

        if let finalResponse, finalResponse.text.isEmpty == false || accumulated.isEmpty {
            let text = finalResponse.text.isEmpty ? accumulated : finalResponse.text
            // A model can return nothing at all — a context overflow, a cold model
            // that failed to load, or a stop condition that fired immediately. Saying
            // so beats persisting a blank answer the user cannot interpret.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SourceDeskError.emptyModelResponse(provider: provider.displayName, model: request.model)
            }
            return AIResponse(
                text: text,
                model: finalResponse.model,
                usage: finalResponse.usage,
                latencyMilliseconds: finalResponse.latencyMilliseconds,
                finishReason: finalResponse.finishReason
            )
        }
        if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SourceDeskError.emptyModelResponse(provider: provider.displayName, model: request.model)
        }
        return AIResponse(text: accumulated, model: request.model)
    }

    /// Model-based reranking. Fails soft: any error means lexical ranking is used.
    private func modelRerank(query: String, candidates: [RetrievedChunk], provider: AIProvider) async -> [Double] {
        guard !candidates.isEmpty else { return [] }
        let (system, user) = PromptBuilder.rerankPrompt(query: query, candidates: candidates)
        var request = AIRequest(
            messages: [.user(user)],
            model: configuration.modelName,
            temperature: 0,
            maxTokens: 200,
            systemPrompt: system
        )
        do {
            let response = try await provider.generate(request)
            if let scores = PromptBuilder.parseRerankScores(response.text, expected: candidates.count) {
                return scores
            }
        } catch {
            // Fall through: the caller uses lexical scores.
        }
        _ = request
        return candidates.map { $0.fusedScore }
    }

    private func modelContextLimit(for provider: AIProvider) -> Int? {
        // Local providers report their window through the model list; cloud models
        // are assumed to be large and are not second-guessed here.
        provider.isLocal ? nil : nil
    }

    private func contextBudget(for provider: AIProvider, model: String) -> Int {
        if provider.isLocal {
            return RetrievalConfiguration.forContextWindow(contextWindow(forLocalModel: model)).contextTokenBudget
        }
        return configuration.retrieval.contextTokenBudget
    }

    private func contextWindow(forLocalModel model: String) -> Int {
        // Known small-model windows keep local answers from overflowing; anything
        // else gets a conservative default that still fits a 3B–8B model.
        let lowered = model.lowercased()
        if lowered.contains("qwen") || lowered.contains("mistral") || lowered.contains("mixtral") { return 32_768 }
        if lowered.contains("llama3.2") || lowered.contains("llama3.1") || lowered.contains("llama3") { return 131_072 }
        if lowered.contains("phi") || lowered.contains("gemma") { return 8_192 }
        return 8_192
    }
}
