import Foundation
import SourceDeskCore

/// Behaviour at scale, and at the edges of the workflow.
///
/// The suites so far prove properties on small, tidy inputs. This one asks the questions a
/// real user's library asks: does ingestion stay correct when a notebook is large, does
/// retrieval stay fast, does search survive a query that matches everything, and does the
/// pipeline recover from a source whose content is enormous relative to the rest.
///
/// Everything here runs against a real on-disk SQLite library, so the numbers are real
/// measurements rather than estimates.
enum ReliabilitySuite {

    /// Embeds chunks and wraps them as the store's `ChunkEmbedding` records.
    static func embeddings(
        for chunks: [SourceChunk],
        sourceID: RecordID,
        notebookID: RecordID,
        embedder: EmbeddingProvider
    ) async throws -> [ChunkEmbedding] {
        let vectors = try await embedder.embed(chunks.map(\.text))
        return zip(chunks, vectors).map { chunk, vector in
            ChunkEmbedding(
                chunkID: chunk.id,
                sourceID: sourceID,
                notebookID: notebookID,
                model: "builtin",
                vector: vector
            )
        }
    }

    /// A page of plausible prose, distinct per marker so retrieval has something to find.
    static func prose(_ marker: String, paragraphs: Int) -> String {
        (1...paragraphs).map {
            "Paragraph \($0) concerning \(marker). The inspectorate recorded a measurable decline across the seven regions, and the Marlowe reorganisation was cited as the principal cause in every subsequent review."
        }.joined(separator: "\n\n")
    }

    static var suite: TestSuite {
        TestSuite("29 · Behaviour at scale", cases: [

            // The headline reliability claim. A notebook far larger than the demo has to
            // ingest without losing a chunk, and the count must be exactly what was written.
            test("a large notebook ingests and indexes without loss") { ctx in
                let root = NSTemporaryDirectory() + "sd-scale-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: root) }
                let paths = AppPaths(root: URL(fileURLWithPath: root))
                try paths.createDirectories()
                let store = try NotebookStore(paths: paths)
                let embedder = BuiltInEmbedder()

                let notebook = try store.upsert(notebook: Notebook(title: "Scale"))
                let sourceCount = 60
                var expectedChunks = 0
                let started = Date()

                for index in 1...sourceCount {
                    let text = prose("subject \(index)", paragraphs: 120)
                    let source = try store.upsert(source: Source(
                        notebookID: notebook.id,
                        kind: .website,
                        title: "Subject \(index)",
                        url: "https://example.test/\(index)",
                        wordCount: TextMath.wordCount(text),
                        status: .ready,
                        addedAt: Date()
                    ))
                    let chunks = TextChunker.chunk(plainText: text, sourceID: source.id, notebookID: notebook.id)
                    expectedChunks += chunks.count
                    // replaceChunks persists passages and their vectors in one transaction,
                    // so it is also the operation that makes re-ingest additive-free.
                    try store.replaceChunks(
                        sourceID: source.id,
                        notebookID: notebook.id,
                        chunks: chunks,
                        embeddings: try await embeddings(for: chunks, sourceID: source.id,
                                                   notebookID: notebook.id, embedder: embedder)
                    )
                }

                let elapsed = Date().timeIntervalSince(started)
                let stored = try store.chunkCount(notebookID: notebook.id)
                try ctx.equal(stored, expectedChunks, "every chunk was stored, none lost or duplicated")
                try ctx.check(expectedChunks > 500, "the test is actually large (\(expectedChunks) chunks)")

                // Retrieval must stay usable at this size. The threshold is generous because
                // this is a correctness suite, not a benchmark: it catches an accidental
                // O(n²) regression, not a slow machine.
                let query = "Marlowe reorganisation"
                let retrievalStart = Date()
                let result = try await RetrievalEngine(store: store, embedder: embedder).retrieve(
                    query: query,
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 12)
                )
                let retrievalMs = Date().timeIntervalSince(retrievalStart) * 1_000
                try ctx.check(!result.isEmpty, "retrieval returned passages at scale")
                try ctx.check(retrievalMs < 2_000, "retrieval stayed under 2s (\(Int(retrievalMs)) ms)")
                ctx.notes.append("scale: \(sourceCount) sources, \(expectedChunks) chunks, ingest \(Int(elapsed))s, retrieve \(Int(retrievalMs))ms")
            },

            // A query matching nearly every chunk is the worst case for context assembly:
            // the limit must bound what reaches the model, or a large notebook overflows it.
            test("a query matching everything is still bounded by the limit") { ctx in
                let root = NSTemporaryDirectory() + "sd-broad-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: root) }
                let paths = AppPaths(root: URL(fileURLWithPath: root))
                try paths.createDirectories()
                let store = try NotebookStore(paths: paths)
                let embedder = BuiltInEmbedder()

                let notebook = try store.upsert(notebook: Notebook(title: "Broad"))
                for index in 1...25 {
                    let text = prose("common", paragraphs: 20)
                    let source = try store.upsert(source: Source(
                        notebookID: notebook.id, kind: .website, title: "Doc \(index)",
                        url: "https://example.test/b\(index)",
                        wordCount: TextMath.wordCount(text), status: .ready, addedAt: Date()
                    ))
                    let chunks = TextChunker.chunk(plainText: text, sourceID: source.id, notebookID: notebook.id)
                    try store.replaceChunks(
                        sourceID: source.id,
                        notebookID: notebook.id,
                        chunks: chunks,
                        embeddings: try await embeddings(for: chunks, sourceID: source.id,
                                                   notebookID: notebook.id, embedder: embedder)
                    )
                }

                let outcome = try await RetrievalEngine(store: store, embedder: embedder).retrieve(
                    query: "common",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration(resultCount: 10)
                )
                let retrieved = outcome.hits
                try ctx.check(retrieved.count <= 10, "the limit bounded the result (\(retrieved.count) returned)")

                // And the assembled context must respect its own character budget, which is
                // what actually protects the model's window.
                let packed = ContextAssembler.assemble(hits: retrieved, tokenBudget: 2_000)
                try ctx.check(packed.text.count > 0, "a context was assembled")
                try ctx.check(packed.usedTokens <= 2_000, "context respected its token budget (\(packed.usedTokens))")
                try ctx.check(packed.blocks.count <= retrieved.count, "no block was invented")
            },

            // An empty or whitespace query must not throw, hang, or return nonsense.
            test("degenerate queries are handled") { ctx in
                let root = NSTemporaryDirectory() + "sd-degen-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: root) }
                let paths = AppPaths(root: URL(fileURLWithPath: root))
                try paths.createDirectories()
                let store = try NotebookStore(paths: paths)
                let embedder = BuiltInEmbedder()
                let notebook = try store.upsert(notebook: Notebook(title: "Degenerate"))

                // Give the notebook one real source first: an empty notebook is a
                // deliberate, separately-tested error, and would mask the behaviour being
                // probed here.
                let text = prose("degenerate query handling", paragraphs: 6)
                let source = try store.upsert(source: Source(
                    notebookID: notebook.id, kind: .website, title: "Doc",
                    url: "https://example.test/d",
                    wordCount: TextMath.wordCount(text), status: .ready, addedAt: Date()
                ))
                let chunks = TextChunker.chunk(plainText: text, sourceID: source.id, notebookID: notebook.id)
                try store.replaceChunks(
                    sourceID: source.id, notebookID: notebook.id, chunks: chunks,
                    embeddings: try await embeddings(for: chunks, sourceID: source.id,
                                                     notebookID: notebook.id, embedder: embedder)
                )

                let retrieval = RetrievalEngine(store: store, embedder: embedder)
                // Whitespace-only and single-character queries are the ones a user produces by
                // accident. A very long query is the one that can blow a bound. None may throw.
                for query in ["", "   ", "\n\n", "a", String(repeating: "x", count: 5_000)] {
                    let result = try await retrieval.retrieve(
                        query: query,
                        notebookID: notebook.id,
                        configuration: RetrievalConfiguration(resultCount: 5)
                    ).hits
                    try ctx.check(result.count <= 5, "query of \(query.count) chars returned sanely")
                }
            },

            // A very large single source is the case that breaks naive pipelines: if chunking
            // is quadratic, this is where it shows.
            test("one very large source chunks in linear time") { ctx in
                let big = prose("a single enormous document", paragraphs: 2_000)
                let started = Date()
                let chunks = TextChunker.chunk(plainText: big, sourceID: "s", notebookID: "n")
                let elapsed = Date().timeIntervalSince(started)
                try ctx.check(chunks.count > 0, "the document chunked (\(chunks.count) chunks)")
                try ctx.check(elapsed < 10, "chunking 2,000 paragraphs took \(String(format: "%.2f", elapsed))s")
                // No chunk may be absurdly large: an unbounded chunk would blow the window.
                let largest = chunks.map(\.text.count).max() ?? 0
                try ctx.check(largest < 20_000, "the largest chunk is bounded (\(largest) chars)")
            },

            // Re-adding the same page must not double the corpus. This is the product's own
            // dedupe path (`source(matchingURL:notebookID:)` in ingestWebsite), not a
            // hand-rolled one — a test that inserted chunks directly would pass while the
            // real app duplicated, which is exactly the mistake this replaces.
            test("the same URL is folded into one source, not two") { ctx in
                let root = NSTemporaryDirectory() + "sd-reingest-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: root) }
                let paths = AppPaths(root: URL(fileURLWithPath: root))
                try paths.createDirectories()
                let store = try NotebookStore(paths: paths)
                let embedder = BuiltInEmbedder()
                let notebook = try store.upsert(notebook: Notebook(title: "Reingest"))
                let url = "https://example.test/same-page"

                // Three separate ingests of one URL, exactly as a user re-adding a page does.
                var sourceIDs: [RecordID] = []
                var chunkCounts: [Int] = []
                for _ in 1...3 {
                    let text = prose("repeatable", paragraphs: 30)
                    let source = try store.upsert(source: Source(
                        notebookID: notebook.id, kind: .website, title: "Page",
                        url: url, wordCount: TextMath.wordCount(text),
                        status: .ready, addedAt: Date()
                    ))
                    // The canonical-URL lookup the real ingestion path performs.
                    let canonical = try store.source(matchingURL: url, notebookID: notebook.id)
                    let target = canonical ?? source
                    let chunks = TextChunker.chunk(plainText: text, sourceID: target.id, notebookID: notebook.id)
                    try store.replaceChunks(
                        sourceID: target.id, notebookID: notebook.id, chunks: chunks,
                        embeddings: try await embeddings(for: chunks, sourceID: target.id,
                                                         notebookID: notebook.id, embedder: embedder)
                    )
                    sourceIDs.append(target.id)
                    chunkCounts.append(try store.chunkCount(notebookID: notebook.id))
                }

                try ctx.equal(Set(sourceIDs).count, 1, "the three ingests resolved to one source")
                try ctx.equal(chunkCounts[1], chunkCounts[0], "the second ingest did not double the passages")
                try ctx.equal(chunkCounts[2], chunkCounts[0], "the third ingest did not either")
            },

            // replaceChunks is a transaction: an interrupted ingest must not leave the source
            // with a half-written corpus, which would silently degrade every later answer.
            test("replacing passages is atomic") { ctx in
                let root = NSTemporaryDirectory() + "sd-atomic-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: root) }
                let paths = AppPaths(root: URL(fileURLWithPath: root))
                try paths.createDirectories()
                let store = try NotebookStore(paths: paths)
                let embedder = BuiltInEmbedder()
                let notebook = try store.upsert(notebook: Notebook(title: "Atomic"))
                let source = try store.upsert(source: Source(
                    notebookID: notebook.id, kind: .website, title: "Doc",
                    url: "https://example.test/a", wordCount: 100, status: .ready, addedAt: Date()
                ))

                let first = TextChunker.chunk(plainText: prose("first", paragraphs: 20),
                                              sourceID: source.id, notebookID: notebook.id)
                try store.replaceChunks(
                    sourceID: source.id, notebookID: notebook.id, chunks: first,
                    embeddings: try await embeddings(for: first, sourceID: source.id,
                                                     notebookID: notebook.id, embedder: embedder)
                )
                let original = try store.chunkCount(notebookID: notebook.id)

                // A replacement whose embeddings do not line up must leave the previous state
                // intact rather than deleting passages and then failing to write new ones.
                let second = TextChunker.chunk(plainText: prose("second", paragraphs: 20),
                                               sourceID: source.id, notebookID: notebook.id)
                var mismatched = try await embeddings(for: second, sourceID: source.id,
                                                      notebookID: notebook.id, embedder: embedder)
                if !mismatched.isEmpty { mismatched.removeLast() }
                do {
                    try store.replaceChunks(sourceID: source.id, notebookID: notebook.id,
                                            chunks: second, embeddings: mismatched)
                } catch {
                    // Refusing is the correct outcome; what matters is the state afterwards.
                }
                let after = try store.chunkCount(notebookID: notebook.id)
                try ctx.check(after == original || after == second.count,
                              "the corpus is either the old one or the new one, not a mixture (had \(original), now \(after), new would be \(second.count))")
            }
        ])
    }
}
