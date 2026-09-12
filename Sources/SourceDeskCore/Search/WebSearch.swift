import Foundation
import Network

// MARK: - Web search abstraction

/// A web result as the pipeline consumes it. `content` is whatever readable text
/// the provider (or a follow-up fetch) supplied — never invented.
public struct WebSearchResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String { url }
    public var title: String
    public var url: String
    public var snippet: String
    public var content: String
    public var score: Double
    public var publishedAt: Date?
    public var siteName: String?

    public init(
        title: String,
        url: String,
        snippet: String = "",
        content: String = "",
        score: Double = 0,
        publishedAt: Date? = nil,
        siteName: String? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.content = content
        self.score = score
        self.publishedAt = publishedAt
        self.siteName = siteName
    }
}

/// The contract every search backend implements, so the engine can be swapped
/// without touching the chat pipeline.
public protocol SearchProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    /// Whether the provider needs an API key.
    var requiresKey: Bool { get }
    var isConfigured: Bool { get }
    var configurationHint: String? { get }
    /// Whether this provider returns page content, or only titles and snippets.
    var returnsContent: Bool { get }
    /// Provider terms the user should know about, shown in Settings.
    var privacyNote: String { get }

    func search(query: String, limit: Int) async throws -> [WebSearchResult]
}

extension SearchProvider {
    public var returnsContent: Bool { false }
}

// MARK: - DuckDuckGo

/// Keyless web search through DuckDuckGo's HTML endpoint.
///
/// No API key, so web search works out of the box, and no account ties queries to a
/// person. It returns titles, URLs and snippets only; SourceDesk fetches page text
/// itself (respecting robots.txt) when it needs more than a snippet. As with any
/// page fetch, this can be rate-limited or changed by the provider — when that
/// happens the app reports it instead of silently returning nothing.
public struct DuckDuckGoSearchProvider: SearchProvider {

    public let identifier = "duckduckgo"
    public let displayName = "DuckDuckGo (no key)"
    public let requiresKey = false
    public let isConfigured = true
    public let configurationHint: String? = "Works without an API key. Returns titles, links and snippets."

    public var privacyNote: String {
        "Queries go to DuckDuckGo's HTML endpoint. No account and no API key are involved."
    }

    private let session: URLSession

    public init() {
        self.session = HTTPClient.session(timeout: 30)
    }

    public func search(query: String, limit: Int = 8) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            throw SourceDeskError.webSearchUnavailable(provider: displayName, reason: "could not build the query URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Networking.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: url)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SourceDeskError.webSearchUnavailable(provider: displayName, reason: "no HTTP response")
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw SourceDeskError.webSearchUnavailable(
                provider: displayName,
                reason: "the provider is rate limiting this Mac (HTTP \(http.statusCode)). Add a Brave or Tavily API key in Settings → Search for reliable results."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: displayName, url: url)
        }
        let html = String(decoding: data, as: UTF8.self)
        let results = Self.parse(html: html, limit: limit)
        if results.isEmpty {
            throw SourceDeskError.noSearchResults(query: query)
        }
        return results
    }

    /// Parses the result list. Selectors are deliberately loose: the point is to
    /// survive markup changes, and anything unrecognisable degrades to "no results"
    /// rather than a wrong answer.
    ///
    /// The result list is structured as a title anchor followed by a separate snippet
    /// element, so a result is only committed once its snippet has been read (or the
    /// next result begins) — committing at the title's close tag would drop every
    /// snippet.
    public static func parse(html: String, limit: Int) -> [WebSearchResult] {
        let tokens = HTMLTokenizer.tokenize(html)
        var results: [WebSearchResult] = []
        var pendingTitle: String?
        var pendingURL: String?
        var pendingSnippet = ""
        var capturingSnippet = false

        func commit() {
            defer { pendingTitle = nil; pendingURL = nil; pendingSnippet = "" }
            guard let title = pendingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, let url = pendingURL, !url.isEmpty,
                  !results.contains(where: { $0.url == url }) else { return }
            results.append(WebSearchResult(
                title: HTMLEntities.decode(title),
                url: url,
                snippet: pendingSnippet.trimmingCharacters(in: .whitespacesAndNewlines),
                score: max(0.1, 1.0 - Double(results.count) * 0.06),
                siteName: URL(string: url)?.host()
            ))
        }

        for token in tokens {
            switch token {
            case .startTag(let name, let attributes, _):
                let classes = (attributes["class"] ?? "").lowercased()
                if name == "a", classes.contains("result__a") || classes.contains("result-link") {
                    commit()
                    if let href = attributes["href"] { pendingURL = Self.unwrapRedirect(href) }
                    capturingSnippet = false
                } else if name == "a" || name == "div" {
                    if classes.contains("result__snippet") || classes.contains("result-snippet") {
                        capturingSnippet = true
                        pendingSnippet = ""
                    } else if classes.contains("result__url") {
                        capturingSnippet = false
                    }
                }
            case .endTag(let name):
                if capturingSnippet, name == "a" || name == "div" { capturingSnippet = false }
            case .text(let text):
                if capturingSnippet {
                    pendingSnippet += text
                } else if pendingTitle == nil || (pendingTitle ?? "").isEmpty {
                    // The title anchor's text arrives as a text node.
                    if pendingURL != nil {
                        pendingTitle = (pendingTitle ?? "") + text
                    }
                }
            default:
                break
            }
            if results.count >= limit { break }
        }
        commit()
        return Array(results.prefix(limit))
    }

    /// DuckDuckGo wraps results as `/l/?uddg=<encoded>`; unwrap to the real URL so
    /// citations point at the source rather than a redirector.
    public static func unwrapRedirect(_ href: String) -> String {
        guard href.contains("uddg=") else {
            return href.hasPrefix("//") ? "https:" + href : href
        }
        guard let components = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
              let value = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return href
        }
        return value
    }
}

// MARK: - DuckDuckGo Instant Answer API

/// DuckDuckGo's *documented* API — the one with a real endpoint instead of a page.
///
/// It is worth being precise about what this is, because the name invites a wrong
/// assumption: DuckDuckGo publishes no general web search API. `api.duckduckgo.com` is an
/// Instant Answer API. It returns an abstract (usually Wikipedia), disambiguation entries,
/// categories and related topics — not the list of ten blue links a search engine shows.
/// So it is excellent for "what is X" and poor for "recent news about X", and the app says
/// as much rather than letting the difference surprise the user.
///
/// The advantage is that it needs no key, no account and no scraping: it is a documented,
/// permitted endpoint returning JSON. The HTML endpoint used by `DuckDuckGoSearchProvider`
/// is the opposite trade — real web results, but parsed out of markup.
public struct DuckDuckGoInstantAnswerProvider: SearchProvider {

    public let identifier = "duckduckgo-api"
    public let displayName = "DuckDuckGo Instant Answer API"
    public let requiresKey = false
    public let isConfigured = true
    public let configurationHint: String? =
        "No API key needed. Returns DuckDuckGo's instant answers and related topics — good for encyclopedic topics, not for news or general web search."

    public var privacyNote: String {
        "Queries go to api.duckduckgo.com over HTTPS. No account, no key, no tracking."
    }

    private let session: URLSession

    public init() {
        self.session = HTTPClient.session(timeout: 30)
    }

    public func search(query: String, limit: Int = 8) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "0")
        ]
        guard let url = components.url else {
            throw SourceDeskError.webSearchUnavailable(provider: displayName, reason: "could not build the query URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Networking.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: url)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SourceDeskError.webSearchUnavailable(provider: displayName, reason: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: displayName, url: url)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceDeskError.webSearchUnavailable(provider: displayName, reason: "the response was not valid JSON")
        }
        let results = Self.parse(json: json, query: query, limit: limit)
        guard !results.isEmpty else {
            throw SourceDeskError.noSearchResults(query: query)
        }
        return results
    }

    /// Flattens the API's shape into ordinary results.
    ///
    /// The payload is a tree: an `Abstract`, then `Results`, then `RelatedTopics` whose
    /// entries may themselves contain a `Topics` array. All four sources of text are real
    /// material, so all four are used, with a real `FirstURL` required — an entry with no
    /// link cannot be cited, so it is not returned.
    public static func parse(json: [String: Any], query: String, limit: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        var seen = Set<String>()

        func append(title: String, url: String, snippet: String, score: Double) {
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty, let host = URL(string: trimmedURL)?.host() else { return }
            // Related topics frequently point back into DuckDuckGo itself
            // (duckduckgo.com/RISC-V_ecosystem, /c/Some_Category). Those are navigation
            // pages on the search engine, not sources — downloading one would store the
            // search engine's own index page as a "source", which is exactly the thin
            // content this app exists to avoid.
            guard host != "duckduckgo.com", !host.hasSuffix(".duckduckgo.com") else { return }
            guard seen.insert(trimmedURL).inserted else { return }
            results.append(WebSearchResult(
                title: title.isEmpty ? trimmedURL : title,
                url: trimmedURL,
                snippet: snippet,
                content: snippet,
                score: score,
                siteName: URL(string: trimmedURL)?.host()
            ))
        }

        // The abstract, when there is one, is the best single answer available.
        if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
            let url = (json["AbstractURL"] as? String) ?? ""
            let heading = (json["Heading"] as? String) ?? query
            append(title: heading, url: url, snippet: abstract, score: 1.0)
        }

        if let definition = json["Definition"] as? String, !definition.isEmpty {
            append(title: (json["DefinitionSource"] as? String) ?? query,
                   url: (json["DefinitionURL"] as? String) ?? "", snippet: definition, score: 0.9)
        }

        func take(_ raw: [[String: Any]], baseScore: Double) {
            for (index, entry) in raw.enumerated() {
                // A grouped entry holds its own Topics; recurse rather than skip.
                if let nested = entry["Topics"] as? [[String: Any]] {
                    take(nested, baseScore: baseScore - 0.05)
                    continue
                }
                guard let text = entry["Text"] as? String, !text.isEmpty else { continue }
                guard let url = entry["FirstURL"] as? String else { continue }
                // DuckDuckGo titles related topics as "Heading - detail"; the heading is a
                // better title than the whole sentence.
                let title: String
                if let separator = text.range(of: " - ") {
                    title = String(text[text.startIndex..<separator.lowerBound])
                } else {
                    title = String(text.prefix(80))
                }
                append(title: title, url: url, snippet: text,
                       score: baseScore - Double(index) * 0.01)
            }
        }

        take((json["Results"] as? [[String: Any]]) ?? [], baseScore: 0.95)
        take((json["RelatedTopics"] as? [[String: Any]]) ?? [], baseScore: 0.8)

        return Array(results.prefix(limit))
    }
}

// MARK: - Brave

/// Brave Search API — a documented, keyed, per-query-priced service.
public struct BraveSearchProvider: SearchProvider {

    public let identifier = "brave"
    public let displayName = "Brave Search API"
    public let requiresKey = true
    public let returnsContent = false
    public let keychain: KeychainReading
    public let explicitKey: String?
    public let baseURL: URL

    public init(
        keychain: KeychainReading = KeychainService(),
        explicitKey: String? = nil,
        baseURL: URL = URL(string: "https://api.search.brave.com/res/v1")!
    ) {
        self.keychain = keychain
        self.explicitKey = explicitKey
        self.baseURL = baseURL
    }

    var apiKey: String? {
        if let explicitKey, !explicitKey.isEmpty { return explicitKey }
        return keychain.secret(for: KeychainService.Key.braveSearchAPIKey)
    }

    public var isConfigured: Bool { apiKey != nil }

    public var configurationHint: String? {
        "Add a Brave Search API key in Settings → Search (free tier available at brave.com/search/api)."
    }

    public var privacyNote: String {
        "Queries are sent to the Brave Search API with your key. Brave states it does not build user profiles from API queries."
    }

    public func search(query: String, limit: Int = 8) async throws -> [WebSearchResult] {
        guard let apiKey else {
            throw SourceDeskError.searchProviderNotConfigured(provider: displayName)
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("web/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(20, max(1, limit))))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPClient.session(timeout: 30).data(for: request)
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: request.url!)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SourceDeskError.webSearchUnavailable(provider: displayName, reason: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: displayName,
                                            url: request.url!, retryAfter: HTTPClient.retryAfter(http))
        }
        return try Self.parse(data: data, limit: limit, provider: displayName)
    }

    public static func parse(data: Data, limit: Int, provider: String) throws -> [WebSearchResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = object["web"] as? [String: Any],
              let entries = web["results"] as? [[String: Any]] else {
            throw SourceDeskError.webSearchUnavailable(provider: provider, reason: "the response had no web results")
        }
        return entries.prefix(limit).enumerated().compactMap { index, entry in
            guard let url = entry["url"] as? String, let title = entry["title"] as? String else { return nil }
            return WebSearchResult(
                title: HTMLEntities.decode(title),
                url: url,
                snippet: HTMLEntities.decode((entry["description"] as? String) ?? ""),
                score: max(0.1, 1.0 - Double(index) * 0.06),
                publishedAt: (entry["age"] as? String).flatMap(DateParsing.parse),
                siteName: (entry["profile"] as? [String: Any])?["name"] as? String ?? URL(string: url)?.host()
            )
        }
    }
}

// MARK: - Tavily

/// Tavily — a search API that returns extracted page content with each result,
/// which makes it the least "thin" of the three: answers get real text instead of a
/// snippet.
public struct TavilySearchProvider: SearchProvider {

    public let identifier = "tavily"
    public let displayName = "Tavily"
    public let requiresKey = true
    public let returnsContent = true
    public let keychain: KeychainReading
    public let explicitKey: String?
    public let baseURL: URL

    public init(
        keychain: KeychainReading = KeychainService(),
        explicitKey: String? = nil,
        baseURL: URL = URL(string: "https://api.tavily.com")!
    ) {
        self.keychain = keychain
        self.explicitKey = explicitKey
        self.baseURL = baseURL
    }

    var apiKey: String? {
        if let explicitKey, !explicitKey.isEmpty { return explicitKey }
        return keychain.secret(for: KeychainService.Key.tavilySearchAPIKey)
    }

    public var isConfigured: Bool { apiKey != nil }

    public var configurationHint: String? {
        "Add a Tavily API key in Settings → Search (tavily.com). Each result includes extracted page content."
    }

    public var privacyNote: String {
        "Queries are sent to the Tavily API with your key. Results include page content retrieved by Tavily."
    }

    public func search(query: String, limit: Int = 8) async throws -> [WebSearchResult] {
        guard let apiKey else {
            throw SourceDeskError.searchProviderNotConfigured(provider: displayName)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "query": query,
            "max_results": min(20, max(1, limit)),
            "include_answer": false,
            "search_depth": "basic"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPClient.session(timeout: 45).data(for: request)
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: request.url!)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SourceDeskError.webSearchUnavailable(provider: displayName, reason: "no HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceDeskError.invalidAPIKey(provider: displayName)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: displayName, url: request.url!)
        }
        _ = apiKey
        return try Self.parse(data: data, limit: limit, provider: displayName)
    }

    public static func parse(data: Data, limit: Int, provider: String) throws -> [WebSearchResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["results"] as? [[String: Any]] else {
            throw SourceDeskError.webSearchUnavailable(provider: provider, reason: "the response had no results")
        }
        return entries.prefix(limit).enumerated().compactMap { index, entry in
            guard let url = entry["url"] as? String, let title = entry["title"] as? String else { return nil }
            let content = (entry["content"] as? String) ?? (entry["raw_content"] as? String) ?? ""
            return WebSearchResult(
                title: title,
                url: url,
                snippet: TextMath.preview(content, limit: 300),
                content: content,
                score: (entry["score"] as? Double) ?? max(0.1, 1.0 - Double(index) * 0.06),
                siteName: URL(string: url)?.host()
            )
        }
    }
}

// MARK: - Search manager

/// Resolves the configured provider and optionally enriches thin results with page
/// content fetched from the site itself.
public struct WebSearchService: Sendable {

    let provider: SearchProvider?
    let downloader: WebDownloader

    public init(provider: SearchProvider?, downloader: WebDownloader = WebDownloader()) {
        self.provider = provider
        self.downloader = downloader
    }

    public struct Outcome: Sendable {
        public var results: [WebSearchResult]
        public var notice: String?
        public var query: String
    }

    /// Searches the web. When the provider only returns snippets, the top results'
    /// pages are fetched (robots.txt respected) so the model has real text; failures
    /// to fetch are tolerated and fall back to the snippet.
    public func search(
        query: String,
        limit: Int = 6,
        enrichWithPageContent: Bool = true
    ) async throws -> Outcome {
        guard let provider else {
            throw SourceDeskError.searchProviderNotConfigured(provider: "Web search")
        }
        guard provider.isConfigured else {
            throw SourceDeskError.searchProviderNotConfigured(provider: provider.displayName)
        }
        var results = try await provider.search(query: query, limit: limit)
        var notice: String?

        if enrichWithPageContent && !provider.returnsContent {
            let toEnrich = results.prefix(4)
            var enriched: [WebSearchResult] = []
            for result in results {
                guard toEnrich.contains(where: { $0.url == result.url }) else {
                    enriched.append(result)
                    continue
                }
                do {
                    let page = try await downloader.fetch(url: result.url, maximumBytes: 3_000_000)
                    var updated = result
                    if let text = page.readableText, text.count > (result.snippet.count + 200) {
                        updated.content = TextMath.preview(text, limit: 3_000)
                    } else {
                        updated.content = result.snippet
                    }
                    if let published = page.publishedAt { updated.publishedAt = published }
                    enriched.append(updated)
                } catch {
                    // Snippet-only is a degradation, not a failure.
                    var updated = result
                    updated.content = result.snippet
                    enriched.append(updated)
                    if notice == nil {
                        let reason = (error as? SourceDeskError)?.errorDescription ?? error.localizedDescription
                        notice = "Some pages could not be read in full (\(reason)), so snippets were used for those results."
                    }
                }
            }
            results = enriched
        } else {
            results = results.map { result in
                var copy = result
                if copy.content.isEmpty { copy.content = copy.snippet }
                return copy
            }
        }

        if results.isEmpty { throw SourceDeskError.noSearchResults(query: query) }
        return Outcome(results: results, notice: notice, query: query)
    }
}

public enum SearchProviderFactory {
    public static func make(
        choice: SearchEngine,
        keychain: KeychainReading = KeychainService()
    ) -> SearchProvider? {
        switch choice {
        case .none: return nil
        case .duckduckgo: return DuckDuckGoSearchProvider()
        case .duckduckgoInstantAnswer: return DuckDuckGoInstantAnswerProvider()
        case .brave: return BraveSearchProvider(keychain: keychain)
        case .tavily: return TavilySearchProvider(keychain: keychain)
        }
    }
}

public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case none
    case duckduckgo
    case duckduckgoInstantAnswer
    case brave
    case tavily

    public var displayName: String {
        switch self {
        case .none: return "Off"
        case .duckduckgo: return "DuckDuckGo search (no key)"
        case .duckduckgoInstantAnswer: return "DuckDuckGo API (no key)"
        case .brave: return "Brave Search API"
        case .tavily: return "Tavily"
        }
    }

    public var identifier: String {
        switch self {
        case .none: return "none"
        case .duckduckgo: return "duckduckgo"
        case .duckduckgoInstantAnswer: return "duckduckgo-api"
        case .brave: return "brave"
        case .tavily: return "tavily"
        }
    }

    public var requiresKey: Bool {
        switch self {
        case .brave, .tavily: return true
        default: return false
        }
    }

    public var detail: String {
        switch self {
        case .none: return "Web search is switched off. Answers use your sources only."
        case .duckduckgo: return "No API key needed. Real web results, parsed from DuckDuckGo's HTML endpoint; page text is fetched separately, respecting robots.txt."
        case .duckduckgoInstantAnswer: return "No API key needed. DuckDuckGo's documented JSON API — instant answers, categories and related topics. Best for encyclopedic topics; it does not return general web results."
        case .brave: return "Independent index, API key required. Cheap and reliable."
        case .tavily: return "Results include extracted page content, so answers need fewer extra fetches."
        }
    }
}

// MARK: - Reachability

/// Internet reachability, surfaced plainly in the UI.
///
/// SourceDesk never blocks local work on this: when the network is down, notebooks,
/// stored sources, local search and local models keep working, and only the online
/// features report themselves as unavailable.
public final class NetworkMonitor: @unchecked Sendable {

    public enum Status: Sendable, Equatable {
        case unknown
        case online
        case offline
        /// Connected to a network, but the internet is not reachable.
        case restricted
    }

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.sourcedesk.network-monitor")
    private let lock = NSLock()
    private var _status: Status = .unknown
    private var observers: [UUID: @Sendable (Status) -> Void] = [:]

    public init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status: Status
            switch path.status {
            case .satisfied:
                status = path.isExpensive || path.isConstrained ? .online : .online
            case .requiresConnection, .unsatisfied:
                status = path.status == .requiresConnection ? .restricted : .offline
            @unknown default:
                status = .unknown
            }
            self.update(status)
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    public var isOnline: Bool { status == .online }

    private func update(_ status: Status) {
        lock.lock()
        let changed = _status != status
        _status = status
        let callbacks = changed ? Array(observers.values) : []
        lock.unlock()
        for callback in callbacks { callback(status) }
    }

    /// Registers a status callback and returns a token for removal.
    @discardableResult
    public func observe(_ callback: @escaping @Sendable (Status) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = callback
        let current = _status
        lock.unlock()
        callback(current)
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        observers[token] = nil
    }

    /// One-shot connectivity probe, for the "test connection" buttons in Settings.
    public static func probe(url: URL = URL(string: "https://api.openai.com/v1/models")!) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        do {
            _ = try await HTTPClient.session(timeout: 6).data(for: request)
            return true
        } catch {
            return false
        }
    }
}

extension Networking {
    public static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" || host.hasSuffix(".local")
    }

    /// A machine on the user's own network: loopback, an mDNS name, or a private
    /// RFC-1918 / link-local address.
    ///
    /// This is the distinction that matters for privacy. A model server on the same
    /// Mac or the same home network is not a third party, so content sent to it has
    /// not left the user's control. Anything else — including `ollama.com` — is a
    /// remote service and is treated as such.
    public static func isPrivateNetworkEndpoint(_ url: URL) -> Bool {
        if isLocalEndpoint(url) { return true }
        guard let host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }

        let parts = host.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }

        switch (octets[0], octets[1]) {
        case (10, _): return true                              // 10.0.0.0/8
        case (192, 168): return true                           // 192.168.0.0/16
        case (172, 16...31): return true                       // 172.16.0.0/12
        case (169, 254): return true                           // link-local
        default: return false
        }
    }
}
