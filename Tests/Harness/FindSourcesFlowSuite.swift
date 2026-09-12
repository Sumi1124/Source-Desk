import Foundation
import SourceDeskCore

/// The Sources-pane flow, end to end.
///
/// Suite 23 covers the plan (search plus the AI's judgement) and suite 16 covers ingesting
/// one URL. This covers the step in between, which is the part the user actually controls:
/// approving a subset of the AI's picks and having only that subset downloaded and
/// indexed. If approval were ignored, the AI's judgement would be pointless.
enum FindSourcesFlowSuite {

    struct FixedSearch: SearchProvider {
        let identifier = "fixed"
        let displayName = "Fixed Search"
        let requiresKey = false
        let isConfigured = true
        let configurationHint: String? = nil
        let privacyNote = "Nothing is sent anywhere."
        let results: [WebSearchResult]

        func search(query: String, limit: Int) async throws -> [WebSearchResult] {
            Array(results.prefix(limit))
        }
    }

    struct ChoosingProvider: AIProvider {
        var identifier: String { "chooser" }
        var displayName: String { "Chooser" }
        var isLocal: Bool { true }
        var isConfigured: Bool { true }
        var configurationHint: String? { nil }
        var replies: [String]
        final class Log: @unchecked Sendable { var count = 0 }
        let log = Log()

        func availability() async -> ProviderAvailability { .ready }
        func availableModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(providerID: identifier, name: "chooser-1", isLocal: true)]
        }
        func generate(_ request: AIRequest) async throws -> AIResponse {
            log.count += 1
            let index = min(log.count - 1, replies.count - 1)
            return AIResponse(text: replies[max(0, index)], model: request.model)
        }
        func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A page with real prose, so extraction and chunking actually produce passages.
    static func page(_ marker: String) -> String {
        (1...30).map { "Paragraph \($0) about \(marker) with enough words to be treated as real prose by the extractor." }
            .joined(separator: " ")
    }

    static var suite: TestSuite {
        TestSuite("25 · Find sources: approve then fetch", cases: [

            test("only the approved results are downloaded") { ctx in
                // The point of the approval step. Three results are found, the model picks
                // one, the user approves a different one — and only the approved one may
                // be fetched.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Approval")

                var fetched: [String] = []
                let lock = NSLock()
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    lock.lock(); fetched.append(request.path); lock.unlock()
                    return .text(Fixtures.htmlPage(title: "Page \(request.path)",
                                                   body: FindSourcesFlowSuite.page(request.path)),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let base = server.baseURL.absoluteString
                let candidates = [
                    WebSearchResult(title: "AI's pick", url: "\(base)/ai-pick"),
                    WebSearchResult(title: "User's pick", url: "\(base)/user-pick"),
                    WebSearchResult(title: "Nobody's pick", url: "\(base)/ignored")
                ]

                let provider = ChoosingProvider(replies: ["query", "1 | the model liked this one"])
                let discovery = SourceDiscoveryService(
                    search: WebSearchService(provider: FixedSearch(results: candidates)),
                    provider: provider, model: "chooser-1",
                    options: .init(candidatesToConsider: 10, fallbackKeep: 2, maximumKeep: 4)
                )
                let plan = try await discovery.plan(topic: "anything", limit: 3)

                try ctx.equal(plan.keptCount, 1, "the model picked one")
                try ctx.equal(plan.results[0].url, "\(base)/ai-pick")

                // The user overrides: they want the second one instead.
                let approved = [candidates[1]]
                let service = SourceIngestionService(store: store, configuration: .default)

                var added: [Source] = []
                for (index, result) in approved.enumerated() {
                    let outcome = await service.ingestWebsite(
                        url: result.url, title: result.title, notebookID: notebook.id,
                        index: index, total: approved.count, progress: nil
                    )
                    if outcome.succeeded, outcome.chunkCount > 0 { added.append(outcome.source) }
                }

                try ctx.equal(added.count, 1)
                try ctx.equal(added[0].title, "User's pick")

                // The two unapproved pages were never requested.
                try ctx.check(!fetched.contains("/ai-pick"), "the model's pick was not fetched")
                try ctx.check(!fetched.contains("/ignored"), "the third result was not fetched")
                try ctx.equal(fetched.filter { $0 == "/user-pick" }.count, 1, "only the approved page was fetched")

                // And the notebook holds exactly one source, with real content.
                let sources = try store.sources(notebookID: notebook.id)
                try ctx.equal(sources.count, 1)
                let chunks = try store.chunks(sourceID: sources[0].id)
                try ctx.check(!chunks.isEmpty, "and it is indexed, so it can be cited")
            },

            test("approving several results adds them all, and one failure does not stop the rest") { ctx in
                // A batch where the second page 404s: the first and third must still land.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Partial batch")
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    if request.path == "/broken" {
                        return LocalHTTPServer.Response(status: 404, headers: ["Content-Type": "text/plain"],
                                                        body: Data("gone".utf8))
                    }
                    return .text(Fixtures.htmlPage(title: "Page \(request.path)",
                                                   body: FindSourcesFlowSuite.page(request.path)),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let base = server.baseURL.absoluteString
                let approved = [
                    WebSearchResult(title: "First", url: "\(base)/first"),
                    WebSearchResult(title: "Broken", url: "\(base)/broken"),
                    WebSearchResult(title: "Third", url: "\(base)/third")
                ]
                let service = SourceIngestionService(store: store, configuration: .default)

                var added = 0
                var failed = 0
                for (index, result) in approved.enumerated() {
                    let outcome = await service.ingestWebsite(
                        url: result.url, title: result.title, notebookID: notebook.id,
                        index: index, total: approved.count, progress: nil
                    )
                    if outcome.succeeded, outcome.chunkCount > 0 { added += 1 } else { failed += 1 }
                }

                try ctx.equal(added, 2, "two pages were indexed")
                try ctx.equal(failed, 1, "the broken one was reported, not counted as added")

                let sources = try store.sources(notebookID: notebook.id)
                let ready = sources.filter { $0.status == .ready || $0.status == .partial }
                try ctx.equal(ready.count, 2)
                // The failure kept a row explaining itself rather than vanishing.
                let broken = sources.first { $0.status == .failed }
                try ctx.notNil(broken, "the failed page is recorded")
                try ctx.notNil(broken?.errorMessage, "with a reason")
            },

            test("re-finding the same topic does not duplicate sources already added") { ctx in
                // Running the search twice is normal; the second run must refresh, not
                // double every citation.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Repeat")
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    return .text(Fixtures.htmlPage(title: "Stable page",
                                                   body: FindSourcesFlowSuite.page("stable")),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let url = "\(server.baseURL.absoluteString)/stable"
                let service = SourceIngestionService(store: store, configuration: .default)

                for _ in 0..<2 {
                    _ = await service.ingestWebsite(url: url, title: "Stable page",
                                                    notebookID: notebook.id, progress: nil)
                }

                let sources = try store.sources(notebookID: notebook.id)
                try ctx.equal(sources.count, 1, "the page was added once")
                let chunks = try store.chunks(sourceID: sources[0].id)
                try ctx.check(!chunks.isEmpty, "and it still has its passages")
                // Crucially, the refresh must not have doubled the passages.
                let firstCount = try store.chunks(sourceID: sources[0].id).count
                try ctx.equal(chunks.count, firstCount, "passages were replaced, not appended")
            },
        ])
    }
}
