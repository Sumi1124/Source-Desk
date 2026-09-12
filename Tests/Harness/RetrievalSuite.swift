import Foundation
import SourceDeskCore

enum RetrievalSuite {

    /// Builds a notebook with several realistic sources, chunked and embedded the
    /// same way the app does it.
    static func makeCorpus(_ store: NotebookStore) throws -> (Notebook, [Source]) {
        let notebook = try Fixtures.makeNotebook(store, title: "Industrial Decline")
        var sources: [Source] = []

        let documents: [(String, SourceKind, String, String?)] = [
            ("Inspectorate Annual Report", .pdf, """
            # Findings
            The review board examined inspection throughput across all seven regions.
            Throughput fell by nineteen percent after the inspection schedule was reorganised in March.
            The board identified two causes: an administrative reorganisation and a shortage of qualified inspectors.
            Budget pressure meant two regional offices closed, concentrating work in the remaining four.
            Permit applications took an average of forty one days to process in the following quarter.
            ## Recommendations
            The board recommended retaining the regional offices and recruiting twelve additional inspectors.
            """, "https://inspectorate.example.gov/report-2024"),
            ("News: Permits slow to a crawl", .website, """
            Applicants in the northern region waited more than six weeks for a routine permit this spring.
            Officials blamed staffing shortages and a new centralised scheduling system introduced in March.
            Independent analysts argued the decline began earlier, when the central office reorganised its inspection schedule.
            A spokesperson said the backlog would be cleared within ninety days.
            """, "https://news.example.com/permits-delay"),
            ("Academic paper: Administrative reform and regulatory output", .docx, """
            # Abstract
            This study examines regulatory output following administrative reorganisation.
            Using inspection logs from 2015 to 2024, we find a persistent decline in throughput of seventeen to twenty two percent.
            We argue the effect is driven by coordination costs rather than budget constraints alone.
            ## Method
            We compared inspection logs with the previous baseline and controlled for regional staffing levels.
            """, nil),
            ("Unrelated source about museum funding", .plainText, """
            The municipal museum secured a three year funding agreement with the regional arts council.
            Visitor numbers rose by eleven percent following the new exhibition on textile history.
            The director said the museum would extend its opening hours on weekends.
            """, nil)
        ]

        for (title, kind, text, url) in documents {
            var source = Source(
                notebookID: notebook.id, kind: kind, title: title, url: url,
                wordCount: TextMath.wordCount(text), status: .ready
            )
            // The source row must exist before its chunks: `chunks.source_id` is a
            // foreign key, exactly as it is in the app.
            source = try store.upsert(source: source)
            let document = ExtractedDocument(
                title: title, method: "test",
                pages: [ExtractedPage(number: kind == .pdf ? 1 : 0, blocks: Markdownish.parse(text))]
            )
            let chunks = TextChunker.chunk(document: document, sourceID: source.id, notebookID: notebook.id,
                                           configuration: TextChunker.Configuration(targetTokens: 90, maximumTokens: 160, overlapTokens: 20, minimumCharacters: 20))
            let embeddings = try awaitBuiltIn(chunks)
            try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: embeddings)
            source.chunkCount = chunks.count
            try? FileStore.write(text, to: store.paths.extractedTextURL(for: source.id))
            source.contentPath = store.paths.extractedTextURL(for: source.id).path
            sources.append(try store.upsert(source: source))
        }
        return (notebook, sources)
    }

    static func awaitBuiltIn(_ chunks: [SourceChunk]) throws -> [ChunkEmbedding] {
        let embedder = BuiltInEmbedder()
        return chunks.map { chunk in
            ChunkEmbedding(chunkID: chunk.id, sourceID: chunk.sourceID, notebookID: chunk.notebookID,
                           model: embedder.identifier, vector: embedder.embedOne(chunk.text))
        }
    }

    static var suite: TestSuite {
        TestSuite("6 · Retrieval (hybrid RAG)", cases: [

            test("finds the passage that answers the question") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try makeCorpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())

                let outcome = try await engine.retrieve(
                    query: "what caused the decline in inspection throughput?",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 5, semanticEnabled: true, keywordEnabled: true, rerank: .lexical)
                )
                try ctx.check(!outcome.hits.isEmpty, "retrieved something")
                let combined = outcome.hits.map(\.chunk.text).joined(separator: " ")
                try ctx.contains(combined, "reorganis", "the cause passage is retrieved")
                try ctx.check(outcome.trace.semanticEnabled, "semantic search ran")
                try ctx.check(outcome.trace.keywordEnabled, "keyword search ran")
                try ctx.check(outcome.trace.rerankEnabled, "reranking ran")
            },

            test("the museum source does not outrank the relevant ones") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try makeCorpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let outcome = try await engine.retrieve(
                    query: "why did permit processing slow down?",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 4)
                )
                let titles = outcome.hits.map(\.sourceTitle)
                try ctx.check(!titles.contains("Unrelated source about museum funding"),
                              "unrelated source excluded, got \(titles)")
            },

            test("per-source diversity stops one long document dominating") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                // One source with 40 chunks, one with 2, all about the same topic.
                let big = try store.upsert(source: Source(notebookID: notebook.id, kind: .pdf, title: "Big report", status: .ready))
                let small = try store.upsert(source: Source(notebookID: notebook.id, kind: .website, title: "Short notice", status: .ready))
                let embedder = BuiltInEmbedder()

                let bigChunks = (0..<40).map { SourceChunk(sourceID: big.id, notebookID: notebook.id, ordinal: $0,
                                                          text: "The inspection backlog grew because permits were delayed by the scheduling system, item \($0).") }
                let smallChunks = (0..<2).map { SourceChunk(sourceID: small.id, notebookID: notebook.id, ordinal: $0,
                                                            text: "Permits were delayed because the scheduling system changed and inspectors were short.") }
                try store.replaceChunks(sourceID: big.id, notebookID: notebook.id, chunks: bigChunks,
                                        embeddings: bigChunks.map { ChunkEmbedding(chunkID: $0.id, sourceID: big.id, notebookID: notebook.id, model: embedder.identifier, vector: embedder.embedOne($0.text)) })
                try store.replaceChunks(sourceID: small.id, notebookID: notebook.id, chunks: smallChunks,
                                        embeddings: smallChunks.map { ChunkEmbedding(chunkID: $0.id, sourceID: small.id, notebookID: notebook.id, model: embedder.identifier, vector: embedder.embedOne($0.text)) })
                try store.upsert(source: big)
                try store.upsert(source: small)

                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let outcome = try await engine.retrieve(
                    query: "why were permits delayed?",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 6, maxChunksPerSource: 2)
                )
                let sourceIDs = Set(outcome.hits.map(\.sourceID))
                try ctx.equal(sourceIDs.count, 2, "both sources are represented")
                let bigCount = outcome.hits.filter { $0.sourceID == big.id }.count
                try ctx.check(bigCount <= 2, "cap respected, got \(bigCount) from the long source")
            },

            test("keyword-only retrieval still works with a broken embedder") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try makeCorpus(store)
                let engine = RetrievalEngine(store: store, embedder: ExplodingEmbedder())
                let outcome = try await engine.retrieve(
                    query: "inspection schedule reorganised",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 4, semanticEnabled: true)
                )
                try ctx.check(!outcome.hits.isEmpty, "keyword search carried the query")
                try ctx.equal(outcome.trace.semanticEnabled, false, "semantic was skipped")
                try ctx.check(outcome.notices.contains { $0.lowercased().contains("semantic") },
                              "the degradation is reported: \(outcome.notices)")
            },

            test("retrieval without embeddings is reported, not silent") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try makeCorpus(store)
                let engine = RetrievalEngine(store: store, embedder: nil)
                let outcome = try await engine.retrieve(query: "what caused the decline", notebookID: notebook.id)
                try ctx.check(!outcome.hits.isEmpty, "keyword retrieval found the answer")
                try ctx.check(outcome.notices.contains { $0.contains("Embeddings are turned off") },
                              "explains why semantic was skipped: \(outcome.notices)")
            },

            test("a query with no match returns nothing and says so") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try makeCorpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let outcome = try await engine.retrieve(
                    query: "zzzqqq xylophone marmalade",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(minimumScore: 0.9)
                )
                try ctx.check(outcome.hits.count <= 2, "no strong matches, got \(outcome.hits.count)")
                try ctx.check(!outcome.trace.notes.isEmpty, "the trace records what happened")
            },

            test("an empty notebook produces a clear error") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let error = try await ctx.expectError("no sources") {
                    try await engine.retrieve(query: "anything", notebookID: notebook.id)
                }
                let message = (error as? SourceDeskError)?.errorDescription ?? "\(error)"
                try ctx.contains(message, "no sources")
                let recovery = (error as? SourceDeskError)?.recoverySuggestion ?? ""
                try ctx.contains(recovery, "Add a website")
            },

            test("source scoping restricts retrieval to chosen sources") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, sources) = try makeCorpus(store)
                let onlyMuseum = try ctx.unwrap(sources.first { $0.title.contains("museum") })
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let outcome = try await engine.retrieve(
                    query: "what caused the decline in inspections?",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 5, sourceIDs: [onlyMuseum.id])
                )
                try ctx.check(outcome.hits.allSatisfy { $0.sourceID == onlyMuseum.id },
                              "only the scoped source was used")
            },

            test("a source excluded from retrieval is skipped") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, sources) = try makeCorpus(store)
                var report = try ctx.unwrap(sources.first { $0.title.contains("Inspectorate") })
                report.includeInRetrieval = false
                try store.upsert(source: report)

                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let outcome = try await engine.retrieve(query: "review board findings", notebookID: notebook.id)
                try ctx.check(outcome.hits.allSatisfy { $0.sourceID != report.id },
                              "the excluded source was not retrieved")
            },

            test("reranking reorders by how well a passage answers the question") { ctx in
                let candidates = [
                    RetrievedChunk(
                        chunk: SourceChunk(sourceID: "a", notebookID: "n", ordinal: 0,
                                           text: "The museum extended its weekend opening hours after the textile exhibition.",
                                           headingPath: "Museum"),
                        sourceID: "a", sourceTitle: "Museum", fusedScore: 0.9
                    ),
                    RetrievedChunk(
                        chunk: SourceChunk(sourceID: "b", notebookID: "n", ordinal: 0,
                                           text: "Budget pressure and a shortage of qualified inspectors caused the decline in inspection throughput.",
                                           headingPath: "Causes"),
                        sourceID: "b", sourceTitle: "Report", fusedScore: 0.6
                    )
                ]
                let ranked = LexicalReranker.rerank(query: "what caused the decline in inspection throughput", candidates: candidates)
                try ctx.equal(ranked.first?.sourceID, "b", "the passage that answers the question wins despite a lower fused score")
                try ctx.check((ranked.first?.rerankScore ?? 0) > (ranked.last?.rerankScore ?? 1), "scores are ordered")
            },

            test("context assembly assigns markers that match the citations") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try makeCorpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let outcome = try await engine.retrieve(query: "what caused the decline", notebookID: notebook.id,
                                                        configuration: RetrievalConfiguration(resultCount: 4))

                let context = ContextAssembler.assemble(hits: outcome.hits, tokenBudget: 3_000)
                try ctx.equal(context.citations.count, outcome.hits.count, "one citation per hit")
                try ctx.equal(context.citations.map(\.marker), (1...outcome.hits.count).map { "[Source \($0)]" },
                              "markers are sequential")
                for citation in context.citations {
                    try ctx.contains(context.text, citation.marker, "marker \(citation.marker) appears in the context")
                    try ctx.check(!citation.excerpt.isEmpty, "citation carries an excerpt")
                }
                try ctx.contains(context.text, "NOTEBOOK SOURCES")
                try ctx.check(context.hasNotebookMaterial)
                try ctx.equal(context.hasWebMaterial, false)
            },

            test("context respects the token budget") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try makeCorpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())
                let outcome = try await engine.retrieve(query: "inspection throughput decline causes permits",
                                                        notebookID: notebook.id,
                                                        configuration: RetrievalConfiguration(resultCount: 20, contextTokenBudget: 400_000))
                let context = ContextAssembler.assemble(hits: outcome.hits, tokenBudget: 120)
                try ctx.check(context.usedTokens <= 300, "budget respected, used \(context.usedTokens)")
                try ctx.check(context.citations.count >= 1, "at least one passage still included")
            }
        ])
    }
}
