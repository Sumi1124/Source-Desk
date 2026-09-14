import Foundation
import SourceDeskCore

/// Research mode: search the web, add the results as real sources, then write a note.
///
/// The point of these tests is that a researched source must be as good as a pasted
/// one. The first version of this feature built a `Source` row straight from the search
/// result and left `contentPath` nil while reading text *from* `contentPath`, so every
/// researched source was saved empty — it looked like it worked and could never be
/// cited. These tests fail if that ever comes back.
enum ResearchSuite {

    /// A tiny search provider returning fixed results, so the pipeline is exercised
    /// without the public internet.
    struct StubSearchProvider: SearchProvider {
        var identifier: String { "stub" }
        var displayName: String { "Stub Search" }
        var requiresKey: Bool { false }
        var isConfigured: Bool { true }
        var configurationHint: String? { nil }
        var privacyNote: String { "Local fixture." }
        var results: [WebSearchResult]

        func search(query: String, limit: Int) async throws -> [WebSearchResult] {
            Array(results.prefix(limit))
        }
    }

    /// Builds a document with enough text to survive extraction and produce chunks.
    static func pageBody(_ marker: String) -> String {
        (1...40).map { "Paragraph \($0) about \(marker) with enough words to be treated as real prose by the extractor and chunked." }
            .joined(separator: " ")
    }

    static var suite: TestSuite {
        TestSuite("16 · Research mode", cases: [

            test("a researched page becomes a real, citable source") { ctx in
                // The whole feature in one assertion: the search result must turn into a
                // source whose content is downloaded, stored and chunked — not a row
                // built from the search snippet.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Research Target")
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    return .text(Fixtures.htmlPage(title: "Industrial Decline Report",
                                                   body: ResearchSuite.pageBody("industrial decline")),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let provider = StubSearchProvider(results: [
                    WebSearchResult(title: "Industrial Decline Report",
                                    url: "\(server.baseURL.absoluteString)/report",
                                    snippet: "A snippet that must NOT become the source text.")
                ])
                let service = SourceIngestionService(
                    store: store,
                    configuration: SourceIngestionService.Configuration(
                        chunking: .default,
                        download: WebDownloader.Options(respectRobotsTxt: true)
                    ),
                    embedder: BuiltInEmbedder()
                )

                let outcome = try await service.searchAndIngest(
                    query: "industrial decline",
                    provider: provider,
                    notebookID: notebook.id,
                    limit: 5
                )

                try ctx.equal(outcome.searched, 1)
                try ctx.equal(outcome.added.count, 1, "the result became a source")
                try ctx.equal(outcome.failed.count, 0)

                let source = try ctx.unwrap(outcome.added.first)
                try ctx.notNil(source.contentPath, "the page content was stored on disk")

                // The stored text is the page's prose, not the search snippet.
                let text = try FileStore.readText(at: URL(fileURLWithPath: try ctx.unwrap(source.contentPath)))
                try ctx.contains(text, "Paragraph 1 about industrial decline")
                try ctx.check(!text.contains("must NOT become the source text"),
                              "the snippet was not treated as the source body")

                // And it is chunked, so retrieval can actually find it.
                let chunks = try store.chunks(sourceID: source.id)
                try ctx.check(!chunks.isEmpty, "the source has chunks")
                try ctx.check(chunks.contains { $0.text.contains("industrial decline") },
                              "a chunk carries the page's text")
            },

            test("a page that cannot be read is reported as a failure, not saved empty") { ctx in
                // The specific bad outcome to prevent: a source row that exists, looks
                // fine in the sidebar, and silently contains nothing.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Research Target")
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    if request.path == "/missing" {
                        return LocalHTTPServer.Response(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found".utf8))
                    }
                    // A page with no readable prose at all.
                    return .text("<html><body><nav>Menu Home About</nav></body></html>", contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let provider = StubSearchProvider(results: [
                    WebSearchResult(title: "Missing", url: "\(server.baseURL.absoluteString)/missing"),
                    WebSearchResult(title: "Empty", url: "\(server.baseURL.absoluteString)/empty")
                ])
                let service = SourceIngestionService(store: store, configuration: .default)

                let outcome = try await service.searchAndIngest(
                    query: "anything",
                    provider: provider,
                    notebookID: notebook.id,
                    limit: 5
                )

                try ctx.equal(outcome.searched, 2)
                try ctx.equal(outcome.added.count, 0, "nothing usable was added")
                try ctx.equal(outcome.failed.count, 2, "both are reported as failures")

                // A failed page may keep a row so the user can see why it failed — but it
                // must be marked failed and explain itself, never look like a source that
                // simply happens to be empty.
                let sources = try store.sources(notebookID: notebook.id)
                for source in sources {
                    let chunks = try store.chunks(sourceID: source.id)
                    if chunks.isEmpty {
                        try ctx.equal(source.status, .failed,
                                      "source “\(source.title)” has no text, so it must be marked failed")
                        try ctx.notNil(source.errorMessage,
                                       "source “\(source.title)” explains why it failed")
                    }
                }
            },

            test("a search that returns nothing is reported clearly") { ctx in
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Empty Search")
                let service = SourceIngestionService(store: store, configuration: .default)
                let provider = StubSearchProvider(results: [])

                let outcome = try await service.searchAndIngest(
                    query: "no such topic", provider: provider, notebookID: notebook.id, limit: 5
                )
                try ctx.equal(outcome.searched, 0)
                try ctx.equal(outcome.added.count, 0)
                try ctx.check(outcome.notice != nil, "the user is told why nothing happened")
                try ctx.contains(outcome.notice ?? "", "no results")
            },

            test("duplicate results do not create duplicate sources") { ctx in
                // Search engines repeat URLs across pages and mirrors; adding the same
                // page twice would double every citation.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Duplicates")
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    return .text(Fixtures.htmlPage(title: "One Page", body: ResearchSuite.pageBody("duplicate")),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let url = "\(server.baseURL.absoluteString)/same"
                let provider = StubSearchProvider(results: [
                    WebSearchResult(title: "One Page", url: url),
                    WebSearchResult(title: "One Page (mirror)", url: url),
                    WebSearchResult(title: "One Page (again)", url: url + "/")
                ])
                let service = SourceIngestionService(store: store, configuration: .default)

                let outcome = try await service.searchAndIngest(
                    query: "duplicate", provider: provider, notebookID: notebook.id, limit: 5
                )
                try ctx.equal(outcome.added.count, 1, "the same page is added once")
                let sources = try store.sources(notebookID: notebook.id)
                try ctx.equal(sources.count, 1, "and stored once")
            },

            test("results without a usable URL are skipped without stopping the run") { ctx in
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Bad URLs")
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    return .text(Fixtures.htmlPage(title: "Good Page", body: ResearchSuite.pageBody("usable")),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let provider = StubSearchProvider(results: [
                    WebSearchResult(title: "Not a URL", url: "not-a-url"),
                    WebSearchResult(title: "Good Page", url: "\(server.baseURL.absoluteString)/good"),
                    WebSearchResult(title: "Also bad", url: "")
                ])
                let service = SourceIngestionService(store: store, configuration: .default)

                let outcome = try await service.searchAndIngest(
                    query: "usable", provider: provider, notebookID: notebook.id, limit: 5
                )
                try ctx.equal(outcome.added.count, 1, "the good result still lands")
                try ctx.equal(outcome.failed.count, 2)
            },

            test("research can be cancelled without losing what was already added") { ctx in
                // Long runs over many pages must be interruptible, and cancelling must
                // keep the sources already indexed rather than rolling them back.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Cancellable")
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    let slug = request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return .text(Fixtures.htmlPage(title: "Page \(slug)", body: ResearchSuite.pageBody(slug)),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let provider = StubSearchProvider(results: (1...8).map { index in
                    WebSearchResult(title: "Page \(index)", url: "\(server.baseURL.absoluteString)/p\(index)")
                })
                let service = SourceIngestionService(store: store, configuration: .default)

                let task = Task {
                    try await service.searchAndIngest(
                        query: "many", provider: provider, notebookID: notebook.id, limit: 8
                    )
                }
                task.cancel()
                let outcome = try await task.value

                // Whether it stopped early or finished, it must never report invented
                // additions, and everything it did claim must exist.
                try ctx.check(outcome.added.count <= 8)
                for source in outcome.added {
                    let chunks = try store.chunks(sourceID: source.id)
                    try ctx.check(!chunks.isEmpty, "every reported addition really has content")
                }
                try ctx.check(outcome.cancelled || outcome.added.count == 8,
                              "a cancelled run says so")
            },
        ])
    }
}
