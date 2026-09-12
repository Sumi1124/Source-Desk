import Foundation

// MARK: - Configuration

public struct RetrievalConfiguration: Sendable, Equatable {
    /// How many chunks end up in the model's context.
    public var resultCount: Int
    /// How many candidates each retriever pulls before fusion and reranking.
    public var candidateCount: Int
    public var semanticEnabled: Bool
    public var keywordEnabled: Bool
    public var rerank: RerankStrategy
    /// Token budget for retrieved notebook material in the prompt.
    public var contextTokenBudget: Int
    /// Cap on chunks from any single source, so one long document cannot crowd out
    /// every other source in the notebook.
    public var maxChunksPerSource: Int
    /// Retrieval is restricted to these sources when non-nil (source scope filter).
    public var sourceIDs: [RecordID]?
    /// Chunks below this fused score are dropped rather than padding the context.
    public var minimumScore: Double

    public init(
        resultCount: Int = 8,
        candidateCount: Int = 40,
        semanticEnabled: Bool = true,
        keywordEnabled: Bool = true,
        rerank: RerankStrategy = .lexical,
        contextTokenBudget: Int = 4_000,
        maxChunksPerSource: Int = 3,
        sourceIDs: [RecordID]? = nil,
        minimumScore: Double = 0.08
    ) {
        self.resultCount = resultCount
        self.candidateCount = candidateCount
        self.semanticEnabled = semanticEnabled
        self.keywordEnabled = keywordEnabled
        self.rerank = rerank
        self.contextTokenBudget = contextTokenBudget
        self.maxChunksPerSource = maxChunksPerSource
        self.sourceIDs = sourceIDs
        self.minimumScore = minimumScore
    }

    public static let `default` = RetrievalConfiguration()

    /// Conservative defaults for a small local model with a 4k–8k window.
    public static func forContextWindow(_ tokens: Int) -> RetrievalConfiguration {
        var configuration = RetrievalConfiguration()
        switch tokens {
        case ..<6_000:
            configuration.contextTokenBudget = 2_000
            configuration.resultCount = 5
        case 6_000..<16_000:
            configuration.contextTokenBudget = 4_000
            configuration.resultCount = 8
        case 16_000..<64_000:
            configuration.contextTokenBudget = 10_000
            configuration.resultCount = 12
        default:
            configuration.contextTokenBudget = 24_000
            configuration.resultCount = 18
        }
        return configuration
    }

    public func validated() -> RetrievalConfiguration {
        var copy = self
        copy.resultCount = max(1, min(60, resultCount))
        copy.candidateCount = max(copy.resultCount, min(400, candidateCount))
        copy.contextTokenBudget = max(500, min(200_000, contextTokenBudget))
        copy.maxChunksPerSource = max(1, min(50, maxChunksPerSource))
        return copy
    }
}

// MARK: - Retrieved chunk

public struct RetrievedChunk: Sendable {
    public var chunk: SourceChunk
    public var sourceID: RecordID
    public var sourceTitle: String
    public var sourceURL: String?
    public var sourceKind: SourceKind
    public var semanticScore: Double
    public var keywordScore: Double
    public var fusedScore: Double
    public var rerankScore: Double?
    public var embeddingModel: String?

    public init(
        chunk: SourceChunk,
        sourceID: RecordID,
        sourceTitle: String,
        sourceURL: String? = nil,
        sourceKind: SourceKind = .plainText,
        semanticScore: Double = 0,
        keywordScore: Double = 0,
        fusedScore: Double = 0,
        rerankScore: Double? = nil,
        embeddingModel: String? = nil
    ) {
        self.chunk = chunk
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.semanticScore = semanticScore
        self.keywordScore = keywordScore
        self.fusedScore = fusedScore
        self.rerankScore = rerankScore
        self.embeddingModel = embeddingModel
    }

    /// Score used for final ordering: the reranker's judgement when it ran, else
    /// the fused hybrid score.
    public var effectiveScore: Double { rerankScore ?? fusedScore }
}

public struct RetrievalOutcome: Sendable {
    public var hits: [RetrievedChunk]
    public var trace: RetrievalTrace
    public var notices: [String]

    public var isEmpty: Bool { hits.isEmpty }
}

// MARK: - Engine

/// Hybrid retrieval: semantic vector search (when an embedder is configured),
/// SQLite FTS5 keyword search, reciprocal-rank fusion, then an optional rerank.
///
/// Semantic and keyword search fail independently — losing one degrades quality and
/// is reported, but never breaks an answer.
public struct RetrievalEngine: Sendable {

    let store: NotebookStore
    let embedder: EmbeddingProvider?

    public init(store: NotebookStore, embedder: EmbeddingProvider?) {
        self.store = store
        self.embedder = embedder
    }

    /// Reciprocal-rank fusion constant. 60 is the value from the original RRF paper
    /// and behaves well without tuning.
    static let rrfConstant = 60.0

    public func retrieve(
        query: String,
        notebookID: RecordID,
        configuration rawConfiguration: RetrievalConfiguration = .default,
        reranker: (@Sendable (String, [RetrievedChunk]) async -> [Double])? = nil
    ) async throws -> RetrievalOutcome {
        let started = Date()
        let configuration = rawConfiguration.validated()
        var notices: [String] = []

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return RetrievalOutcome(
                hits: [],
                trace: RetrievalTrace(query: query, notes: ["Empty query."]),
                notices: ["Empty query."]
            )
        }

        // Source metadata for citation labels.
        let allSources = try store.sources(notebookID: notebookID)
        let allowed = configuration.sourceIDs.map(Set.init)
        let sourcesByID = Dictionary(
            uniqueKeysWithValues: allSources
                .filter { $0.includeInRetrieval && (allowed == nil || allowed!.contains($0.id)) }
                .map { ($0.id, $0) }
        )
        guard !sourcesByID.isEmpty else {
            throw SourceDeskError.noSources(
                notebook: (try? store.notebook(id: notebookID))?.title ?? "This notebook"
            )
        }

        var semanticByChunk: [RecordID: (score: Double, model: String)] = [:]
        var keywordByChunk: [RecordID: Double] = [:]
        var semanticEnabled = false
        var keywordEnabled = false

        // 1. Semantic retrieval.
        if configuration.semanticEnabled, let embedder {
            let availability = await embedder.availability()
            if availability.isReady {
                do {
                    let queryVectors = try await embedder.embed([trimmedQuery])
                    if let queryVector = queryVectors.first {
                        semanticEnabled = true
                        let stored = try store.embeddings(notebookID: notebookID)
                        for embedding in stored {
                            guard sourcesByID[embedding.sourceID] != nil else { continue }
                            let score = VectorMath.cosineSimilarity(queryVector, embedding.vector)
                            if score > 0 {
                                semanticByChunk[embedding.chunkID] = (score, embedding.model)
                            }
                        }
                    }
                } catch is CancellationError {
                    throw SourceDeskError.cancelled
                } catch let error as SourceDeskError {
                    notices.append("Semantic search was skipped: \(error.errorDescription ?? "\(error)")")
                } catch {
                    notices.append("Semantic search was skipped: \(error.localizedDescription)")
                }
            } else if case .unavailable(let reason) = availability {
                notices.append("Semantic search is unavailable (\(reason)). Keyword search is still active.")
            }
        } else if configuration.semanticEnabled && embedder == nil {
            notices.append("Embeddings are turned off, so only keyword search ran.")
        }

        // 2. Keyword retrieval (FTS5). Query terms are widened with stems so
        //    "decline" and "declining" still match in the index.
        if configuration.keywordEnabled {
            keywordEnabled = true
            let expanded = Self.keywordVariants(for: trimmedQuery)
            if let raw = try? store.keywordSearch(
                query: expanded,
                notebookID: notebookID,
                sourceIDs: Array(sourcesByID.keys),
                limit: configuration.candidateCount
            ) {
                for entry in raw { keywordByChunk[entry.chunkID] = entry.score }
            }
        }

        // 3. Fuse with reciprocal rank fusion.
        var fused: [RecordID: Double] = [:]
        let semanticRanking = semanticByChunk.sorted { $0.value.score > $1.value.score }.map(\.key)
        let keywordRanking = keywordByChunk.sorted { $0.value > $1.value }.map(\.key)
        for (rank, chunkID) in semanticRanking.enumerated() {
            fused[chunkID, default: 0] += 1.0 / (Self.rrfConstant + Double(rank + 1))
        }
        for (rank, chunkID) in keywordRanking.enumerated() {
            fused[chunkID, default: 0] += 1.0 / (Self.rrfConstant + Double(rank + 1))
        }

        // A chunk retrieved by both channels is a strong signal; RRF already rewards
        // it, and this small bonus breaks ties in favour of genuine agreement.
        for chunkID in fused.keys {
            if semanticByChunk[chunkID] != nil && keywordByChunk[chunkID] != nil {
                fused[chunkID, default: 0] *= 1.15
            }
        }

        guard !fused.isEmpty else {
            let trace = RetrievalTrace(
                query: trimmedQuery, candidateCount: 0, hits: [], usedTokens: 0,
                contextBudget: configuration.contextTokenBudget,
                semanticEnabled: semanticEnabled, keywordEnabled: keywordEnabled,
                rerankEnabled: configuration.rerank != .none, webResultCount: 0,
                notes: notices + ["No candidate chunks matched this query."],
                durationMilliseconds: Self.milliseconds(since: started)
            )
            return RetrievalOutcome(hits: [], trace: trace, notices: notices)
        }

        // 4. Load the winning chunks and build candidates.
        let rankedIDs = fused.sorted { $0.value > $1.value }.prefix(configuration.candidateCount).map(\.key)
        let chunks = try store.chunks(ids: Array(rankedIDs))
        let maxFused = fused.values.max() ?? 1
        var candidates: [RetrievedChunk] = chunks.compactMap { chunk in
            guard let source = sourcesByID[chunk.sourceID] else { return nil }
            let raw = fused[chunk.id] ?? 0
            return RetrievedChunk(
                chunk: chunk,
                sourceID: chunk.sourceID,
                sourceTitle: source.title,
                sourceURL: source.url,
                sourceKind: source.kind,
                semanticScore: semanticByChunk[chunk.id]?.score ?? 0,
                keywordScore: keywordByChunk[chunk.id] ?? 0,
                fusedScore: maxFused > 0 ? raw / maxFused : 0,
                embeddingModel: semanticByChunk[chunk.id]?.model
            )
        }
        candidates.sort { $0.fusedScore > $1.fusedScore }

        // 5. Rerank.
        var rerankEnabled = false
        switch configuration.rerank {
        case .none:
            break
        case .lexical:
            rerankEnabled = true
            candidates = LexicalReranker.rerank(query: trimmedQuery, candidates: candidates)
        case .model:
            if let reranker {
                do {
                    let scores = await reranker(trimmedQuery, Array(candidates.prefix(20)))
                    if scores.count == candidates.prefix(20).count {
                        rerankEnabled = true
                        for index in 0..<scores.count {
                            candidates[index].rerankScore = scores[index]
                        }
                    } else {
                        notices.append("The model reranker returned an unexpected score count, so lexical reranking was used instead.")
                        candidates = LexicalReranker.rerank(query: trimmedQuery, candidates: candidates)
                        rerankEnabled = true
                    }
                }
            } else {
                notices.append("No reranking model is configured, so lexical reranking was used.")
                candidates = LexicalReranker.rerank(query: trimmedQuery, candidates: candidates)
                rerankEnabled = true
            }
        }

        candidates.sort { $0.effectiveScore > $1.effectiveScore }

        // 6. Apply the per-source cap and the score floor, then take the top results.
        //
        // The cap is a guarantee, not a hint: with several eligible sources no single
        // document may occupy more than its share, which is what keeps a 600-page
        // report from burying a two-page memo. A notebook with only one eligible
        // source has nothing to be diverse across, so the cap is lifted there rather
        // than returning three chunks when the user asked for eight.
        let effectiveCap = sourcesByID.count <= 1
            ? max(configuration.maxChunksPerSource, configuration.resultCount)
            : configuration.maxChunksPerSource

        var perSourceCount: [RecordID: Int] = [:]
        var selected: [RetrievedChunk] = []
        var cappedOut = 0
        for candidate in candidates {
            let used = perSourceCount[candidate.sourceID, default: 0]
            if used >= effectiveCap {
                cappedOut += 1
                continue
            }
            perSourceCount[candidate.sourceID] = used + 1
            selected.append(candidate)
        }
        selected = selected
            .filter { $0.effectiveScore >= configuration.minimumScore || selected.count <= 2 }
            .prefix(configuration.resultCount)
            .map { $0 }

        if cappedOut > 0 && selected.count < configuration.resultCount {
            notices.append(
                "Returned \(selected.count) of \(configuration.resultCount) requested passages: the per-source limit (\(effectiveCap)) was reached. Raise “Passages per source” in Settings → Advanced for more from each source."
            )
        }

        if selected.isEmpty {
            notices.append("No chunk scored above the relevance floor (\(String(format: "%.2f", configuration.minimumScore))).")
        }

        // 7. Trim to the context budget.
        var usedTokens = 0
        var final: [RetrievedChunk] = []
        for candidate in selected {
            let cost = candidate.chunk.tokenCount + 24 // marker + heading overhead
            if usedTokens + cost > configuration.contextTokenBudget && !final.isEmpty { break }
            usedTokens += cost
            final.append(candidate)
        }

        let hits = final.map { candidate in
            RetrievalTrace.Hit(
                chunkID: candidate.chunk.id,
                sourceID: candidate.sourceID,
                sourceTitle: candidate.sourceTitle,
                semanticScore: candidate.semanticScore,
                keywordScore: candidate.keywordScore,
                fusedScore: candidate.fusedScore,
                rerankScore: candidate.rerankScore,
                pageNumber: candidate.chunk.pageNumber,
                headingPath: candidate.chunk.headingPath,
                preview: TextMath.preview(candidate.chunk.text, limit: 180),
                embeddingModel: candidate.embeddingModel,
                usedInContext: true
            )
        }

        let trace = RetrievalTrace(
            query: trimmedQuery,
            candidateCount: fused.count,
            hits: hits,
            usedTokens: usedTokens,
            contextBudget: configuration.contextTokenBudget,
            semanticEnabled: semanticEnabled,
            keywordEnabled: keywordEnabled,
            rerankEnabled: rerankEnabled,
            webResultCount: 0,
            notes: notices,
            durationMilliseconds: Self.milliseconds(since: started)
        )
        return RetrievalOutcome(hits: final, trace: trace, notices: notices)
    }

    /// Adds stem variants to the FTS query so morphology does not defeat keyword
    /// search (FTS5 matches tokens, not stems).
    static func keywordVariants(for query: String) -> String {
        var terms: [String] = []
        for token in TextMath.tokens(query) where token.count > 2 && !TextMath.stopWords.contains(token) {
            let stem = TextMath.stem(token)
            terms.append(token)
            if stem != token, stem.count > 3 { terms.append(stem + "*") }
        }
        if terms.isEmpty {
            terms = TextMath.tokens(query).filter { $0.count > 1 }
        }
        return terms.map { $0.hasSuffix("*") ? $0 : "\"\($0)\"" }.joined(separator: " OR ")
    }

    static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - Lexical reranker

/// Re-scores candidates on how well they actually answer the query: term coverage,
/// phrase proximity, heading agreement, and a mild preference for focused chunks.
/// This runs in milliseconds and needs no model, which is why it is the default.
public enum LexicalReranker {

    public static func rerank(query: String, candidates: [RetrievedChunk]) -> [RetrievedChunk] {
        let queryTokens = TextMath.tokens(query).filter { !TextMath.stopWords.contains($0) }
        let queryStems = Set(queryTokens.map(TextMath.stem))
        guard !queryStems.isEmpty else { return candidates }

        var scored = candidates
        for index in scored.indices {
            let chunk = scored[index]
            let chunkTokens = TextMath.tokens(chunk.chunk.text)
            let chunkStems = Set(chunkTokens.map(TextMath.stem))
            let coverage = Double(queryStems.intersection(chunkStems).count) / Double(queryStems.count)

            // Proximity: best window containing the most distinct query stems.
            let proximity = bestWindowCoverage(tokens: chunkTokens, queryStems: queryStems)

            // Heading agreement is a strong hint that this chunk is *about* the topic.
            let headingStems = Set(TextMath.tokens(chunk.chunk.headingPath ?? "").map(TextMath.stem))
            let headingMatch = headingStems.isEmpty ? 0 : Double(queryStems.intersection(headingStems).count) / Double(queryStems.count)

            // Term frequency saturating quickly: a chunk repeating a word ten times
            // is not ten times more relevant.
            let matches = chunkTokens.filter { queryStems.contains(TextMath.stem($0)) }.count
            let density = Double(matches) / Double(max(20, chunkTokens.count))
            let frequency = min(1.0, log(1.0 + Double(matches)) / 3.0)

            // Very short fragments are usually list stubs; prefer real prose.
            let lengthPenalty = chunk.chunk.tokenCount < 40 ? 0.85 : 1.0

            let score = (
                coverage * 0.44
                + proximity * 0.24
                + headingMatch * 0.16
                + frequency * 0.10
                + min(1.0, density * 12) * 0.06
            ) * lengthPenalty

            // Blend with the fused score so a strong vector match is not discarded.
            scored[index].rerankScore = min(1.0, score * 0.75 + chunk.fusedScore * 0.25)
        }
        return scored.sorted { $0.effectiveScore > $1.effectiveScore }
    }

    /// Fraction of distinct query stems found inside the densest sliding window.
    static func bestWindowCoverage(tokens: [String], queryStems: Set<String>) -> Double {
        guard !tokens.isEmpty, !queryStems.isEmpty else { return 0 }
        let window = 40
        var best = 0.0
        var index = 0
        while index < tokens.count {
            let end = min(index + window, tokens.count)
            let windowStems = Set(tokens[index..<end].map(TextMath.stem))
            let coverage = Double(queryStems.intersection(windowStems).count) / Double(queryStems.count)
            best = max(best, coverage)
            if best >= 1.0 { break }
            index += max(1, window / 2)
        }
        return best
    }
}

// MARK: - Context assembly

public struct ContextBlock: Sendable {
    public var marker: String
    public var citation: Citation
    public var text: String
    public var tokens: Int

    public init(marker: String, citation: Citation, text: String, tokens: Int) {
        self.marker = marker
        self.citation = citation
        self.text = text
        self.tokens = tokens
    }
}

public struct AssembledContext: Sendable {
    public var text: String
    public var citations: [Citation]
    public var blocks: [ContextBlock]
    public var usedTokens: Int
    /// Notebook material present at all?
    public var hasNotebookMaterial: Bool
    /// Web material present at all?
    public var hasWebMaterial: Bool
}

/// Turns retrieved chunks (and optional web results) into the exact prompt block a
/// model sees, while producing the citation records the UI needs to make every
/// marker clickable.
///
/// Markers are assigned here and only here, so a citation can never point at
/// something that was not actually in the context.
public enum ContextAssembler {

    public static func assemble(
        hits: [RetrievedChunk],
        webResults: [WebSearchResult] = [],
        tokenBudget: Int
    ) -> AssembledContext {
        var blocks: [ContextBlock] = []
        var citations: [Citation] = []
        var sections: [String] = []
        var usedTokens = 0

        if !hits.isEmpty {
            var notebookLines: [String] = []
            for (offset, hit) in hits.enumerated() {
                let marker = "[Source \(offset + 1)]"
                let location = locationDescription(for: hit)
                let heading = hit.chunk.headingPath.map { "\nSection: \($0)" } ?? ""
                let body = """
                \(marker) \(hit.sourceTitle)\(location.isEmpty ? "" : " — \(location)")\(heading)
                \(hit.chunk.text)
                """
                let tokens = TextMath.estimatedTokens(for: body)
                guard usedTokens + tokens <= tokenBudget || blocks.isEmpty else { break }
                usedTokens += tokens
                notebookLines.append(body)

                let citation = Citation(
                    kind: .notebook,
                    marker: marker,
                    sourceID: hit.sourceID,
                    chunkID: hit.chunk.id,
                    title: hit.sourceTitle,
                    location: hit.sourceURL ?? location,
                    url: hit.sourceURL,
                    pageNumber: hit.chunk.pageNumber,
                    headingPath: hit.chunk.headingPath,
                    excerpt: TextMath.preview(hit.chunk.text, limit: 600),
                    score: hit.effectiveScore
                )
                citations.append(citation)
                blocks.append(ContextBlock(marker: marker, citation: citation, text: hit.chunk.text, tokens: tokens))
            }
            sections.append("NOTEBOOK SOURCES (the user's own collected material):\n\n" + notebookLines.joined(separator: "\n\n---\n\n"))
        }

        if !webResults.isEmpty {
            var webLines: [String] = []
            for (offset, result) in webResults.enumerated() {
                let marker = "[Web \(offset + 1)]"
                let content = TextMath.preview(result.content, limit: 1_200)
                let body = """
                \(marker) \(result.title) — \(result.url)
                \(content)
                """
                let tokens = TextMath.estimatedTokens(for: body)
                guard usedTokens + tokens <= tokenBudget + 1_200 || blocks.isEmpty else { break }
                usedTokens += tokens
                webLines.append(body)

                let citation = Citation(
                    kind: .web,
                    marker: marker,
                    title: result.title,
                    location: result.url,
                    url: result.url,
                    excerpt: TextMath.preview(result.content, limit: 600),
                    score: result.score
                )
                citations.append(citation)
                blocks.append(ContextBlock(marker: marker, citation: citation, text: result.content, tokens: tokens))
            }
            sections.append("WEB RESULTS (live search; NOT part of the user's notebook):\n\n" + webLines.joined(separator: "\n\n---\n\n"))
        }

        return AssembledContext(
            text: sections.joined(separator: "\n\n"),
            citations: citations,
            blocks: blocks,
            usedTokens: usedTokens,
            hasNotebookMaterial: !hits.isEmpty,
            hasWebMaterial: !webResults.isEmpty
        )
    }

    static func locationDescription(for hit: RetrievedChunk) -> String {
        if let page = hit.chunk.pageNumber { return "page \(page)" }
        if let url = hit.sourceURL { return url }
        return hit.sourceKind.displayName
    }
}

// MARK: - Citation resolution

/// What the model actually cited, validated against what it was given.
public struct CitationResolution: Sendable {
    /// Citations that resolve to real context, in order of first appearance.
    public var cited: [Citation]
    /// Citations that were provided but never referenced.
    public var uncited: [Citation]
    /// Markers the model wrote that do not exist in the context. These are stripped
    /// from the visible answer: a fabricated citation is worse than none.
    public var hallucinatedMarkers: [String]
    /// Answer text with fabricated markers removed.
    public var cleanedAnswer: String
    /// The model stated that the sources do not answer the question.
    public var reportedInsufficientEvidence: Bool

    public var usedSourceCount: Int { cited.filter { $0.kind == .notebook }.count }
    public var usedWebCount: Int { cited.filter { $0.kind == .web }.count }
}

public enum CitationResolver {

    public static let markerPattern = "\\[(?:Source|Web)\\s*\\d+\\]"

    /// Phrases models use when the retrieved context genuinely does not answer the
    /// question. Detecting them lets the UI offer "add sources / turn on web search"
    /// instead of leaving the user with a dead-end answer.
    static let insufficiencyPhrases = [
        "do not contain enough information", "does not contain enough information",
        "do not contain sufficient information", "does not contain sufficient information",
        "not enough information in the provided sources", "not enough relevant source material",
        "the provided sources do not", "the sources provided do not", "not mentioned in the provided",
        "no information about", "cannot be determined from the provided", "unable to answer from the provided",
        "the context does not", "based on the provided context, there is no", "insufficient information"
    ]

    public static func resolve(answer: String, context: AssembledContext) -> CitationResolution {
        let available = Dictionary(uniqueKeysWithValues: context.citations.map { ($0.marker, $0) })
        var cited: [Citation] = []
        var hallucinated: [String] = []
        var seen = Set<String>()

        for match in matches(of: markerPattern, in: answer) {
            let normalized = normalizeMarker(match)
            guard let citation = available[normalized] ?? available[match] else {
                if !hallucinated.contains(match) { hallucinated.append(match) }
                continue
            }
            if seen.insert(citation.marker).inserted { cited.append(citation) }
        }

        let citedSet = Set(cited.map(\.marker))
        let uncited = context.citations.filter { !citedSet.contains($0.marker) }
        let lowered = answer.lowercased()
        let insufficient = insufficiencyPhrases.contains { lowered.contains($0) }

        return CitationResolution(
            cited: cited,
            uncited: uncited,
            hallucinatedMarkers: hallucinated,
            cleanedAnswer: stripFabricatedMarkers(from: answer, unavailable: Set(hallucinated)),
            reportedInsufficientEvidence: insufficient
        )
    }

    /// Removes only the markers that do not resolve; real citations stay put.
    public static func stripFabricatedMarkers(from answer: String, unavailable: Set<String>) -> String {
        guard !unavailable.isEmpty else { return answer }
        var result = answer
        for marker in unavailable {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        // Tidy the space left behind, and collapse doubled punctuation.
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " ([.,;])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n ", with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "[Source 3]" and "[source3]" both resolve to "[Source 3]".
    public static func normalizeMarker(_ marker: String) -> String {
        let inner = marker.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let digits = inner.filter(\.isNumber)
        let kind = inner.lowercased().hasPrefix("web") ? "Web" : "Source"
        return "[\(kind) \(digits)]"
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }
}
