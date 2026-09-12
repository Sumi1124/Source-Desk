import Foundation
import SourceDeskCore

/// Whole-document retrieval.
///
/// A tool like "Summarize", "Key Points" or "Outline" does not have a question — it has
/// a request for the notebook itself, and its query is synthesised from boilerplate
/// ("key point finding result important significant evidence"). That text appears nowhere
/// in the user's sources, so both retrieval channels legitimately came up empty and the
/// tool failed with "Not enough relevant source material was found".
///
/// Measured cause: the built-in embedder gave a negative cosine score for such a query
/// (so the semantic channel, which keeps only positive scores, dropped it) and FTS5 found
/// no keyword match. Both channels returning nothing is correct for a *question*, and the
/// bug was treating a whole-document request the same way.
enum WholeDocumentSuite {

    static func corpus(_ store: NotebookStore) throws -> (Notebook, Source) {
        let notebook = try Fixtures.makeNotebook(store, title: "Whole document")
        let text = """
        RISC-V was developed in 2010 at the University of California, Berkeley. The project \
        began inside a research programme into parallel computing, and the fifth generation of \
        the design gave the architecture its name. The specification was published openly so \
        that any company could implement it without paying licensing fees, which is the property \
        that distinguishes RISC-V from proprietary instruction set architectures. \
        Reduced instruction set computing emerged in the 1970s as a reaction to increasingly \
        complex instruction sets, on the insight that a small simple instruction set could run \
        faster and use less silicon than a large one.
        """
        var source = Source(notebookID: notebook.id, kind: .website, title: "RISC-V History",
                            wordCount: TextMath.wordCount(text), status: .ready)
        source = try store.upsert(source: source)
        let chunks = TextChunker.chunk(plainText: text, sourceID: source.id,
                                       notebookID: notebook.id, configuration: .default)
        let embedder = BuiltInEmbedder()
        let embeddings = chunks.map { chunk in
            ChunkEmbedding(chunkID: chunk.id, sourceID: source.id, notebookID: notebook.id,
                           model: embedder.identifier, vector: embedder.embedOne(chunk.text))
        }
        try store.replaceChunks(sourceID: source.id, notebookID: notebook.id,
                                chunks: chunks, embeddings: embeddings)
        source.chunkCount = chunks.count
        _ = try store.upsert(source: source)
        return (notebook, source)
    }

    static var suite: TestSuite {
        TestSuite("19 · Whole-document retrieval", cases: [

            test("a boilerplate whole-document query still finds the notebook's passages") { ctx in
                let (store, _) = try Fixtures.temporaryStore()
                let (notebook, source) = try corpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())

                // The exact shape of query the study tools synthesise, with the score
                // floor removed, which is how those tools ask for breadth.
                var configuration = RetrievalConfiguration()
                configuration.minimumScore = 0
                configuration.sourceIDs = [source.id]
                configuration.resultCount = 16
                configuration.maxChunksPerSource = 10

                for query in ["key point finding result important significant evidence detail",
                              "overview purpose main argument conclusion finding result"] {
                    let outcome = try await engine.retrieve(
                        query: query, notebookID: notebook.id, configuration: configuration
                    )
                    try ctx.check(!outcome.hits.isEmpty,
                                  "a whole-document request returns material: “\(TextMath.preview(query, limit: 30))”")
                    for hit in outcome.hits {
                        try ctx.equal(hit.chunk.notebookID, notebook.id)
                    }
                }
            },

            test("the fallback is reported rather than hidden") { ctx in
                // If the only reason an answer exists is that retrieval gave up and used
                // everything, the user should be able to see that.
                let (store, _) = try Fixtures.temporaryStore()
                let (notebook, source) = try corpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())

                var configuration = RetrievalConfiguration()
                configuration.minimumScore = 0
                configuration.sourceIDs = [source.id]

                let outcome = try await engine.retrieve(
                    query: "overview purpose main argument conclusion finding result",
                    notebookID: notebook.id, configuration: configuration
                )
                try ctx.check(!outcome.hits.isEmpty)
                let notices = outcome.notices + outcome.trace.notes
                try ctx.check(notices.contains { $0.lowercased().contains("document order") },
                              "the breadth fallback says so")
            },

            test("a real question is not padded with irrelevant passages") { ctx in
                // The other half of the rule: a genuine question keeps the default score
                // floor, and must still be allowed to answer "nothing relevant here".
                // Padding an answer with unrelated text would be worse than saying so.
                let (store, _) = try Fixtures.temporaryStore()
                let (notebook, _) = try corpus(store)
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())

                let outcome = try await engine.retrieve(
                    query: "quantum chromodynamics lattice gauge renormalisation",
                    notebookID: notebook.id,
                    configuration: RetrievalConfiguration() // default floor
                )
                try ctx.check(outcome.hits.isEmpty,
                              "an unrelated question returns nothing rather than the whole notebook")
            },

            test("a notebook with no sources is refused before it reaches retrieval") { ctx in
                // Retrieval declines an empty notebook rather than returning an empty
                // list, so the caller gets "this notebook has no sources" instead of a
                // vague "nothing found". Either way it must not invent material.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Empty")
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())

                var configuration = RetrievalConfiguration()
                configuration.minimumScore = 0

                var caught: SourceDeskError?
                do {
                    _ = try await engine.retrieve(
                        query: "overview purpose main argument", notebookID: notebook.id,
                        configuration: configuration
                    )
                } catch let error as SourceDeskError {
                    caught = error
                }
                let error = try ctx.unwrap(caught, "an empty notebook is reported, not silently answered")
                try ctx.contains(error.errorDescription ?? "", "no sources")
            },

            test("a source with no chunks yields nothing rather than a phantom result") { ctx in
                // The case the empty-notebook guard does not cover: a source row exists
                // (a failed import, say) but has no indexed passages. Breadth must not
                // fabricate a hit from it.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Chunkless")
                _ = try store.upsert(source: Source(notebookID: notebook.id, kind: .website,
                                                    title: "Failed import", status: .failed))
                let engine = RetrievalEngine(store: store, embedder: BuiltInEmbedder())

                var configuration = RetrievalConfiguration()
                configuration.minimumScore = 0
                let outcome = try await engine.retrieve(
                    query: "overview purpose main argument", notebookID: notebook.id,
                    configuration: configuration
                )
                try ctx.check(outcome.hits.isEmpty, "no passages were invented")
            },

            test("passages come back in reading order, not an arbitrary one") { ctx in
                // With breadth, sequence matters: the model should read the notebook the
                // way a person would, source by source and chunk by chunk.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Ordered")
                for index in 1...3 {
                    let text = "Document \(index) part one about the topic with plenty of words. Document \(index) part two continuing the same subject in more detail so it chunks."
                    var source = Source(notebookID: notebook.id, kind: .website,
                                        title: "Doc \(index)", status: .ready)
                    source = try store.upsert(source: source)
                    let chunks = TextChunker.chunk(plainText: text, sourceID: source.id,
                                                   notebookID: notebook.id, configuration: .default)
                    try store.replaceChunks(sourceID: source.id, notebookID: notebook.id,
                                            chunks: chunks, embeddings: [])
                }

                let all = try store.chunks(notebookID: notebook.id)
                try ctx.check(!all.isEmpty)
                // Ordinals restart per source, so the grouping is what is asserted: all of
                // one source's chunks, in order, before the next source's.
                var seenSourceOrder: [RecordID] = []
                for chunk in all where seenSourceOrder.last != chunk.sourceID {
                    try ctx.check(!seenSourceOrder.contains(chunk.sourceID),
                                  "a source's chunks are not split across the result")
                    seenSourceOrder.append(chunk.sourceID)
                }
                for sourceID in seenSourceOrder {
                    let ordinals = all.filter { $0.sourceID == sourceID }.map(\.ordinal)
                    try ctx.equal(ordinals, ordinals.sorted(),
                                  "chunks within a source are in ascending order")
                }
            },
        ])
    }
}
