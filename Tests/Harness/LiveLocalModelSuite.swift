import Foundation
import SourceDeskCore

/// Grounded answering with a **real** local model.
///
/// Everything else in the harness uses a stub provider, which verifies the pipeline
/// around the model but says nothing about whether a real model, given real retrieved
/// passages, actually answers from them and cites them. That is the app's central
/// promise, so pretending it is verified would be the worst kind of dishonesty in a test
/// suite.
///
/// These tests therefore run against whatever Ollama has installed, and **skip loudly**
/// when nothing is. A skip is reported in the summary as NOT VERIFIED rather than as a
/// pass.
enum LiveLocalModelSuite {

    /// A provider for a real local model, or nil when the machine has none.
    static func localProvider() async -> (provider: OllamaProvider, model: String)? {
        let provider = OllamaProvider(endpoint: URL(string: "http://127.0.0.1:11434")!, host: .local)
        guard case .ready = await provider.availability() else { return nil }
        guard let models = try? await provider.availableModels() else { return nil }
        // Prefer a small chat model: these tests run real inference.
        let chat = models.filter { !$0.supportsEmbeddings }
        guard !chat.isEmpty else { return nil }
        let preferred = chat.first { $0.name.contains("llama3.2") }
            ?? chat.first { $0.name.contains("llama3") || $0.name.contains("qwen") || $0.name.contains("gemma") }
            ?? chat[0]
        return (provider, preferred.name)
    }

    /// A notebook whose sources answer a question in a way the model cannot guess.
    ///
    /// The details are invented — a fictional agency, fictional figures — so an answer
    /// containing them can only have come from the retrieved passages, not from the
    /// model's training data. That is what makes this a test of grounding rather than of
    /// fluency.
    static func notebookWithDistinctiveSources(_ store: NotebookStore) throws -> Notebook {
        let notebook = try Fixtures.makeNotebook(store, title: "Live grounding")
        let documents: [(String, String)] = [
            ("Thornbury Inspectorate — 1987 annual report",
             """
             The Thornbury Inspectorate recorded a decline of 43.5 percent in inspection throughput \
             during the 1987 financial year. The report attributes most of this to the Marlowe \
             reorganisation, under which inspections were moved to a central scheduling desk in \
             March 1987. That change introduced an average coordination overhead of eleven days per \
             job. A secondary cause was the closure of two regional offices in Quillan and Hartsmere \
             under budget pressure, which concentrated the remaining work into four offices. \
             Permit processing averaged forty-one days against a baseline of twenty-two.
             """),
            ("Marlowe scheduling desk — internal note",
             """
             The Marlowe desk was staffed by nine schedulers on rotation. The note records that \
             the desk had no direct channel to regional inspectors for the first four months, so \
             scheduling conflicts were resolved by post. Independent analysts quoted alongside the \
             official account argue the decline began before March, when the reorganisation was \
             announced rather than implemented. The two accounts disagree on timing, not on cause.
             """)
        ]
        for (title, text) in documents {
            var source = Source(notebookID: notebook.id, kind: .website, title: title,
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
        }
        return notebook
    }

    static func engine(
        store: NotebookStore,
        provider: AIProvider,
        model: String
    ) -> AnswerEngine {
        AnswerEngine(
            store: store,
            providers: ProviderRegistry(providers: [provider]),
            embedder: BuiltInEmbedder(),
            search: WebSearchService(provider: nil),
            configuration: .init(providerID: provider.identifier, modelName: model, scope: .notebookSources),
            networkIsOnline: { false }
        )
    }

    static var suite: TestSuite {
        TestSuite("20 · Live local model (needs Ollama + a model)", cases: [

            test("a real model answers from the sources and cites them") { ctx in
                guard let (provider, model) = await localProvider() else {
                    try ctx.skip("no local Ollama model is installed (run `ollama pull llama3.2`), so grounded answering with a real model is unproven")
                }
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebookWithDistinctiveSources(store)
                let engine = engine(store: store, provider: provider, model: model)

                let outcome = try await engine.answerOnce(
                    question: "What caused the decline in inspection throughput?",
                    notebookID: notebook.id
                )

                // It answered at all.
                try ctx.check(!outcome.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              "the model produced an answer")
                // It used the source material: a figure it could only have read.
                let answer = outcome.answer
                try ctx.check(answer.contains("43.5") || answer.lowercased().contains("marlowe")
                              || answer.lowercased().contains("scheduling"),
                              "the answer draws on the retrieved passages, not general knowledge. Got: \(TextMath.preview(answer, limit: 300))")
                // And it cited.
                try ctx.check(!outcome.citations.isEmpty, "the answer carries citations")
                for citation in outcome.citations {
                    guard let sourceID = citation.sourceID else { continue }
                    let sourceIDs = try store.sources(notebookID: notebook.id).map(\.id)
                    try ctx.check(sourceIDs.contains(sourceID), "every citation resolves to a real source")
                }
            },

            test("a question the sources cannot answer is refused, not invented") { ctx in
                // The anti-hallucination guarantee, tested against a real model rather than
                // a stub. A model asked about something absent from the notebook must say
                // so; if it answers confidently, the grounding is not working.
                guard let (provider, model) = await localProvider() else {
                    try ctx.skip("no local Ollama model is installed, so refusal-on-absent-material is unproven")
                }
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebookWithDistinctiveSources(store)
                let engine = engine(store: store, provider: provider, model: model)

                let outcome = try await engine.answerOnce(
                    question: "What was the exact budget of the Thornbury Inspectorate in 1994, and who was its finance director?",
                    notebookID: notebook.id
                )
                let answer = outcome.answer.lowercased()
                // Either the pipeline refuses for lack of material, or the model states the
                // absence. What must not happen is a confident invented figure.
                let saysAbsent = answer.contains("not") || answer.contains("no information")
                    || answer.contains("doesn't") || answer.contains("does not")
                    || answer.contains("unable") || answer.contains("no mention")
                    || answer.contains("not provided") || answer.contains("not specified")
                try ctx.check(saysAbsent,
                              "the model declined to invent an answer. Got: \(TextMath.preview(outcome.answer, limit: 300))")
            },

            test("a study note is written from real sources by a real model") { ctx in
                guard let (provider, model) = await localProvider() else {
                    try ctx.skip("no local Ollama model is installed, so note generation with a real model is unproven")
                }
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebookWithDistinctiveSources(store)

                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [provider]),
                    embedder: BuiltInEmbedder(),
                    configuration: StudyToolsService.Configuration(
                        providerID: provider.identifier,
                        modelName: model
                    )
                )
                let outcome = try await service.generateOnce(
                    tool: .summary,
                    notebookID: notebook.id,
                    sourceIDs: nil,
                    focus: "what caused the decline in throughput"
                )

                try ctx.check(!outcome.note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              "the note has content")
                let body = outcome.note.body
                try ctx.check(body.lowercased().contains("marlowe")
                              || body.lowercased().contains("scheduling")
                              || body.contains("43.5")
                              || body.lowercased().contains("budget"),
                              "the note is grounded in the sources. Got: \(TextMath.preview(body, limit: 300))")

                // And it survived being saved.
                let saved = try store.notes(notebookID: notebook.id)
                try ctx.equal(saved.count, 1, "the note is stored")
                try ctx.check(!saved[0].body.isEmpty, "the stored note has its body")
            },

            test("answering offline with a local model needs no network") { ctx in
                // The offline promise, with a real model: the machine is treated as having
                // no internet, and local answering must still work end to end.
                guard let (provider, model) = await localProvider() else {
                    try ctx.skip("no local Ollama model is installed, so offline answering is unproven")
                }
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebookWithDistinctiveSources(store)
                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [provider]),
                    embedder: BuiltInEmbedder(),
                    search: WebSearchService(provider: DuckDuckGoSearchProvider()),
                    configuration: .init(providerID: provider.identifier, modelName: model,
                                         scope: .notebookAndWeb),
                    networkIsOnline: { false }
                )

                let outcome = try await engine.answerOnce(
                    question: "What caused the decline?", notebookID: notebook.id
                )
                try ctx.check(!outcome.answer.isEmpty, "answered without a network")
                try ctx.check(outcome.notices.contains { $0.lowercased().contains("offline") },
                              "the skipped web search is reported: \(outcome.notices)")
            },
        ])
    }
}
