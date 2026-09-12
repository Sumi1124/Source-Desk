import Foundation
import SourceDeskCore

/// Ad-hoc diagnostics, run explicitly with `--debug-scratch`.
///
/// Kept in the repository because it is genuinely useful: it drives the hosted Ollama
/// API through the same code the app uses, which is how the shape of that endpoint
/// (blank `details`, unauthenticated catalogue, uncompressed sizes) was established.
///
/// It also prints exactly what the toolbar's model menu is built from, provider by
/// provider, so "is the Ollama Cloud choice visible?" is answered by the code that
/// renders it rather than by reading source.
enum DebugScratch {

    static func run() {
        print("--- Ollama Cloud, live ---")
        let provider = OllamaProvider(endpoint: OllamaProvider.cloudEndpoint, host: .cloud, keychain: EmptyKeychain())

        print("identifier:   \(provider.identifier)")
        print("displayName:  \(provider.displayName)")
        print("isLocal:      \(provider.isLocal)")
        print("isConfigured: \(provider.isConfigured)  (no key in the Keychain)")

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let availability = await provider.availability()
            print("availability: \(availability)")

            do {
                let models = try await provider.availableModels()
                print("models:       \(models.count)")
                for model in models {
                    let params: String = model.parameterSize ?? "-"
                    let context: Int = model.contextLength ?? 0
                    let size: String = model.sizeDescription ?? "(not a download)"
                    print("  \(model.name)  params={\(params)}  ctx=\(context)  size=\(size)")
                }
            } catch {
                print("models failed: \(error)")
            }

            do {
                _ = try await provider.generate(AIRequest(messages: [.user("hi")], model: "gpt-oss:120b"))
                print("generate:     UNEXPECTED SUCCESS (is a key configured?)")
            } catch let error as SourceDeskError {
                print("generate err: \(error.errorDescription ?? "")")
                print("  recovery:   \(error.recoverySuggestion ?? "")")
            } catch {
                print("generate err: \(error)")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 45) == .timedOut { print("TIMED OUT") }

        print("")
        print("--- what the toolbar model menu is built from ---")
        // The same registry the app builds, then the same policy the menu renders from.
        // Listing is attempted regardless of configuration, which is the fix under test.
        let registry = ProviderRegistry.standard(
            ollamaEndpoint: URL(string: "http://127.0.0.1:11434")!,
            ollamaCloudEndpoint: OllamaProvider.cloudEndpoint,
            keychain: EmptyKeychain()
        )
        let menuSemaphore = DispatchSemaphore(value: 0)
        Task {
            for provider in registry.all {
                let availability = await provider.availability()
                let models = (try? await provider.availableModels()) ?? []
                let section = ModelMenuPolicy.section(
                    providerID: provider.identifier,
                    displayName: provider.displayName,
                    models: models,
                    availability: availability,
                    hasBeenProbed: true
                )
                print("section \u{201C}\(section.displayName)\u{201D}  models=\(section.rows.count)  usable=\(section.hasUsableModel)")
                if let statusLine = section.statusLine { print("    status: \(statusLine)") }
                if let emptyLine = section.emptyLine { print("    empty:  \(emptyLine)") }
                for row in section.rows.prefix(5) {
                    print("    row: \(row.model.name) — \(row.model.detailLine)")
                }
                if section.rows.count > 5 { print("    \u{2026} \(section.rows.count - 5) more") }
            }
            menuSemaphore.signal()
        }
        if menuSemaphore.wait(timeout: .now() + 60) == .timedOut { print("MENU TIMED OUT") }

        print("")
        print("--- retrieval: does a generic study-tool query find anything? ---")
        let retrievalSemaphore = DispatchSemaphore(value: 0)
        Task {
            let (store, _) = try Fixtures.temporaryStore()
            let notebook = try Fixtures.makeNotebook(store, title: "Retrieval probe")
            let text = "RISC-V was developed in 2010 at the University of California Berkeley. The specification was published openly so any company could implement it without licensing fees. Reduced instruction set computing emerged in the 1970s as a reaction to complex instruction sets."
            var source = Source(notebookID: notebook.id, kind: .website, title: "RISC-V History",
                                wordCount: 40, status: .ready)
            source = try store.upsert(source: source)
            let chunks = TextChunker.chunk(plainText: text, sourceID: source.id, notebookID: notebook.id, configuration: .default)
            let embedder = BuiltInEmbedder()
            let embeddings = chunks.map { ChunkEmbedding(chunkID: $0.id, sourceID: source.id, notebookID: notebook.id, model: embedder.identifier, vector: embedder.embedOne($0.text)) }
            try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: embeddings)
            print("  corpus: \(chunks.count) chunks")

            let retrieval = RetrievalEngine(store: store, embedder: embedder)
            // What the study tools actually ask for: source-scoped, no score floor.
            var studyConfig = RetrievalConfiguration()
            studyConfig.minimumScore = 0
            studyConfig.sourceIDs = [source.id]
            studyConfig.resultCount = 16
            studyConfig.maxChunksPerSource = 10
            let queries = [
                ("specific", "RISC-V origins and licensing"),
                ("keyPoints", "key point finding result important significant evidence detail"),
                ("outline", "overview purpose main argument conclusion finding result")
            ]
            for (label, query) in queries {
                let outcome = try await retrieval.retrieve(query: query, notebookID: notebook.id, configuration: studyConfig)
                print("  [\(label)] hits=\(outcome.hits.count)")
            }
            // And with the default floor, to show the difference.
            let floorOutcome = try await retrieval.retrieve(
                query: "key point finding result important significant evidence detail",
                notebookID: notebook.id,
                configuration: RetrievalConfiguration()
            )
            print("  [default floor] hits=\(floorOutcome.hits.count)")
            // What are the actual similarity scores? The semantic channel keeps only
            // positive cosine scores, which is the suspect.
            let queryVector = try await embedder.embed(["key point finding result important significant evidence detail"]).first
            let stored = try store.embeddings(notebookID: notebook.id)
            print("  stored embeddings: \(stored.count)")
            for embedding in stored {
                let score = VectorMath.cosineSimilarity(queryVector!, embedding.vector)
                print("    cosine for chunk \(embedding.chunkID.prefix(8)) = \(String(format: "%.4f", score))")
            }
            // And the keyword channel in isolation.
            let variants = "key point finding result important significant evidence detail"
            let keyword = (try? store.keywordSearch(query: variants, notebookID: notebook.id, sourceIDs: [source.id], limit: 40)) ?? []
            print("  keyword hits: \(keyword.count)")
            retrievalSemaphore.signal()
        }
        if retrievalSemaphore.wait(timeout: .now() + 40) == .timedOut { print("  retrieval probe TIMED OUT") }

        print("--- LIVE: does asking with Sources + Web actually search the web? ---")
        if ProcessInfo.processInfo.environment["SOURCEDESK_LIVE_WEB"] != "1" {
            print("(set SOURCEDESK_LIVE_WEB=1 to run)")
        } else {
            let liveAsk = DispatchSemaphore(value: 0)
            Task {
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Live ask")
                // A notebook WITH a source, so the bug's condition is reproduced: before
                // the fix, having sources meant the answer never consulted the web.
                let text = "The Thornbury Inspectorate recorded a decline of 43.5 percent in inspection throughput in 1987."
                var source = Source(notebookID: notebook.id, kind: .website, title: "Thornbury report",
                                    wordCount: 20, status: .ready)
                source = try store.upsert(source: source)
                let chunks = TextChunker.chunk(plainText: text, sourceID: source.id,
                                               notebookID: notebook.id, configuration: .default)
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: [])
                print("  notebook has \(chunks.count) chunk(s) of its own")

                // Config says notebook-only (the Settings default); the user asked for web.
                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
                    embedder: BuiltInEmbedder(),
                    search: WebSearchService(provider: DuckDuckGoSearchProvider()),
                    configuration: .init(providerID: "ollama", modelName: "stub", scope: .notebookSources),
                    networkIsOnline: { true }
                )
                let outcome = try await engine.answerOnce(
                    question: "who invented the RISC-V instruction set",
                    notebookID: notebook.id,
                    scope: .notebookAndWeb
                )
                print("  web results used: \(outcome.trace.webResultCount)")
                print("  notebook hits:    \(outcome.trace.hits.count)")
                let webCitations = outcome.citations.filter { $0.kind == .web }
                print("  web citations:    \(webCitations.count)")
                for citation in webCitations.prefix(3) {
                    print("    • \(citation.title) — \(citation.url ?? "-")")
                }
                if outcome.trace.webResultCount == 0 {
                    print("  ✗ WEB SEARCH DID NOT RUN")
                } else {
                    print("  ✓ web search ran and its results reached the answer")
                }
                liveAsk.signal()
            }
            if liveAsk.wait(timeout: .now() + 90) == .timedOut { print("  LIVE ASK TIMED OUT") }
        }

        print("--- LIVE: the DuckDuckGo Instant Answer API through the app's provider ---")
        if ProcessInfo.processInfo.environment["SOURCESK_LIVE_WEB"] != "1"
            && ProcessInfo.processInfo.environment["SOURCEDESK_LIVE_WEB"] != "1" {
            print("(set SOURCEDESK_LIVE_WEB=1 to run)")
        } else {
            let ddgSemaphore = DispatchSemaphore(value: 0)
            Task {
                let provider = DuckDuckGoInstantAnswerProvider()
                for query in ["RISC-V", "industrial revolution", "asdjkhqweoiu zzzz"] {
                    do {
                        let results = try await provider.search(query: query, limit: 5)
                        print("  query \(TextMath.preview(query, limit: 26)): \(results.count) result(s)")
                        for result in results.prefix(3) {
                            print("    • \(TextMath.preview(result.title, limit: 50))")
                            print("      \(result.url)")
                        }
                    } catch let error as SourceDeskError {
                        print("  query \(TextMath.preview(query, limit: 26)): \(error.errorDescription ?? "error")")
                    } catch {
                        print("  query \(TextMath.preview(query, limit: 26)): \(error)")
                    }
                }

                // And the HTML endpoint, which is what topic search uses, for comparison.
                let html = DuckDuckGoSearchProvider()
                do {
                    let results = try await html.search(query: "risc-v history", limit: 5)
                    print("  HTML endpoint: \(results.count) result(s)")
                    for result in results.prefix(3) {
                        print("    • \(TextMath.preview(result.title, limit: 50)) — \(result.url)")
                    }
                } catch {
                    print("  HTML endpoint failed: \(error)")
                }
                ddgSemaphore.signal()
            }
            if ddgSemaphore.wait(timeout: .now() + 90) == .timedOut { print("  DDG PROBE TIMED OUT") }
        }

        print("--- trim-off comparison on a small synthetic page ---")
        do {
            let body = "<p>RISC-V is a free and open standard instruction set architecture based on established reduced instruction set computer principles. It is open and royalty free.</p><p>RISC-V was developed in 2010 at the University of California Berkeley as the fifth generation of the design.</p>"
            let html = """
            <html><head><title>RISC-V</title></head><body>
            <div id="mw-navigation"><div class="vector-menu"><p>Toggle the table of contents RISC-V 31 languages العربية Català Čeština Deutsch Ελληνικά Español Suomi Français עברית Magyar Italiano 日本語 한국어 Nederlands Polski Português Русский Svenska Türkçe Українська 中文 Edit links</p></div></div>
            <div id="content"><p>Appearance move to sidebar hide</p><p>From Wikipedia, the free encyclopedia</p>\(body)</div>
            </body></html>
            """
            var off = HTMLExtractor.Options()
            off.trimBoilerplateHead = false
            off.trimBoilerplateTail = false
            let offOptions = off
            if let doc = try? HTMLExtractor.extract(html: html, url: "https://en.wikipedia.org/wiki/RISC-V", options: offOptions) {
                print("TRIM OFF: \(doc.plainText.count) chars")
                print("  first 300: \(TextMath.preview(doc.plainText, limit: 300))")
                print("  blocks: \(doc.blocks.count)")
                for (i, b) in doc.blocks.prefix(6).enumerated() {
                    print("    [\(i)] \(b.kind) len=\(b.text.count) \(TextMath.preview(b.text, limit: 60))")
                }
            } else {
                print("TRIM OFF: extraction threw")
            }
            if let doc = try? HTMLExtractor.extract(html: html, url: "https://en.wikipedia.org/wiki/RISC-V") {
                print("TRIM ON:  \(doc.plainText.count) chars")
                print("  first 200: \(TextMath.preview(doc.plainText, limit: 200))")
            } else {
                print("TRIM ON:  extraction threw")
            }
        }

        print("--- extractor quality check on a real page ---")
        // A real saved page, so the extractor is judged on real markup rather than a fixture.
        let probePath = ProcessInfo.processInfo.environment["SOURCEDESK_PROBE_HTML"]
            ?? FileManager.default.currentDirectoryPath + "/.build/riscv-sample.html"
        if let html = try? String(contentsOfFile: probePath, encoding: .utf8),
           let document = try? HTMLExtractor.extract(html: html, url: "https://en.wikipedia.org/wiki/RISC-V") {
            let text = document.plainText
            print("extracted \(text.count) chars, title=\(document.title)")
            print("FIRST 400 CHARS:")
            print(String(text.prefix(400)))
            print("")
            print("LAST 300 CHARS:")
            print(String(text.suffix(300)))
            // What are the LEADING blocks, and how big is each? The head of a document
            // is what a model weighs most, so furniture here is costly.
            print("")
            print("LEADING BLOCKS (index, kind, length, preview):")
            for (index, block) in document.blocks.prefix(14).enumerated() {
                let preview = TextMath.preview(block.text, limit: 90)
                print("  [\(index)] \(block.kind) len=\(block.text.count)  \(preview)")
            }
            print("")
            print("FIRST BLOCK WITH >= 200 CHARS:")
            if let firstBig = document.blocks.firstIndex(where: { $0.text.count >= 200 }) {
                print("  index \(firstBig)")
                print("  \(TextMath.preview(document.blocks[firstBig].text, limit: 200))")
            }
        } else {
            print("(no sample HTML at \(probePath) — skipping)")
        }

        print("")
        print("--- LIVE research: real search, real pages ---")
        guard ProcessInfo.processInfo.environment["SOURCEDESK_LIVE_WEB"] == "1" else {
            print("(set SOURCEDESK_LIVE_WEB=1 to run)")
            print("--- done ---")
            return
        }
        let liveSemaphore = DispatchSemaphore(value: 0)
        Task {
            let (store, _) = try Fixtures.temporaryStore()
            let notebook = try Fixtures.makeNotebook(store, title: "Live Research")
            let provider = DuckDuckGoSearchProvider()
            let service = SourceIngestionService(
                store: store,
                configuration: SourceIngestionService.Configuration(embeddingsEnabled: false)
            )
            do {
                let outcome = try await service.searchAndIngest(
                    query: "history of the RISC-V instruction set architecture",
                    provider: provider,
                    notebookID: notebook.id,
                    limit: 3
                )
                print("searched: \(outcome.searched)  added: \(outcome.added.count)  failed: \(outcome.failed.count)")
                print("notice:   \(outcome.notice ?? "-")")
                for source in outcome.added {
                    let chunks = try store.chunks(sourceID: source.id)
                    let bytes = source.plainTextBytes
                    print("  ✓ \(source.title)")
                    print("      \(source.url ?? "-")")
                    print("      chunks=\(chunks.count) text=\(bytes) bytes status=\(source.status)")
                    if let first = chunks.first {
                        print("      first chunk: \(TextMath.preview(first.text, limit: 110))")
                    }
                }
                for failure in outcome.failed {
                    print("  ✗ \(failure.url): \(failure.error?.errorDescription ?? "unknown")")
                }
            } catch {
                print("live research threw: \(error)")
            }
            liveSemaphore.signal()
        }
        if liveSemaphore.wait(timeout: .now() + 150) == .timedOut { print("LIVE TIMED OUT") }

        print("--- done ---")
    }
}
