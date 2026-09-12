import Foundation
import SourceDeskCore

/// End-to-end verification of the real application pipeline, run headlessly.
///
/// This suite exists because unit tests can pass while the *product* does not work:
/// it exercises the same objects the app composes at launch — store, settings,
/// ingestion, retrieval, the answer engine, providers, study tools, export/import —
/// against a live local HTTP server, and against this Mac's real filesystem layout.
///
/// Set `SOURCEDESK_LIVE_WEB=1` to also run the tests that touch the public internet.
enum EndToEndSuite {

    static var liveWeb: Bool {
        ProcessInfo.processInfo.environment["SOURCEDESK_LIVE_WEB"] == "1"
    }

    static var suite: TestSuite {
        TestSuite("13 · End-to-end product flows", cases: [
            test("a website is ingested from a real HTTP server, chunked, embedded and searchable") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" {
                        return .text("User-agent: *\nAllow: /\n")
                    }
                    if request.path == "/article" {
                        return .text(Fixtures.htmlPage(
                            title: "Inspectorate finds two causes",
                            body: "Throughput fell by nineteen percent across all seven regions after the inspection schedule was reorganised in March."
                        ), contentType: "text/html; charset=utf-8")
                    }
                    return .text("not found", status: 404)
                }
                try server.start()
                defer { server.stop() }

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store, title: "Live ingest")

                // The same service the app builds at launch.
                let service = SourceIngestionService(
                    store: store,
                    configuration: .default,
                    embedder: BuiltInEmbedder()
                )
                let result = await service.ingest(
                    request: .website(url: "\(server.baseURL.absoluteString)/article", title: nil),
                    notebookID: notebook.id
                )

                try ctx.equal(result.results.count, 1)
                let outcome = try ctx.unwrap(result.results.first)
                try ctx.isNil(outcome.error, "ingest reported no error")
                try ctx.equal(outcome.source.status, .ready)
                try ctx.check(outcome.chunkCount > 0, "chunks were produced")
                try ctx.check(outcome.embeddingCount > 0, "vectors were produced")
                try ctx.contains(outcome.source.title, "Inspectorate")

                // Stored text, chunks, vectors and the keyword index all exist on disk.
                let stored = try ctx.unwrap(outcome.source.contentPath)
                try ctx.contains(try FileStore.readText(at: URL(fileURLWithPath: stored)), "nineteen percent")
                try ctx.check(try store.chunks(sourceID: outcome.source.id).count == outcome.chunkCount)
                try ctx.check(try store.embeddingCount(notebookID: notebook.id) == outcome.embeddingCount)
                try ctx.check(!(try store.keywordSearch(query: "inspection schedule reorganised", notebookID: notebook.id)).isEmpty)

                // And retrieval finds it.
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let retrieved = try await engine.retrieve(
                    query: "what caused the decline?",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 4)
                )
                try ctx.check(!retrieved.hits.isEmpty, "retrieval found the ingested page")

                // The app must have sent a user agent and respected robots.txt.
                try ctx.check(server.requests.contains { $0.path == "/robots.txt" }, "robots.txt was consulted")
                let article = try ctx.unwrap(server.requests.first { $0.path == "/article" })
                try ctx.contains(article.headers["user-agent"] ?? "", "SourceDesk")
            },

            test("a robots.txt disallow stops the request and explains why") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" {
                        return .text("User-agent: *\nDisallow: /private\n")
                    }
                    return .text("<html><body><p>This should never be fetched.</p></body></html>", contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())

                let result = await service.ingest(
                    request: .website(url: "\(server.baseURL.absoluteString)/private/report", title: nil),
                    notebookID: notebook.id
                )
                let outcome = try ctx.unwrap(result.results.first)
                let error = try ctx.unwrap(outcome.error)
                try ctx.contains(error.errorDescription ?? "", "disallowed by the site's robots.txt")
                try ctx.contains(error.recoverySuggestion ?? "", "pasted text")
                try ctx.equal(outcome.source.status, .failed)
                try ctx.check(!server.requests.contains { $0.path.hasPrefix("/private") }, "the disallowed path was never requested")

                // The failed source is kept, with its explanation, so the user can see it.
                try ctx.equal(try store.sourceCount(notebookID: notebook.id), 1, "a failed source is recorded rather than silently dropped")
            },

            test("a whole research session runs against a local model and produces citations") { ctx in
                // A local "model" that answers from whatever it is given, using the
                // markers SourceDesk assigned — which is what a well-behaved model does.
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" {
                        return .json(["models": [["name": "test-model", "details": ["parameter_size": "3B"]]]])
                    }
                    guard request.path == "/api/chat" else { return .json([:], status: 404) }
                    let messages = (request.json?["messages"] as? [[String: Any]]) ?? []
                    let userContent = messages.last?["content"] as? String ?? ""
                    let systemContent = messages.first?["content"] as? String ?? ""
                    // Echo back proof that the grounding instructions were sent.
                    let sawGrounding = systemContent.contains("GROUNDING RULES")
                    let sawMarkers = userContent.contains("[Source 1]")
                    let answer = sawMarkers
                        ? "Two causes were identified: an administrative reorganisation and a shortage of inspectors. [Source 1]"
                        : "The material does not contain enough information to answer that."
                    let payload = [
                        "message": ["content": (sawGrounding ? "" : "[NO GROUNDING]\n") + answer, "thinking": ""],
                        "done": true,
                        "prompt_eval_count": 900,
                        "eval_count": 40,
                        "done_reason": "stop"
                    ]
                    return .ndjson([(try? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)) ?? "{}"])
                }
                try server.start()
                defer { server.stop() }

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, sources) = try RetrievalSuite.makeCorpus(store)

                let providers = ProviderRegistry(providers: [OllamaProvider(endpoint: server.baseURL)])
                let engine = AnswerEngine(
                    store: store,
                    providers: providers,
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "ollama", modelName: "test-model", scope: .notebookSources)
                )

                let outcome = try await engine.answerOnce(
                    question: "What caused the decline in inspection throughput?",
                    notebookID: notebook.id
                )

                try ctx.contains(outcome.answer, "reorganisation")
                try ctx.doesNotContain(outcome.answer, "[NO GROUNDING]", "the grounding instructions reached the model")
                try ctx.equal(outcome.citations.count, 1, "one citation was resolved")
                try ctx.equal(outcome.citations[0].marker, "[Source 1]")
                try ctx.equal(outcome.citations[0].kind, .notebook)
                try ctx.check(outcome.trace.hits.count > 0, "a retrieval trace was recorded")
                try ctx.check(outcome.usage.promptTokens ?? 0 > 0)
                try ctx.equal(outcome.privacyLevel, .local, "a local model keeps the content local")

                // The cited source must be one of the notebook's real sources.
                let cited = try ctx.unwrap(outcome.citations[0].sourceID)
                try ctx.check(sources.contains { $0.id == cited }, "the citation points at a real source")
            },

            test("a fabricated citation is removed and the problem is reported") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" {
                        return .json(["models": [["name": "test-model", "details": ["parameter_size": "3B"]]]])
                    }
                    let payload = [
                        "message": ["content": "Officials blamed the weather. [Source 7] Throughput fell by nineteen percent. [Source 1]"],
                        "done": true, "done_reason": "stop"
                    ]
                    return .ndjson([(try? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)) ?? "{}"])
                }
                try server.start()
                defer { server.stop() }

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try RetrievalSuite.makeCorpus(store)

                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [OllamaProvider(endpoint: server.baseURL)]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "ollama", modelName: "test-model")
                )
                let outcome = try await engine.answerOnce(question: "What caused the decline?", notebookID: notebook.id)

                try ctx.doesNotContain(outcome.answer, "[Source 7]", "the fabricated marker was stripped from the answer")
                try ctx.contains(outcome.answer, "[Source 1]", "the real citation stayed")
                try ctx.equal(outcome.resolution.hallucinatedMarkers.count, 1)
                try ctx.check(outcome.notices.contains { $0.contains("were not in the retrieved material") },
                              "the user is told: \(outcome.notices)")
            },

            test("notebook-only mode is enforced even when the web would help") { ctx in
                struct BoomSearch: SearchProvider {
                    let identifier = "boom"
                    let displayName = "Boom"
                    let requiresKey = false
                    let isConfigured = true
                    let configurationHint: String? = nil
                    let privacyNote = "never called in this mode"
                    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
                        throw SourceDeskError.webSearchUnavailable(provider: "Boom", reason: "should not have been called")
                    }
                }
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try RetrievalSuite.makeCorpus(store)

                let search = WebSearchService(provider: BoomSearch())
                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
                    embedder: BuiltInEmbedder(),
                    search: search,
                    configuration: .init(providerID: "ollama", modelName: "stub", scope: .notebookSources)
                )
                let outcome = try await engine.answerOnce(question: "what caused the decline", notebookID: notebook.id)
                try ctx.equal(outcome.trace.webResultCount, 0, "web search was not used in notebook-only mode")

                // With the scope flipped, the failing search is reported, not fatal.
                let webEngine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
                    embedder: BuiltInEmbedder(),
                    search: search,
                    configuration: .init(providerID: "ollama", modelName: "stub", scope: .notebookAndWeb)
                )
                let webOutcome = try await webEngine.answerOnce(question: "what caused the decline", notebookID: notebook.id)
                try ctx.check(webOutcome.notices.contains { $0.contains("Web search") },
                              "the search failure is reported alongside a usable answer: \(webOutcome.notices)")
            },

            test("a cloud provider without a key fails with instructions, not a crash") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try RetrievalSuite.makeCorpus(store)

                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [AnthropicProvider(keychain: EmptyKeychain())]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "anthropic", modelName: "claude-sonnet-4-5", cloudConsentGranted: true)
                )
                let error = try await ctx.expectError("missing key") {
                    try await engine.answerOnce(question: "what caused the decline", notebookID: notebook.id)
                }
                let sde = try ctx.unwrap(error as? SourceDeskError)
                try ctx.contains(sde.errorDescription ?? "", "no API key is stored")
                try ctx.contains(sde.recoverySuggestion ?? "", "Keychain")
            },

            test("a cloud model without consent is refused before any content moves") { ctx in
                // The server is present but must never be contacted.
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" { return .json(["models": [["name": "m", "details": [:]]]]) }
                    return .json(["error": "should not have been called"], status: 500)
                }
                try server.start()
                defer { server.stop() }

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try RetrievalSuite.makeCorpus(store)

                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [OpenAIProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "k")]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "openai", modelName: "gpt-4o-mini", cloudConsentGranted: false)
                )
                let error = try await ctx.expectError("no consent") {
                    try await engine.answerOnce(question: "what caused the decline", notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "banner above the composer")
                try ctx.check(!server.requests.contains { $0.path.hasSuffix("chat/completions") },
                              "no request was made without consent")
            },

            test("offline: everything local keeps working, and online features say so") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store, title: "Offline notebook")

                // A source ingested "before" going offline.
                let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())
                let text = Fixtures.longArticle(topic: "the inspection programme", paragraphs: 30)
                let ingested = await service.ingest(
                    request: .pastedText(title: "Offline report", text: text, url: nil),
                    notebookID: notebook.id
                )
                try ctx.check(ingested.results.first?.succeeded == true, "source stored while online")

                // Now build the app-level objects as if the network were down.
                let search = WebSearchService(provider: DuckDuckGoSearchProvider())

                // Local reading works.
                try ctx.check(!(try store.sources(notebookID: notebook.id)).isEmpty, "notebook opens offline")
                let retrieved = try await RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                    .retrieve(query: "what caused the decline in the programme", notebookID: notebook.id)
                try ctx.check(!retrieved.hits.isEmpty, "local search works offline")
                try ctx.check(try store.keywordSearch(query: "budget pressure", notebookID: notebook.id).isEmpty == false,
                              "keyword search works offline")

                // Cloud is refused, with an offline reason.
                let cloudEngine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [OpenAIProvider(keychain: EmptyKeychain(), explicitKey: "k")]),
                    embedder: BuiltInEmbedder(),
                    search: search,
                    configuration: .init(providerID: "openai", modelName: "gpt-4o-mini", cloudConsentGranted: true),
                    networkIsOnline: { false }
                )
                let error = try await ctx.expectError("offline cloud") {
                    try await cloudEngine.answerOnce(question: "x", notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "internet connection")

                // Web search in the answer pipeline is skipped, and the answer still works.
                let localEngine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
                    embedder: BuiltInEmbedder(),
                    search: search,
                    configuration: .init(providerID: "ollama", modelName: "stub", scope: .notebookAndWeb),
                    networkIsOnline: { false }
                )
                let outcome = try await localEngine.answerOnce(question: "what caused the decline", notebookID: notebook.id)
                try ctx.check(outcome.notices.contains { $0.contains("offline") }, "offline is reported: \(outcome.notices)")
                try ctx.check(!outcome.answer.isEmpty, "an answer was still produced from local sources")

                // Website download is refused with the same clarity.
                let downloader = WebDownloader(options: WebDownloader.Options(timeout: 2))
                let fetchError = try await ctx.expectError("no network") {
                    try await downloader.fetch(url: "http://127.0.0.1:9/nothing")
                }
                try ctx.check(fetchError is SourceDeskError)
            },

            test("a source is re-added rather than duplicated, and refreshed") { ctx in
                // The handler runs on the server's thread, so the count is kept in a
                // locked counter rather than a captured `var`.
                let hits = Counter()
                let server = LocalHTTPServer { request in
                    if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
                    hits.increment()
                    return .text(Fixtures.htmlPage(title: "Article", body: "Version \(hits.current) of the article body with enough words to extract properly."),
                                 contentType: "text/html")
                }
                try server.start()
                defer { server.stop() }

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())
                let url = "\(server.baseURL.absoluteString)/page"

                _ = await service.ingest(request: .website(url: url, title: nil), notebookID: notebook.id)
                _ = await service.ingest(request: .website(url: url, title: nil), notebookID: notebook.id)
                _ = await service.ingest(request: .website(url: url, title: nil), notebookID: notebook.id)

                try ctx.equal(try store.sourceCount(notebookID: notebook.id), 1, "three additions produced one source")
                let source = try ctx.unwrap(try store.sources(notebookID: notebook.id).first)
                let stored = try FileStore.readText(at: URL(fileURLWithPath: try ctx.unwrap(source.contentPath)))
                try ctx.contains(stored, "Version 3", "the stored copy is the latest version")
                try ctx.check(try store.chunks(sourceID: source.id).count > 0, "chunks were rebuilt")
            },

            test("a large local document imports, indexes and answers from disk") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)

                // A realistically large Markdown document.
                var lines: [String] = ["# Long report", ""]
                for index in 0..<600 {
                    lines.append("## Section \(index)")
                    lines.append("Paragraph \(index). The inspection programme entered phase \(index) after the review board published findings about throughput, permits and staffing levels in region \(index % 24).")
                    lines.append("Officials cited budget pressure. Analysts cited the reorganisation of the inspection schedule. The backlog of permit applications grew by \(5 + index % 30) percent.")
                    lines.append("")
                }
                let documentText = lines.joined(separator: "\n")
                let fileURL = paths.root.appendingPathComponent("long-report.md")
                try FileStore.write(documentText, to: fileURL)

                let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())
                let start = Date()
                let result = await service.ingest(request: .files([fileURL]), notebookID: notebook.id)
                let elapsed = Date().timeIntervalSince(start)

                let outcome = try ctx.unwrap(result.results.first)
                try ctx.isNil(outcome.error)
                try ctx.check(outcome.chunkCount > 100, "produced \(outcome.chunkCount) chunks")
                try ctx.check(outcome.embeddingCount == outcome.chunkCount, "every chunk was embedded")
                try ctx.check(elapsed < 60, "imported in \(String(format: "%.1f", elapsed))s")
                ctx.note("600-section Markdown: \(outcome.chunkCount) chunks + vectors in \(String(format: "%.1f", elapsed))s")

                // Retrieval and a grounded answer from the large source.
                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "ollama", modelName: "stub",
                                         retrieval: RetrievalConfiguration(resultCount: 6, contextTokenBudget: 3_000))
                )
                let answer = try await engine.answerOnce(question: "what did officials cite as the cause?", notebookID: notebook.id)
                try ctx.check(!answer.trace.hits.isEmpty, "retrieved from the large source")
                try ctx.check(answer.trace.usedTokens <= 3_000, "stayed inside the context budget: \(answer.trace.usedTokens)")
                try ctx.equal(answer.trace.hits.count <= 6, true, "no more passages than requested")
            },

            test("deleting a source then restarting leaves a consistent library") { ctx in
                var paths: AppPaths?
                var notebookID = ""
                var keptSourceID = ""
                do {
                    let (store, p) = try Fixtures.temporaryStore()
                    paths = p
                    let notebook = try Fixtures.makeNotebook(store, title: "Consistency")
                    notebookID = notebook.id

                    let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())
                    for index in 0..<4 {
                        _ = await service.ingest(
                            request: .pastedText(title: "Document \(index)",
                                                 text: String(repeating: "The inspection programme reported finding number \(index). ", count: 40),
                                                 url: nil),
                            notebookID: notebook.id
                        )
                    }
                    var sources = try store.sources(notebookID: notebook.id)
                    try ctx.equal(sources.count, 4, "four sources ingested")
                    keptSourceID = sources[1].id
                    try store.deleteSource(id: sources[0].id)
                    try store.deleteSource(id: sources[3].id)
                    sources = try store.sources(notebookID: notebook.id)
                    try ctx.equal(sources.count, 2, "two sources remain")
                }
                defer { if let paths { Fixtures.cleanup(paths) } }

                // Reopen the library, as a relaunch does.
                let reopened = try NotebookStore(paths: try ctx.unwrap(paths))
                let sources = try reopened.sources(notebookID: notebookID)
                try ctx.equal(sources.count, 2, "the surviving sources are still there")
                try ctx.check(sources.contains { $0.id == keptSourceID }, "the kept source is intact")
                for source in sources {
                    let contentPath = try ctx.unwrap(source.contentPath, "surviving source has a stored text path")
                    try ctx.check(FileStore.exists(URL(fileURLWithPath: contentPath)),
                                  "surviving source “\(source.title)” still has its stored text")
                }
                // No orphaned chunks or vectors anywhere.
                try ctx.equal(try reopened.chunkCount(notebookID: notebookID),
                              sources.reduce(0) { $0 + $1.chunkCount },
                              "chunk rows match the surviving sources exactly")
                try ctx.equal(try reopened.db.integrityCheck(), "ok")
                // And search still works on the survivors.
                try ctx.check(!(try reopened.keywordSearch(query: "inspection programme", notebookID: notebookID)).isEmpty)
            },

            test("the whole app pipeline survives export, import and re-answering") { ctx in
                // 1. Build a notebook with a source, a conversation and a note.
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store, title: "Portable research")
                let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())
                _ = await service.ingest(
                    request: .pastedText(title: "Inspectorate report",
                                         text: Fixtures.longArticle(topic: "inspections", paragraphs: 20),
                                         url: nil),
                    notebookID: notebook.id
                )
                let session = try store.upsert(session: ChatSession(notebookID: notebook.id, title: "Causes"))
                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "ollama", modelName: "stub")
                )
                let answer = try await engine.answerOnce(question: "what caused the decline?", notebookID: notebook.id)
                try store.upsert(message: ChatMessage(
                    sessionID: session.id, notebookID: notebook.id, role: .assistant,
                    content: answer.answer, citations: answer.citations, retrieval: answer.trace
                ))
                try store.upsert(note: NotebookNote(notebookID: notebook.id, title: "Summary", body: "Material covers an inspection decline.", kind: .summary))

                // 2. Export and import into a fresh library.
                let archive = paths.root.appendingPathComponent("portable.nbk")
                let export = try NotebookArchive.export(notebookID: notebook.id, from: store, to: archive)
                try ctx.check(export.byteCount > 0)

                let (destination, destinationPaths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(destinationPaths) }
                let imported = try NotebookArchive.import(from: archive, into: destination)
                try ctx.equal(imported.skipped.count, 0, "nothing was skipped: \(imported.skipped)")

                // 3. Retrieval works in the imported library.
                let restoredEngine = RetrievalEngine(store: destination, embedder: BuiltInEmbedder())
                let retrieved = try await restoredEngine.retrieve(
                    query: "what caused the decline?",
                    notebookID: imported.notebook.id
                )
                try ctx.check(!retrieved.hits.isEmpty, "the imported notebook retrieves")

                // 4. And the restored citations still point at real sources.
                let restoredSourceIDs = Set(try destination.sources(notebookID: imported.notebook.id).map(\.id))
                let restoredSession = try ctx.unwrap(try destination.sessions(notebookID: imported.notebook.id).first)
                let messages = try destination.messages(sessionID: restoredSession.id)
                let assistant = try ctx.unwrap(messages.first { $0.role == .assistant })
                for citation in assistant.citations {
                    if let sourceID = citation.sourceID {
                        try ctx.check(restoredSourceIDs.contains(sourceID),
                                      "citation \(citation.marker) resolves to a restored source")
                    }
                    if let chunkID = citation.chunkID {
                        try ctx.check(!(try destination.chunks(ids: [chunkID])).isEmpty,
                                      "citation chunk \(chunkID) exists in the restored library")
                    }
                }
                // The retrieval trace survived, so the "show your work" panel works after import.
                try ctx.check((assistant.retrieval?.hits.count ?? 0) > 0, "the retrieval trace survived the round trip")
            },

            test("live: a real web page is downloaded, extracted and cited") { ctx in
                guard liveWeb else {
                    ctx.note("skipped: set SOURCEDESK_LIVE_WEB=1 to run against the public internet")
                    return
                }
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store, title: "Live web")

                let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())
                let result = await service.ingest(
                    request: .website(url: "https://example.com/", title: nil),
                    notebookID: notebook.id
                )
                let outcome = try ctx.unwrap(result.results.first)
                if let error = outcome.error {
                    // Network conditions vary; a clear error is an acceptable outcome,
                    // a crash or an empty source is not.
                    ctx.note("live fetch reported: \(error.errorDescription ?? "")")
                    try ctx.check(error.recoverySuggestion != nil, "the failure is actionable")
                    return
                }
                try ctx.check(outcome.chunkCount > 0, "the live page produced chunks")
                try ctx.contains(outcome.source.title.lowercased(), "example")
                try ctx.check(try store.keywordSearch(query: "domain", notebookID: notebook.id).isEmpty == false,
                              "the live page is searchable")
            }
        ])
    }
}
