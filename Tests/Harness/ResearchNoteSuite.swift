import Foundation
import SourceDeskCore

/// Research → note, end to end.
///
/// The pipeline that adds sources is covered by suite 16. What this covers is the second
/// half: after the sources exist, writing a note from them must actually work — and when
/// the model is unavailable, the sources must survive and the failure must be reported
/// rather than losing the research.
enum ResearchNoteSuite {

    /// A provider that returns a fixed answer, so the note path runs without a network.
    struct FixedProvider: AIProvider {
        var identifier: String { "fixed" }
        var displayName: String { "Fixed Model" }
        var isLocal: Bool { true }
        var isConfigured: Bool { true }
        var configurationHint: String? { nil }
        var reply: String
        var failure: SourceDeskError?

        func availability() async -> ProviderAvailability { .ready }

        func availableModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(providerID: identifier, name: "fixed-1", contextLength: 32_768, isLocal: true)]
        }

        func generate(_ request: AIRequest) async throws -> AIResponse {
            if let failure { throw failure }
            return AIResponse(
                text: reply,
                model: request.model,
                usage: ChatUsage(promptTokens: 100, completionTokens: 50),
                latencyMilliseconds: 100,
                finishReason: "stop"
            )
        }

        func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                if let failure {
                    continuation.yield(.failed(failure))
                    continuation.finish()
                    return
                }
                continuation.yield(.delta(reply))
                continuation.yield(.finished(AIResponse(
                    text: reply,
                    model: request.model,
                    usage: ChatUsage(promptTokens: 100, completionTokens: 50),
                    latencyMilliseconds: 100,
                    finishReason: "stop"
                )))
                continuation.finish()
            }
        }
    }

    /// A notebook with real indexed sources, so a note has something to be grounded in.
    static func notebookWithSources(_ store: NotebookStore) throws -> Notebook {
        let notebook = try Fixtures.makeNotebook(store, title: "RISC-V Research")
        let documents: [(String, String)] = [
            ("RISC-V History — RISC-V International",
             "RISC-V was developed in 2010 at the University of California, Berkeley. The project began as part of a research programme into parallel computing, and the fifth generation of the design gave the architecture its name. The specification was published openly so that any company could implement it without paying licensing fees, which is the property that distinguishes RISC-V from proprietary instruction set architectures."),
            ("IBM — RISC architecture",
             "Reduced instruction set computing emerged in the 1970s as a reaction to increasingly complex instruction sets. The insight was that a small, simple instruction set could execute faster and be implemented in less silicon than a large one, because complex operations could be composed from simple ones by the compiler instead of being encoded in hardware.")
        ]
        for (title, text) in documents {
            // The source row must exist before its chunks: `chunks.source_id` is a
            // foreign key, exactly as it is in the app.
            var source = Source(
                notebookID: notebook.id, kind: .website, title: title,
                wordCount: TextMath.wordCount(text), status: .ready
            )
            source = try store.upsert(source: source)
            let chunks = TextChunker.chunk(
                plainText: text, sourceID: source.id, notebookID: notebook.id, configuration: .default
            )
            // Indexed with embeddings, as the app does. A study tool retrieves
            // semantically, so a keyword-only fixture would not represent it.
            let embedder = BuiltInEmbedder()
            let embeddings = chunks.map { chunk in
                ChunkEmbedding(chunkID: chunk.id, sourceID: source.id, notebookID: notebook.id,
                               model: embedder.identifier, vector: embedder.embedOne(chunk.text))
            }
            try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: chunks, embeddings: embeddings)
            source.chunkCount = chunks.count
            _ = try store.upsert(source: source)
        }
        return notebook
    }

    static var suite: TestSuite {
        TestSuite("18 · Research notes", cases: [

            test("a note is written from the sources and saved to the notebook") { ctx in
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebookWithSources(store)

                let provider = FixedProvider(reply: """
                RISC-V began in 2010 at UC Berkeley and was published as an open standard. \
                The defining property is that anyone may implement it without licensing fees. \
                [Source 1]
                """)
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [provider]),
                    embedder: BuiltInEmbedder(),
                    configuration: StudyToolsService.Configuration(
                        providerID: provider.identifier,
                        modelName: "fixed-1"
                    )
                )

                let outcome = try await service.generateOnce(
                    tool: .summary,
                    notebookID: notebook.id,
                    sourceIDs: nil,
                    focus: "origins of RISC-V",
                    title: "Research: RISC-V origins"
                )

                // The note is persisted and readable, not just returned.
                try ctx.equal(outcome.note.title, "Research: RISC-V origins")
                try ctx.equal(outcome.note.kind, .summary)
                try ctx.contains(outcome.note.body, "UC Berkeley")

                let saved = try store.notes(notebookID: notebook.id)
                try ctx.equal(saved.count, 1, "the note is stored in the notebook")
                try ctx.contains(saved[0].body, "UC Berkeley")
                try ctx.equal(saved[0].notebookID, notebook.id)
            },

            test("a note records which sources it was grounded in") { ctx in
                // Citations are the point of a grounded note; a note that cannot say
                // where it came from is not much use.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebookWithSources(store)
                let provider = FixedProvider(reply: "RISC-V is an open instruction set. [Source 1]")
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [provider]),
                    embedder: BuiltInEmbedder(),
                    configuration: StudyToolsService.Configuration(
                        providerID: provider.identifier,
                        modelName: "fixed-1"
                    )
                )

                let outcome = try await service.generateOnce(tool: .keyPoints, notebookID: notebook.id)
                let sourceIDs = try store.sources(notebookID: notebook.id).map(\.id)
                try ctx.check(!outcome.citations.isEmpty, "the note cites at least one source")
                for citation in outcome.citations {
                    guard let cited = citation.sourceID else { continue }
                    try ctx.check(sourceIDs.contains(cited),
                                  "every cited source belongs to this notebook")
                }
            },

            test("a model failure leaves the sources intact and reports the reason") { ctx in
                // The failure that matters most: research added sources, then the note
                // failed. Losing the sources would be the worst outcome, and reporting
                // a vague error would hide why.
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try notebookWithSources(store)
                let provider = FixedProvider(reply: "", failure: .missingAPIKey(provider: "Fixed Model"))
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [provider]),
                    embedder: BuiltInEmbedder(),
                    configuration: StudyToolsService.Configuration(
                        providerID: provider.identifier,
                        modelName: "fixed-1"
                    )
                )

                var caught: SourceDeskError?
                do {
                    _ = try await service.generateOnce(tool: .summary, notebookID: notebook.id)
                } catch let error as SourceDeskError {
                    caught = error
                }

                let error = try ctx.unwrap(caught, "the failure is surfaced to the caller")
                try ctx.contains(error.errorDescription ?? "", "Fixed Model", "the error names the provider")
                try ctx.notNil(error.recoverySuggestion, "and says what to do about it")

                // The research is untouched.
                let sources = try store.sources(notebookID: notebook.id)
                try ctx.equal(sources.count, 2, "both sources survive a failed note")
                let notes = try store.notes(notebookID: notebook.id)
                try ctx.equal(notes.count, 0, "no half-written note is left behind")
            },

            test("a note over a notebook with no sources reports that plainly") { ctx in
                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try Fixtures.makeNotebook(store, title: "Empty")
                let provider = FixedProvider(reply: "anything")
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [provider]),
                    embedder: nil,
                    configuration: StudyToolsService.Configuration(
                        providerID: provider.identifier,
                        modelName: "fixed-1"
                    )
                )
                var caught: SourceDeskError?
                do {
                    _ = try await service.generateOnce(tool: .summary, notebookID: notebook.id)
                } catch let error as SourceDeskError {
                    caught = error
                }
                let error = try ctx.unwrap(caught)
                try ctx.contains(error.errorDescription ?? "", "no sources")
            },
        ])
    }
}
