import Foundation

/// "Find sources about X": search by topic, let the selected AI choose which results are
/// worth keeping, then download the chosen pages as ordinary sources.
///
/// Two deliberate design points.
///
/// **The AI chooses, the search engine finds.** The search API returns links; the model
/// is used for the judgement the search engine cannot make — "which of these 20 results
/// actually relate to what the user asked for?" — and to translate the user's own words
/// into a good query. Everything it returns is validated against the real result list, so
/// a model that invents a link changes nothing.
///
/// **Discovery is free, and that is not an accident.** DuckDuckGo's Instant Answer API
/// requires no key and, importantly, permits this use: the results it returns are its own
/// index, not another engine's results re-served. DuckDuckGo offers no *general* web
/// search API at all — the documented endpoint covers instant answers, disambiguation and
/// related topics, and has no key, no quota and no account. So SourceDesk asks for neither
/// a key nor consent to use one. Providers that *do* have a key (Brave, Tavily) are
/// unaffected and still work through the same pipeline.
public struct SourceDiscoveryService: Sendable {

    public struct Options: Sendable {
        /// How many results to present to the model for judgement.
        public var candidatesToConsider: Int
        /// How many to keep when the model is unavailable, or fails to choose.
        public var fallbackKeep: Int
        /// Hard ceiling on what a single run may download, regardless of what the model
        /// asks for. A model that returns "all 20" should not start a twenty-page crawl
        /// the user did not intend.
        public var maximumKeep: Int

        public init(
            candidatesToConsider: Int = 20,
            fallbackKeep: Int = 4,
            maximumKeep: Int = 8
        ) {
            self.candidatesToConsider = candidatesToConsider
            self.fallbackKeep = fallbackKeep
            self.maximumKeep = maximumKeep
        }

        public static let `default` = Options()
    }

    let search: WebSearchService
    let provider: AIProvider?
    let model: String
    let options: Options

    public init(
        search: WebSearchService,
        provider: AIProvider?,
        model: String,
        options: Options = .default
    ) {
        self.search = search
        self.provider = provider
        self.model = model
        self.options = options
    }

    public struct Selection: Sendable {
        public var result: WebSearchResult
        /// The model's reason, when it gave one.
        public var reason: String?
        /// False when this result was kept by the fallback rather than chosen.
        public var chosenByModel: Bool
    }

    public struct Plan: Sendable {
        /// The query actually sent to the search provider (the model may have improved it).
        public var query: String
        /// True when the model rewrote the user's topic into the query used.
        public var queryWasRewritten: Bool
        /// How many raw results came back.
        public var searchedCount: Int
        public var selections: [Selection]
        /// Set when the model could not be used, so the UI can say so.
        public var aiNotice: String?

        public var results: [WebSearchResult] { selections.map(\.result) }
        public var keptCount: Int { selections.count }
    }

    // MARK: - Planning

    /// Searches, then asks the model which results to keep.
    ///
    /// Never throws for model problems: a model that is unavailable, unconfigured or
    /// unparseable degrades to the top results with `aiNotice` set, because making the
    /// user solve an AI problem before they can fetch a page would be worse than fetching
    /// the obvious pages.
    public func plan(topic: String, limit: Int? = nil) async throws -> Plan {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceDeskError.invalidURL(trimmed)
        }
        let keep = min(max(1, limit ?? options.fallbackKeep), options.maximumKeep)

        // 1. Optionally let the model turn the user's words into a search query.
        var query = trimmed
        var rewritten = false
        var aiNotice: String?
        if let provider {
            if let better = try? await suggestedQuery(for: trimmed, provider: provider) {
                let candidate = better.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only accept a plausible query: a model sometimes answers with a sentence
                // or an apology, which would make a nonsense search.
                if isPlausibleQuery(candidate, original: trimmed) {
                    query = candidate
                    rewritten = candidate.localizedCaseInsensitiveCompare(trimmed) != .orderedSame
                }
            }
        }

        // 2. Search.
        //
        // `WebSearchService` raises `noSearchResults` when a query matches nothing. That is
        // an ordinary outcome of a search, not a fault in the app, so it is turned into an
        // empty plan here — otherwise a topic with no matches would surface as though
        // something had broken.
        let outcome: WebSearchService.Outcome
        do {
            outcome = try await search.search(
                query: query,
                limit: options.candidatesToConsider,
                enrichWithPageContent: false
            )
        } catch let error as SourceDeskError {
            if case .noSearchResults = error {
                return Plan(query: query, queryWasRewritten: rewritten, searchedCount: 0,
                            selections: [], aiNotice: nil)
            }
            throw error
        }
        let results = outcome.results
        guard !results.isEmpty else {
            return Plan(query: query, queryWasRewritten: rewritten, searchedCount: 0,
                        selections: [], aiNotice: aiNotice)
        }

        // 3. Ask the model which to keep. On any problem, fall back to the top results.
        guard let provider else {
            aiNotice = "No AI model is available, so the top results were taken."
            return Plan(query: query, queryWasRewritten: rewritten, searchedCount: results.count,
                        selections: Self.fallback(results, keep: keep), aiNotice: aiNotice)
        }

        do {
            guard let judgement = try await choose(
                topic: trimmed,
                results: results,
                keep: keep,
                provider: provider
            ) else {
                aiNotice = "The model's answer could not be read, so the top results were taken."
                return Plan(query: query, queryWasRewritten: rewritten, searchedCount: results.count,
                            selections: Self.fallback(results, keep: keep), aiNotice: aiNotice)
            }
            if judgement.isEmpty {
                // The model was understood, and said none of these are any good. Believing
                // it is better than downloading pages it just told us are irrelevant.
                return Plan(query: query, queryWasRewritten: rewritten, searchedCount: results.count,
                            selections: [],
                            aiNotice: "The model judged none of the \(results.count) results relevant to “\(trimmed)”.")
            }
            return Plan(query: query, queryWasRewritten: rewritten, searchedCount: results.count,
                        selections: judgement, aiNotice: nil)
        } catch let error as SourceDeskError {
            aiNotice = "The model could not be used (\(error.errorDescription ?? "unknown error")), so the top results were taken."
            return Plan(query: query, queryWasRewritten: rewritten, searchedCount: results.count,
                        selections: Self.fallback(results, keep: keep), aiNotice: aiNotice)
        } catch {
            aiNotice = "The model could not be used, so the top results were taken."
            return Plan(query: query, queryWasRewritten: rewritten, searchedCount: results.count,
                        selections: Self.fallback(results, keep: keep), aiNotice: aiNotice)
        }
    }

    // MARK: - Model interaction

    private func suggestedQuery(for topic: String, provider: AIProvider) async throws -> String? {
        let system = """
        You turn a user's topic into one web search query. Reply with the query only — no \
        quotes, no explanation, no punctuation at the end.
        """
        let user = "Topic: \(topic)"
        let response = try await provider.generate(
            AIRequest(messages: [.user(user)], model: model, temperature: 0, maxTokens: 60, systemPrompt: system)
        )
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Asks the model to pick the results worth fetching.
    ///
    /// Returns nil when the reply cannot be read (so the caller falls back), and an empty
    /// array when the model readably decided nothing is relevant — the two are different
    /// answers and must not be conflated.
    private func choose(
        topic: String,
        results: [WebSearchResult],
        keep: Int,
        provider: AIProvider
    ) async throws -> [Selection]? {
        let system = """
        You select web search results that are worth reading for a research notebook. \
        Judge only from the titles, URLs and snippets given. Reply in the required format \
        and nothing else.
        """
        var lines: [String] = []
        lines.append("The user wants sources about: \(topic)")
        lines.append("")
        lines.append("""
        Pick at most \(keep) results that are most likely to contain useful, substantive \
        information about that topic. Prefer primary sources, documentation, reference \
        material and substantial articles. Reject search pages, tag pages, shopping or \
        marketing pages, and anything only tangentially related.
        """)
        lines.append("")
        lines.append("Results:")
        for (index, result) in results.enumerated() {
            var line = "\(index + 1). \(result.title)"
            if let host = result.siteName ?? URL(string: result.url)?.host() {
                line += " (\(host))"
            }
            lines.append(line)
            let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                lines.append("   \(TextMath.preview(snippet, limit: 200))")
            }
        }
        lines.append("")
        lines.append("Reply with one line per result you want, in this exact form:")
        lines.append("number | one short reason")
        lines.append("If none are relevant, reply with exactly: NONE")

        let response = try await provider.generate(
            AIRequest(messages: [.user(lines.joined(separator: "\n"))], model: model,
                      temperature: 0, maxTokens: 400, systemPrompt: system)
        )
        return try Self.parseChoices(response.text, results: results, keep: keep)
    }

    /// Reads the model's choices and maps them onto the real results.
    ///
    /// Returns nil only when nothing at all could be understood. Indices outside the list
    /// are discarded rather than clamped: if the model references result 27 when 20 were
    /// offered, that is a hallucination, and honouring it would fetch an unintended page.
    static func parseChoices(_ text: String, results: [WebSearchResult], keep: Int) throws -> [Selection]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.uppercased().hasPrefix("NONE") { return [] }

        var seen = Set<Int>()
        var selections: [Selection] = []

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Accept "3 | reason", "3 - reason", "3. reason" and a bare "3".
            var numberText = ""
            var reasonText = ""
            let separators: [Character] = ["|", "-", ".", ":", "—", ")"]
            if let separatorIndex = line.firstIndex(where: { separators.contains($0) }) {
                numberText = String(line[line.startIndex..<separatorIndex])
                reasonText = String(line[line.index(after: separatorIndex)...])
            } else {
                numberText = line
            }
            numberText = numberText.trimmingCharacters(in: .whitespaces)
            reasonText = reasonText.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|\"-–—"))

            guard let index = Int(numberText), index >= 1, index <= results.count else { continue }
            guard seen.insert(index).inserted else { continue }
            let reason = reasonText.isEmpty ? nil : TextMath.preview(reasonText, limit: 140)
            selections.append(Selection(result: results[index - 1], reason: reason, chosenByModel: true))
            if selections.count >= keep { break }
        }

        // Nothing parseable at all — let the caller fall back rather than guessing.
        return selections.isEmpty ? nil : selections
    }

    /// A query the model returned is only usable if it looks like a query.
    private func isPlausibleQuery(_ candidate: String, original: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        // A query is short, one line, and not an explanation.
        guard candidate.count <= max(80, original.count * 3) else { return false }
        guard !candidate.contains("\n") else { return false }
        let lower = candidate.lowercased()
        let refusals = ["i cannot", "i can't", "as an ai", "sorry", "unable to",
                        "please provide", "i apologize", "there is no"]
        return !refusals.contains { lower.hasPrefix($0) || lower.contains($0) }
    }

    /// The results to use when the model could not choose.
    ///
    /// Search engines return their own result pages and section indexes near the top for
    /// some queries; those pages contain almost no prose, so preferring a page that is
    /// obviously not one of those makes the fallback useful rather than merely
    /// deterministic.
    static func fallback(_ results: [WebSearchResult], keep: Int) -> [Selection] {
        let ranked = results.enumerated().sorted { lhs, rhs in
            let lhsQuality = navigationPenalty(lhs.element.url)
            let rhsQuality = navigationPenalty(rhs.element.url)
            if lhsQuality != rhsQuality { return lhsQuality < rhsQuality }
            return lhs.offset < rhs.offset
        }
        return ranked.prefix(keep).map { entry in
            Selection(result: entry.element, reason: nil, chosenByModel: false)
        }
    }

    /// Lower is better. A crude but honest heuristic: paths that are obviously a section
    /// listing or a search page tend to be thin content.
    static func navigationPenalty(_ url: String) -> Int {
        guard let components = URLComponents(string: url) else { return 1 }
        let path = components.path.lowercased()
        let query = components.query?.lowercased() ?? ""
        if !query.isEmpty { return 3 }
        let thin = ["/search", "/tag/", "/tags/", "/category/", "/categories/", "/index",
                    "/archive", "/page/", "/author/", "/feed", "/rss", "/login", "/signup",
                    "/cart", "/checkout", "/pricing", "/contact", "/about-us", "/privacy"]
        if thin.contains(where: { path.hasSuffix($0) || path.contains($0) }) { return 2 }
        if path.isEmpty || path == "/" { return 2 }
        return 0
    }
}
