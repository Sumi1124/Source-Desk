import Foundation
import SourceDeskCore

/// Persistence is the foundation everything else rests on: if notebooks, chunks,
/// vectors, chat and notes do not survive a restart, nothing else matters.
enum StoreSuite {

    static var suite: TestSuite {
        TestSuite("1 · Persistence (SQLite store)", cases: [
            test("notebooks round-trip, update and delete") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }

                var notebook = try Fixtures.makeNotebook(store, title: "Industrial Decline")
                try ctx.check(notebook.id.isEmpty == false, "notebook got an id")

                var loaded = try ctx.unwrap(try store.notebook(id: notebook.id), "notebook is readable")
                try ctx.equal(loaded.title, "Industrial Decline")
                try ctx.equal(loaded.isFavorite, false, "defaults to not favourited")

                notebook.isFavorite = true
                notebook.title = "Industrial Decline (revised)"
                try store.upsert(notebook: notebook)

                loaded = try ctx.unwrap(try store.notebook(id: notebook.id))
                try ctx.equal(loaded.title, "Industrial Decline (revised)")
                try ctx.equal(loaded.isFavorite, true, "favourite flag persisted")

                try ctx.equal(try store.notebooks().count, 1, "one notebook listed")
                try store.deleteNotebook(id: notebook.id)
                try ctx.equal(try store.notebooks().count, 0, "notebook removed")
                try ctx.isNil(try store.notebook(id: notebook.id), "deleted notebook is gone")
            },

            test("source, chunk, embedding and FTS rows are written together") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)

                let source = try store.upsert(source: Source(
                    notebookID: notebook.id, kind: .website, title: "Review Board Findings",
                    url: "https://example.com/findings", wordCount: 900, status: .ready
                ))

                let chunks = (0..<5).map { index in
                    SourceChunk(
                        sourceID: source.id, notebookID: notebook.id, ordinal: index,
                        text: "Chunk \(index): the decline accelerated after the reorganisation of the inspection schedule.",
                        headingPath: "Findings", pageNumber: index + 1
                    )
                }
                let embeddings = chunks.map { chunk in
                    ChunkEmbedding(chunkID: chunk.id, sourceID: source.id, notebookID: notebook.id,
                                   model: "builtin-hash-384", vector: [Float](repeating: 0.1, count: 384))
                }
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id,
                                        chunks: chunks, embeddings: embeddings)

                try ctx.equal(try store.chunks(sourceID: source.id).count, 5, "chunks stored")
                try ctx.equal(try store.embeddingCount(notebookID: notebook.id), 5, "vectors stored")
                try ctx.equal(try store.chunkCount(notebookID: notebook.id), 5, "chunk count indexed")

                let reloaded = try ctx.unwrap(try store.source(id: source.id))
                try ctx.equal(reloaded.chunkCount, 5, "source knows its chunk count")
                try ctx.equal(reloaded.url, "https://example.com/findings", "url preserved")
                try ctx.equal(reloaded.pageCount, nil, "no page count for a website")

                // The vector must come back bit-identical.
                let vectors = try store.embeddings(sourceID: source.id)
                try ctx.equal(vectors.first?.vector.count, 384, "dimensions preserved")
                try ctx.close(Double(vectors.first?.vector.first ?? 0), 0.1, tolerance: 1e-5, "values preserved")

                let hits = try store.keywordSearch(query: "reorganisation inspection schedule", notebookID: notebook.id)
                try ctx.check(hits.count >= 1, "FTS5 finds the chunks")
            },

            test("re-indexing a source replaces chunks instead of duplicating them") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .pdf, title: "Report"))

                let first = (0..<4).map { SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: $0, text: "original chunk \($0)") }
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: first, embeddings: [])

                let second = (0..<2).map { SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: $0, text: "replacement chunk \($0)") }
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: second, embeddings: [])

                let stored = try store.chunks(sourceID: source.id)
                try ctx.equal(stored.count, 2, "old chunks are gone")
                try ctx.contains(stored[0].text, "replacement")

                // And the stale FTS rows must be gone too, not just the chunk rows.
                let stale = try store.keywordSearch(query: "original", notebookID: notebook.id)
                try ctx.equal(stale.count, 0, "stale keyword index entries removed")
            },

            test("deleting a source removes its chunks, vectors and content folder") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .pdf, title: "Disposable"))

                let chunks = [SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: 0, text: "temporary content")]
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: [
                    ChunkEmbedding(chunkID: chunks[0].id, sourceID: source.id, notebookID: notebook.id, model: "m", vector: [1, 0, 0])
                ])
                try FileStore.write("some extracted text", to: paths.extractedTextURL(for: source.id))
                try ctx.check(FileStore.exists(paths.extractedTextURL(for: source.id)), "extracted text on disk before delete")

                try store.deleteSource(id: source.id)

                try ctx.equal(try store.chunks(sourceID: source.id).count, 0, "chunks removed")
                try ctx.equal(try store.embeddingCount(notebookID: notebook.id), 0, "vectors removed")
                try ctx.isNil(try store.source(id: source.id), "source row removed")
                try ctx.check(!FileStore.exists(paths.contentDirectory(for: source.id)), "content folder removed")
            },

            test("deleting a notebook cascades to everything it owns") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .plainText, title: "Notes"))
                let chunks = [SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: 0, text: "some body text")]
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: [])

                let session = try store.upsert(session: ChatSession(notebookID: notebook.id, title: "Session"))
                try store.upsert(message: ChatMessage(sessionID: session.id, notebookID: notebook.id, role: .user, content: "hello"))
                try store.upsert(note: NotebookNote(notebookID: notebook.id, title: "Note"))

                try store.deleteNotebook(id: notebook.id)

                try ctx.equal(try store.sourceCount(notebookID: notebook.id), 0, "sources gone")
                try ctx.equal(try store.messages(sessionID: session.id).count, 0, "messages gone")
                try ctx.equal(try store.notes(notebookID: notebook.id).count, 0, "notes gone")
                try ctx.equal(try store.keywordSearch(query: "body", notebookID: notebook.id).count, 0, "keyword index cleaned")
            },

            test("chat messages keep citations and the retrieval trace") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let session = try store.upsert(session: ChatSession(notebookID: notebook.id))

                let citation = Citation(
                    kind: .notebook, marker: "[Source 1]", sourceID: "src-1", chunkID: "chunk-1",
                    title: "Review Board Findings", url: "https://example.com/findings",
                    pageNumber: 4, headingPath: "Findings › Causes", excerpt: "Budget pressure and staffing shortages.", score: 0.82
                )
                let trace = RetrievalTrace(
                    query: "what caused the decline", candidateCount: 120,
                    hits: [RetrievalTrace.Hit(
                        chunkID: "chunk-1", sourceID: "src-1", sourceTitle: "Review Board Findings",
                        semanticScore: 0.71, keywordScore: 4.2, fusedScore: 0.9, rerankScore: 0.88,
                        pageNumber: 4, headingPath: "Findings › Causes", preview: "Budget pressure…",
                        embeddingModel: "builtin-hash-384", usedInContext: true
                    )],
                    usedTokens: 1450, contextBudget: 4000, semanticEnabled: true, keywordEnabled: true,
                    rerankEnabled: true, notes: ["hybrid retrieval"], durationMilliseconds: 37
                )

                let message = ChatMessage(
                    sessionID: session.id, notebookID: notebook.id, role: .assistant,
                    content: "The decline had two causes. [Source 1]",
                    citations: [citation], retrieval: trace, providerID: "ollama", modelName: "llama3.2",
                    latencyMilliseconds: 812, promptTokens: 1500, completionTokens: 96
                )
                try store.upsert(message: message)

                let loaded = try ctx.unwrap(try store.messages(sessionID: session.id).first)
                try ctx.equal(loaded.citations.count, 1, "citation survived")
                try ctx.equal(loaded.citations[0].marker, "[Source 1]")
                try ctx.equal(loaded.citations[0].pageNumber, 4, "page number survived")
                try ctx.equal(loaded.retrieval?.hits.count, 1, "retrieval trace survived")
                try ctx.close(loaded.retrieval?.hits.first?.rerankScore ?? 0, 0.88, tolerance: 1e-9, "trace detail survived")
                try ctx.equal(loaded.latencyMilliseconds, 812, "timings survived")
                try ctx.equal(loaded.citations[0].provenance, "page 4 · Findings › Causes")
            },

            test("error messages round-trip as user-facing text") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let session = try store.upsert(session: ChatSession(notebookID: notebook.id))

                try store.upsert(message: ChatMessage(
                    sessionID: session.id, notebookID: notebook.id, role: .assistant, content: "",
                    isError: true,
                    errorMessage: SourceDeskError.missingAPIKey(provider: "Anthropic Claude").errorDescription,
                    errorRecovery: SourceDeskError.missingAPIKey(provider: "Anthropic Claude").recoverySuggestion
                ))

                let loaded = try ctx.unwrap(try store.messages(sessionID: session.id).first)
                try ctx.equal(loaded.isError, true)
                try ctx.equal(loaded.errorMessage, "Anthropic Claude is selected but no API key is stored.")
                try ctx.contains(loaded.errorRecovery ?? "", "Keychain")
            },

            test("notes store structured payloads for flashcards and quizzes") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)

                let payload = NotePayload(
                    flashcards: [Flashcard(front: "When did phase 2 begin?", back: "After the review board published its findings.", sourceMarker: "[Source 1]")],
                    quizItems: [QuizItem(question: "What caused the decline?", choices: ["Budget pressure", "Weather", "Tourism", "None"], answerIndex: 0, explanation: "The report cites budget pressure.", sourceMarker: "[Source 1]")]
                )
                let note = NotebookNote(
                    notebookID: notebook.id, title: "Study set", body: "Generated from 2 sources.",
                    kind: .flashcards, sourceIDs: ["src-1", "src-2"], payload: payload
                )
                try store.upsert(note: note)

                let loaded = try ctx.unwrap(try store.notes(notebookID: notebook.id).first)
                try ctx.equal(loaded.kind, .flashcards)
                try ctx.equal(loaded.payload?.flashcards.count, 1)
                try ctx.equal(loaded.payload?.quizItems.first?.answer, "Budget pressure")
                try ctx.equal(loaded.sourceIDs, ["src-1", "src-2"])
            },

            test("settings persist, and unknown keys read back as nil") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }

                try ctx.isNil(try store.settingValue("retrieval.count"), "unset key is nil")
                try store.setSettingValue("retrieval.count", "8")
                try store.setSettingValue("retrieval.count", "12")
                try ctx.equal(try store.settingValue("retrieval.count"), "12", "value updated in place")
                try ctx.equal(try store.allSettings().count, 1, "one key stored")
            },

            test("the library survives closing and reopening (restart simulation)") { ctx in
                var paths: AppPaths?
                var notebookID = ""
                var sourceID = ""
                do {
                    let (store, p) = try Fixtures.temporaryStore()
                    paths = p
                    let notebook = try Fixtures.makeNotebook(store, title: "Survives restart")
                    notebookID = notebook.id
                    let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .website, title: "Kept", url: "https://example.com/kept"))
                    sourceID = source.id
                    let chunks = [SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: 0, text: "content that must persist across launches")]
                    try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: [
                        ChunkEmbedding(chunkID: chunks[0].id, sourceID: source.id, notebookID: notebook.id, model: "m", vector: [0.5, 0.5])
                    ])
                    try store.setSettingValue("appearance", "dark")
                }
                defer { if let paths { Fixtures.cleanup(paths) } }

                // Fresh store object against the same files — the same thing that
                // happens when the app is quit and launched again.
                let reopened = try NotebookStore(paths: try ctx.unwrap(paths))
                let notebook = try ctx.unwrap(try reopened.notebook(id: notebookID), "notebook reloaded")
                try ctx.equal(notebook.title, "Survives restart")
                try ctx.equal(try reopened.sources(notebookID: notebookID).count, 1, "source reloaded")
                try ctx.equal(try reopened.chunks(sourceID: sourceID).count, 1, "chunks reloaded")
                try ctx.equal(try reopened.embeddingCount(notebookID: notebookID), 1, "vectors reloaded")
                try ctx.equal(try reopened.keywordSearch(query: "persist launches", notebookID: notebookID).count, 1, "keyword index reloaded")
                try ctx.equal(try reopened.settingValue("appearance"), "dark", "settings reloaded")
            },

            test("a newer on-disk schema is refused with an actionable message") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                store.db.userVersion = 99

                let error = try await ctx.expectError("refuses future schema") {
                    try NotebookStore(paths: paths)
                }
                let message = (error as? SourceDeskError)?.errorDescription ?? "\(error)"
                try ctx.contains(message, "newer version of SourceDesk")
                try ctx.contains(message, "Update the app")
            },

            test("store statistics describe what is on disk") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .pdf, title: "Stats"))
                let chunks = [SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: 0, text: "counted")]
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: [
                    ChunkEmbedding(chunkID: chunks[0].id, sourceID: source.id, notebookID: notebook.id, model: "builtin-hash-384", vector: [1, 2, 3])
                ])
                try FileStore.write(String(repeating: "x", count: 1024), to: paths.extractedTextURL(for: source.id))

                let stats = try store.stats()
                try ctx.equal(stats.notebookCount, 1)
                try ctx.equal(stats.sourceCount, 1)
                try ctx.equal(stats.chunkCount, 1)
                try ctx.equal(stats.embeddingCount, 1)
                try ctx.equal(stats.embeddingModels, ["builtin-hash-384"])
                try ctx.check(stats.contentBytes >= 1024, "content size measured, got \(stats.contentBytes)")
                try ctx.check(stats.databaseBytes > 0, "database size measured")
                try ctx.equal(try store.db.integrityCheck(), "ok")
            },

            test("large batch inserts are atomic and fast") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .pdf, title: "Big document"))

                // 4,000 chunks with 384-dimension vectors: roughly a 600-page book.
                let chunks = (0..<4_000).map { index in
                    SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: index,
                                text: "Section \(index) discusses inspection throughput, permit backlogs and staffing levels in region \(index % 24).")
                }
                let embeddings = chunks.map { chunk in
                    ChunkEmbedding(chunkID: chunk.id, sourceID: source.id, notebookID: notebook.id,
                                   model: "builtin-hash-384", vector: (0..<384).map { Float(($0 % 7) + 1) })
                }
                let start = Date()
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: embeddings)
                let elapsed = Date().timeIntervalSince(start)

                try ctx.equal(try store.chunks(sourceID: source.id).count, 4_000)
                try ctx.equal(try store.embeddingCount(notebookID: notebook.id), 4_000)
                try ctx.check(elapsed < 120, "4,000 chunks + vectors written in \(String(format: "%.2f", elapsed))s")
                ctx.note("4000 chunks + 1.5M float values in \(String(format: "%.2f", elapsed))s")
            },

            test("an interrupted write leaves no orphaned chunks") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .pdf, title: "Partial"))

                // Pre-existing good chunks.
                let good = [SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: 0, text: "good chunk")]
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: good, embeddings: [])

                // A replacement whose payload cannot be written (invalid SQL via an
                // absurdly long id is not possible, so we force a constraint failure:
                // a chunk id that already exists inside the same transaction).
                let duplicate = [
                    SourceChunk(id: "dup", sourceID: source.id, notebookID: notebook.id, ordinal: 0, text: "first"),
                    SourceChunk(id: "dup", sourceID: source.id, notebookID: notebook.id, ordinal: 1, text: "second"),
                ]
                do {
                    try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: duplicate, embeddings: [])
                    throw TestFailure(description: "expected the duplicate-id write to fail")
                } catch is TestFailure {
                    throw TestFailure(description: "expected the duplicate-id write to fail")
                } catch {
                    // expected
                }

                let remaining = try store.chunks(sourceID: source.id)
                try ctx.equal(remaining.count, 1, "rollback restored the previous chunk set")
                try ctx.equal(remaining[0].text, "good chunk", "and it is the original content")
            }
        ])
    }
}
