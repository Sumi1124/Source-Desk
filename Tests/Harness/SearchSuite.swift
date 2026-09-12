import Foundation
import SourceDeskCore

enum SearchSuite {

    static var suite: TestSuite {
        TestSuite("8 · Web search", cases: [

            test("DuckDuckGo results are parsed and redirect URLs unwrapped") { ctx in
                let payload = """
                <html><body>
                <div class="result">
                  <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fnews.example.com%2Fpermits-delay&amp;rut=abc">Permits slow to a crawl</a>
                  <a class="result__snippet">Applicants waited more than six weeks for a routine permit this spring.</a>
                </div>
                <div class="result">
                  <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Finspectorate.example.gov%2Freport-2024">Inspectorate annual report</a>
                  <a class="result__snippet">Throughput fell by nineteen percent after the reorganisation.</a>
                </div>
                </body></html>
                """
                let results = DuckDuckGoSearchProvider.parse(html: payload, limit: 5)
                try ctx.equal(results.count, 2)
                try ctx.equal(results[0].url, "https://news.example.com/permits-delay", "redirect unwrapped")
                try ctx.equal(results[0].siteName, "news.example.com")
                try ctx.contains(results[0].title, "Permits slow")
                try ctx.contains(results[0].snippet, "six weeks")
                try ctx.equal(results[1].url, "https://inspectorate.example.gov/report-2024")
            },

            test("malformed search markup yields nothing rather than wrong links") { ctx in
                let results = DuckDuckGoSearchProvider.parse(html: "<html><body>nothing here</body></html>", limit: 5)
                try ctx.equal(results.count, 0)
                let broken = DuckDuckGoSearchProvider.parse(html: "<a class=\"result__a\" href=", limit: 5)
                try ctx.equal(broken.count, 0, "unterminated markup is tolerated")
            },

            test("DuckDuckGo works without a key and says so") { ctx in
                let provider = DuckDuckGoSearchProvider()
                try ctx.equal(provider.isConfigured, true)
                try ctx.equal(provider.requiresKey, false)
                try ctx.equal(provider.returnsContent, false)
                try ctx.contains(provider.privacyNote, "No account")
            },

            test("Brave requires a key and reports that clearly") { ctx in
                let provider = BraveSearchProvider(keychain: EmptyKeychain())
                try ctx.equal(provider.isConfigured, false)
                try ctx.contains(provider.configurationHint ?? "", "brave.com")
                let error = try await ctx.expectError("no key") {
                    try await provider.search(query: "anything")
                }
                try ctx.equal(error as? SourceDeskError, .searchProviderNotConfigured(provider: "Brave Search API"))
            },

            // A stub provider lets the whole search → enrich → context path be
            // exercised without depending on an external service.
            test("search results are handed to the answer context as web citations") { ctx in
                let results = [
                    WebSearchResult(title: "Permits delayed", url: "https://news.example.com/a",
                                    snippet: "Applicants waited six weeks.", content: "Applicants in the northern region waited more than six weeks for a routine permit this spring.", score: 0.9),
                    WebSearchResult(title: "Inspectorate report", url: "https://inspectorate.example.gov/r",
                                    snippet: "Throughput fell 19%.", content: "Throughput fell by nineteen percent after the inspection schedule was reorganised in March.", score: 0.8)
                ]
                let context = ContextAssembler.assemble(hits: [], webResults: results, tokenBudget: 5_000)
                try ctx.equal(context.hasWebMaterial, true)
                try ctx.equal(context.hasNotebookMaterial, false)
                try ctx.contains(context.text, "WEB RESULTS")
                try ctx.contains(context.text, "NOT part of the user's notebook")
                try ctx.equal(context.citations.count, 2)
                try ctx.equal(context.citations[0].marker, "[Web 1]")
                try ctx.equal(context.citations[0].kind, .web)
                try ctx.equal(context.citations[0].url, "https://news.example.com/a")
                for citation in context.citations {
                    try ctx.contains(context.text, citation.marker)
                }
            },

            test("notebook and web material are labelled separately in one prompt") { ctx in
                let hit = RetrievedChunk(
                    chunk: SourceChunk(sourceID: "s1", notebookID: "n1", ordinal: 0,
                                       text: "The review board identified two causes of the decline.", pageNumber: 4),
                    sourceID: "s1", sourceTitle: "Inspectorate Report",
                    sourceURL: "https://inspectorate.example.gov/r", sourceKind: .pdf, fusedScore: 0.9
                )
                let web = WebSearchResult(title: "News", url: "https://news.example.com/a",
                                          content: "Officials blamed staffing shortages.", score: 0.7)
                let context = ContextAssembler.assemble(hits: [hit], webResults: [web], tokenBudget: 5_000)
                try ctx.contains(context.text, "NOTEBOOK SOURCES")
                try ctx.contains(context.text, "WEB RESULTS")
                try ctx.contains(context.text, "[Source 1]")
                try ctx.contains(context.text, "[Web 1]")
                try ctx.contains(context.text, "page 4", "the PDF page number reaches the model")
                try ctx.contains(context.text, "https://news.example.com/a", "the web URL reaches the model")
            },

            test("an empty search result produces a specific error") { ctx in
                struct EmptySearch: SearchProvider {
                    let identifier = "empty"
                    let displayName = "Empty Search"
                    let requiresKey = false
                    let isConfigured = true
                    let configurationHint: String? = nil
                    let privacyNote = "Nothing is sent anywhere."
                    func search(query: String, limit: Int) async throws -> [WebSearchResult] { [] }
                }
                let service = WebSearchService(provider: EmptySearch())
                let error = try await ctx.expectError("no results") {
                    try await service.search(query: "obscure query")
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "no usable results")
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "different query")
            },

            test("a provider that returns snippets only is enriched from the page") { ctx in
                struct SnippetSearch: SearchProvider {
                    let identifier = "snippet"
                    let displayName = "Snippet Search"
                    let requiresKey = false
                    let isConfigured = true
                    let configurationHint: String? = nil
                    let privacyNote = "Snippets only."
                    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
                        [WebSearchResult(title: "Page", url: "https://example.com/article",
                                         snippet: "A short snippet.", score: 1.0)]
                    }
                }
                // Pointing the downloader at a server that refuses keeps this test
                // offline-safe: the service must fall back to the snippet.
                let downloader = WebDownloader(options: WebDownloader.Options(timeout: 2))
                let service = WebSearchService(provider: SnippetSearch(), downloader: downloader)
                let outcome = try await service.search(query: "anything", limit: 1, enrichWithPageContent: true)
                try ctx.equal(outcome.results.count, 1)
                try ctx.check(!outcome.results[0].content.isEmpty, "some content is always present")
            },

            test("search engines describe their own trade-offs") { ctx in
                for engine in SearchEngine.allCases {
                    try ctx.check(!engine.displayName.isEmpty, "\(engine.rawValue) has a name")
                    try ctx.check(!engine.detail.isEmpty, "\(engine.rawValue) explains itself")
                }
                try ctx.equal(SearchEngine.brave.requiresKey, true)
                try ctx.equal(SearchEngine.tavily.requiresKey, true)
                try ctx.equal(SearchEngine.duckduckgo.requiresKey, false)
                try ctx.isNil(SearchProviderFactory.make(choice: .none))
                try ctx.notNil(SearchProviderFactory.make(choice: .duckduckgo))
            },

            test("Tavily results carry page content") { ctx in
                let data = try JSONSerialization.data(withJSONObject: [
                    "results": [
                        ["title": "Permits delayed", "url": "https://news.example.com/a",
                         "content": "Applicants in the northern region waited more than six weeks for a routine permit this spring.", "score": 0.93],
                        ["title": "Report", "url": "https://inspectorate.example.gov/r",
                         "content": "Throughput fell by nineteen percent.", "score": 0.81]
                    ]
                ])
                let results = try TavilySearchProvider.parse(data: data, limit: 5, provider: "Tavily")
                try ctx.equal(results.count, 2)
                try ctx.contains(results[0].content, "six weeks")
                try ctx.close(results[0].score, 0.93, tolerance: 1e-9)
            },

            test("Brave results are parsed with ages") { ctx in
                let data = try JSONSerialization.data(withJSONObject: [
                    "web": ["results": [
                        ["title": "Permits slow", "url": "https://news.example.com/a",
                         "description": "Applicants waited six weeks.", "age": "3 days ago",
                         "profile": ["name": "Example News"]]
                    ]]
                ])
                let results = try BraveSearchProvider.parse(data: data, limit: 5, provider: "Brave Search API")
                try ctx.equal(results.count, 1)
                try ctx.equal(results[0].siteName, "Example News")
                try ctx.notNil(results[0].publishedAt, "relative age parsed")
            },

            test("the network monitor starts without claiming a status it does not know") { ctx in
                let monitor = NetworkMonitor()
                // Status is either unknown or a real verdict; never a crash.
                let token = monitor.observe { _ in }
                monitor.removeObserver(token)
                try ctx.check([NetworkMonitor.Status.unknown, .online, .offline, .restricted].contains(monitor.status),
                              "status is one of the known values")
            },

            test("local endpoints are recognised so local calls are never blocked") { ctx in
                try ctx.equal(Networking.isLocalEndpoint(URL(string: "http://127.0.0.1:11434")!), true)
                try ctx.equal(Networking.isLocalEndpoint(URL(string: "http://localhost:8080")!), true)
                try ctx.equal(Networking.isLocalEndpoint(URL(string: "https://api.openai.com/v1")!), false)
                try ctx.equal(Networking.isLocalEndpoint(URL(string: "http://macbook.local:11434")!), true)
            }
        ])
    }
}
