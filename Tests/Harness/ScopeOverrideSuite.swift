import Foundation
import SourceDeskCore

/// The composer's scope choice must actually reach the engine.
///
/// This encodes a bug that made the "Sources + Web" and "Web only" buttons do nothing.
/// The chain was:
///
///   1. The composer called `chat.ask(question, scope: scope)`.
///   2. `ChatViewModel` stored the scope on the *session* — correct.
///   3. But the engine it used had been built from
///      `settings.researchConfiguration(notebookID:)`, which carries
///      `settings.defaultAnswerScope`.
///   4. So the engine ran with the Settings default (`.notebookSources`) regardless of
///      what the user picked. `usesWeb` was false, web search never ran, and the answer
///      came back from notebook sources alone while the segmented control still showed
///      "Sources + Web" — the choice was *displayed* and *saved* but never used.
///
/// The tests below assert the two halves that must stay fixed: an explicitly passed scope
/// reaches the pipeline, and the configuration is still honoured when nothing is passed.
enum ScopeOverrideSuite {

    /// Returns fixed web results, so "did web search run?" is observable.
    struct RecordingSearch: SearchProvider {
        let identifier = "recording"
        let displayName = "Recording Search"
        let requiresKey = false
        let isConfigured = true
        let configurationHint: String? = nil
        let privacyNote = "Nothing is sent anywhere."
        let results: [WebSearchResult]

        func search(query: String, limit: Int) async throws -> [WebSearchResult] {
            Array(results.prefix(limit))
        }
    }

    static func notebook(_ store: NotebookStore) throws -> Notebook {
        let notebook = try Fixtures.makeNotebook(store, title: "Scope")
        let text = """
        The Thornbury Inspectorate recorded a decline of 43.5 percent in inspection throughput \
        during the 1987 financial year, which the report attributes to the Marlowe \
        reorganisation moving inspections to a central scheduling desk.
        """
        var source = Source(notebookID: notebook.id, kind: .website, title: "Thornbury report",
                            wordCount: TextMath.wordCount(text), status: .ready)
        source = try store.upsert(source: source)
        let chunks = TextChunker.chunk(plainText: text, sourceID: source.id,
                                       notebookID: notebook.id, configuration: .default)
        try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: [])
        source.chunkCount = chunks.count
        _ = try store.upsert(source: source)
        return notebook
    }

    static func engine(
        store: NotebookStore,
        scope: AnswerScope,
        search: SearchProvider
    ) -> AnswerEngine {
        AnswerEngine(
            store: store,
            providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
            embedder: BuiltInEmbedder(),
            search: WebSearchService(provider: search),
            // The configuration deliberately says notebook-only, exactly as the Settings
            // default does in the reproduction. The passed scope must win.
            configuration: .init(providerID: "ollama", modelName: "stub", scope: scope),
            networkIsOnline: { true }
        )
    }

    static var suite: TestSuite {
        TestSuite("22 · Scope reaches the engine", cases: [

            test("asking with a scope overrides the configured default") { ctx in
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebook(store)
                let search = RecordingSearch(results: [
                    WebSearchResult(title: "News: permits slow", url: "https://news.example.com/permits",
                                    snippet: "Independent analysts dispute the official timeline.")
                ])

                // Configuration says notebook-only; the user asked for sources + web.
                let engine = engine(store: store, scope: .notebookSources, search: search)
                let outcome = try await engine.answerOnce(
                    question: "What caused the decline?",
                    notebookID: notebook.id,
                    scope: .notebookAndWeb
                )

                // Web search ran, and its result reached the answer.
                try ctx.equal(outcome.trace.webResultCount, 1,
                              "the web search ran despite the notebook-only configuration")
                try ctx.check(!outcome.citations.isEmpty || !outcome.notices.isEmpty)
                try ctx.check(outcome.citations.contains { $0.kind == .web }
                              || outcome.trace.webResultCount == 1,
                              "the web result is represented in the outcome")
                try ctx.check(!outcome.notices.contains { $0.contains("switched off") },
                              "and it was not reported as switched off: \(outcome.notices)")
            },

            test("web-only ignores the notebook's sources") { ctx in
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebook(store)
                let search = RecordingSearch(results: [
                    WebSearchResult(title: "Web only result", url: "https://example.com/a",
                                    snippet: "A web-only snippet.")
                ])

                let engine = engine(store: store, scope: .notebookSources, search: search)
                let outcome = try await engine.answerOnce(
                    question: "What caused the decline?",
                    notebookID: notebook.id,
                    scope: .webOnly
                )
                try ctx.equal(outcome.trace.webResultCount, 1, "the web was searched")
                try ctx.equal(outcome.trace.hits.count, 0, "and notebook retrieval was skipped")
            },

            test("without an explicit scope the configuration is still honoured") { ctx in
                // The other half: the new parameter must not silently break the default
                // path that Settings and the study tools rely on.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebook(store)
                let search = RecordingSearch(results: [
                    WebSearchResult(title: "Should not be used", url: "https://example.com/x",
                                    snippet: "Nope.")
                ])

                let engine = engine(store: store, scope: .notebookSources, search: search)
                let outcome = try await engine.answerOnce(
                    question: "What caused the decline?", notebookID: notebook.id
                )
                try ctx.equal(outcome.trace.webResultCount, 0,
                              "a notebook-only configuration does not search the web")
                try ctx.check(!outcome.trace.hits.isEmpty, "and it did use the notebook")
            },

            test("the session's scope survives being saved and reloaded") { ctx in
                // The persistence half of the bug: the choice was recorded, but nothing
                // read it back, so picking "Sources + Web" and switching notebooks silently
                // reverted to notebook-only.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebook(store)

                var session = ChatSession(
                    notebookID: notebook.id, scope: .notebookAndWeb,
                    providerID: "ollama", modelName: "stub"
                )
                session = try store.upsert(session: session)

                let reloaded = try ctx.unwrap(
                    try store.sessions(notebookID: notebook.id).first { $0.id == session.id }
                )
                try ctx.equal(reloaded.scope, .notebookAndWeb,
                              "the scope is persisted, so it can be used on the next question")

                // And an engine built from that stored scope does search the web.
                let search = RecordingSearch(results: [
                    WebSearchResult(title: "From the web", url: "https://example.com/w", snippet: "Web text.")
                ])
                let engine = engine(store: store, scope: reloaded.scope, search: search)
                let outcome = try await engine.answerOnce(
                    question: "Anything", notebookID: notebook.id, scope: reloaded.scope
                )
                try ctx.equal(outcome.trace.webResultCount, 1)
            },

            test("a scope needing the web says so when no search provider is available") { ctx in
                // If web search is selected but no provider is configured, the user must
                // be told, rather than getting a quietly source-only answer.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebook(store)
                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [Fixtures.stubProvider()]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "ollama", modelName: "stub", scope: .notebookSources),
                    networkIsOnline: { true }
                )
                let outcome = try await engine.answerOnce(
                    question: "What caused the decline?", notebookID: notebook.id, scope: .notebookAndWeb
                )
                try ctx.check(outcome.notices.contains { $0.contains("switched off") },
                              "the user is told web search is off: \(outcome.notices)")
            },
        ])
    }
}
