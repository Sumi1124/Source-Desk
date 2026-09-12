import Foundation
import SourceDeskCore

enum StudyToolsSuite {

    static var suite: TestSuite {
        TestSuite("9 · Study tools", cases: [

            test("flashcards are parsed from the Q:/A: contract") { ctx in
                let output = """
                Q: When did phase two begin?
                A: After the review board published its findings in March. [Source 1]

                Q: **What caused the decline?**
                A: Budget pressure and a shortage of qualified inspectors. [Source 2][Source 3]

                - Q: How long did permits take?
                - A: An average of forty one days.
                """
                let cards = StudyToolsService.parseFlashcards(output)
                try ctx.equal(cards.count, 3, "got \(cards.count) cards")
                try ctx.equal(cards[0].front, "When did phase two begin?")
                try ctx.contains(cards[0].back, "review board")
                try ctx.equal(cards[0].sourceMarker, "[Source 1]")
                try ctx.equal(cards[1].front, "What caused the decline?", "bold markers stripped")
                try ctx.equal(cards[1].sourceMarker, "[Source 2]")
                try ctx.equal(cards[2].front, "How long did permits take?", "leading dashes stripped")
                try ctx.equal(cards[2].sourceMarker, nil, "no marker when none was given")
            },

            test("malformed flashcard output yields no cards instead of junk") { ctx in
                try ctx.equal(StudyToolsService.parseFlashcards("").count, 0)
                try ctx.equal(StudyToolsService.parseFlashcards("Just a paragraph with no cards at all.").count, 0)
                // A question with no answer is not a card.
                try ctx.equal(StudyToolsService.parseFlashcards("Q: Orphan question?").count, 0)
                try ctx.equal(StudyToolsService.parseFlashcards("A: Orphan answer.").count, 0)
            },

            test("quiz questions are parsed with choices, answer and explanation") { ctx in
                let output = """
                1. What caused the decline in inspection throughput?
                A. Budget pressure and staffing shortages
                B. A change in the weather
                C. A new museum exhibition
                D. An increase in funding
                Answer: A
                Why: The report cites budget pressure and a shortage of qualified inspectors. [Source 1]

                2) How long did permit applications take?
                A) Twenty days
                B) Forty one days
                C) Ninety days
                D) Six weeks
                Answer: B
                """
                let items = StudyToolsService.parseQuiz(output)
                try ctx.equal(items.count, 2, "got \(items.count) items")
                try ctx.equal(items[0].question, "What caused the decline in inspection throughput?")
                try ctx.equal(items[0].choices.count, 4)
                try ctx.equal(items[0].answer, "Budget pressure and staffing shortages")
                try ctx.equal(items[0].answerIndex, 0)
                try ctx.contains(items[0].explanation, "budget pressure")
                try ctx.equal(items[0].sourceMarker, "[Source 1]")
                try ctx.equal(items[1].answer, "Forty one days", "parenthesised choice markers work")
                try ctx.equal(items[1].answerIndex, 1)
            },

            test("a numeric answer key is accepted 1-based") { ctx in
                let output = """
                1. Which region fell most?
                A. North
                B. South
                C. East
                D. West
                Answer: 2
                """
                let items = StudyToolsService.parseQuiz(output)
                try ctx.equal(items.count, 1)
                try ctx.equal(items[0].answer, "South", "answer 2 means the second choice")
            },

            test("an unusable answer key means no quiz item, not a wrong one") { ctx in
                let output = """
                1. Which region fell most?
                A. North
                B. South
                Answer: Z
                """
                try ctx.equal(StudyToolsService.parseQuiz(output).count, 0)
            },

            test("every study tool has a display name, symbol and output contract") { ctx in
                for tool in StudyToolsService.availableTools {
                    try ctx.check(!tool.displayName.isEmpty, "\(tool.rawValue) has a name")
                    try ctx.check(!tool.symbolName.isEmpty, "\(tool.rawValue) has a symbol")
                    let contract = PromptBuilder.outputContract(for: tool)
                    try ctx.check(contract.count > 40, "\(tool.rawValue) contract is specific (\(contract.count) chars)")
                    let system = PromptBuilder.studyToolSystemPrompt(tool: tool, grounding: PromptBuilder.Grounding(
                        notebookAvailable: true, webAvailable: false, sourceCount: 3, scope: .notebookSources, cloudProviderName: nil))
                    try ctx.contains(system, "Use only the supplied material")
                    try ctx.contains(system, "Never invent a marker")
                }
                try ctx.equal(StudyToolsService.availableTools.count, 11, "eleven tools are offered")
            },

            test("quiz and flashcard prompts demand the exact parseable format") { ctx in
                let quiz = PromptBuilder.outputContract(for: .quiz)
                try ctx.contains(quiz, "Answer: B")
                try ctx.contains(quiz, "Why:")
                let cards = PromptBuilder.outputContract(for: .flashcards)
                try ctx.contains(cards, "Q:")
                try ctx.contains(cards, "A:")
                let quotes = PromptBuilder.outputContract(for: .quotations)
                try ctx.contains(quotes, "quoted verbatim")
                try ctx.contains(quotes, "never invent a quote")
            },

            test("each tool retrieves material suited to it") { ctx in
                let timeline = StudyToolsService.retrievalQuery(for: .timeline, sourceTitles: ["Report"])
                try ctx.contains(timeline, "date")
                try ctx.contains(timeline, "chronology")
                let comparison = StudyToolsService.retrievalQuery(for: .comparison, sourceTitles: ["Report A", "Report B"])
                try ctx.contains(comparison, "Report A")
                for tool in StudyToolsService.availableTools {
                    let query = StudyToolsService.retrievalQuery(for: tool, sourceTitles: ["A", "B"])
                    try ctx.check(!query.isEmpty, "\(tool.rawValue) produces a retrieval query")
                }
            },

            test("default note titles describe the tool and its scope") { ctx in
                let single = Source(notebookID: "n", kind: .pdf, title: "Inspectorate Report")
                try ctx.contains(StudyToolsService.defaultTitle(for: .summary, sources: [single]), "Inspectorate Report")
                try ctx.contains(StudyToolsService.defaultTitle(for: .summary, sources: [single]), "Summary")
                let two = [single, Source(notebookID: "n", kind: .website, title: "News article")]
                let comparison = StudyToolsService.defaultTitle(for: .comparison, sources: two)
                try ctx.contains(comparison, "vs")
                try ctx.contains(comparison, "News article")
                let many = (0..<7).map { Source(notebookID: "n", kind: .pdf, title: "S\($0)") }
                try ctx.contains(StudyToolsService.defaultTitle(for: .quiz, sources: many), "7 sources")
            },

            test("study generation fails with an actionable error when sources are missing") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [StubProvider(identifier: "ollama", displayName: "Ollama")]),
                    embedder: BuiltInEmbedder(),
                    configuration: .init(providerID: "ollama", modelName: "llama3.2")
                )
                let error = try await ctx.expectError("no sources") {
                    try await service.generateOnce(tool: .summary, notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "no sources")
            },

            test("comparison requires at least two sources") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .pdf, title: "Only one", status: .ready))
                let chunk = SourceChunk(sourceID: source.id, notebookID: notebook.id, ordinal: 0,
                                        text: "The review board examined inspection throughput across all regions.")
                try store.replaceChunks(sourceID: source.id, notebookID: notebook.id, chunks: [chunk],
                                        embeddings: [ChunkEmbedding(chunkID: chunk.id, sourceID: source.id, notebookID: notebook.id,
                                                                   model: "builtin-hash-384", vector: BuiltInEmbedder().embedOne(chunk.text))])
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [StubProvider(identifier: "ollama", displayName: "Ollama")]),
                    embedder: BuiltInEmbedder(),
                    configuration: .init(providerID: "ollama", modelName: "llama3.2")
                )
                let error = try await ctx.expectError("one source") {
                    try await service.generateOnce(tool: .comparison, notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "at least two")
            },

            test("local-only mode blocks a cloud study tool before any request") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let keychain = InMemoryKeychain()
                keychain.values["anthropic.api-key"] = "sk-ant-x"
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [AnthropicProvider(keychain: keychain)]),
                    embedder: nil,
                    configuration: .init(providerID: "anthropic", modelName: "claude-sonnet-4-5", localOnlyMode: true)
                )
                let error = try await ctx.expectError("local-only") {
                    try await service.generateOnce(tool: .summary, notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "Local-Only Mode")
            },

            test("cloud tools without consent explain how to grant it") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let keychain = InMemoryKeychain()
                keychain.values["anthropic.api-key"] = "sk-ant-x"
                let service = StudyToolsService(
                    store: store,
                    providers: ProviderRegistry(providers: [AnthropicProvider(keychain: keychain)]),
                    embedder: nil,
                    configuration: .init(providerID: "anthropic", modelName: "claude-sonnet-4-5", cloudConsentGranted: false)
                )
                let error = try await ctx.expectError("no consent") {
                    try await service.generateOnce(tool: .summary, notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "Anthropic Claude")
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "banner above the composer")
            },

            test("notes are saved and can be re-read with their payload") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let note = NotebookNote(
                    notebookID: notebook.id, title: "Quiz · 2 sources",
                    body: "1. What caused the decline?", kind: .quiz, payload: NotePayload(quizItems: [
                        QuizItem(question: "What caused the decline?", choices: ["Budget pressure", "Weather"], answerIndex: 0)
                    ])
                )
                try store.upsert(note: note)
                let loaded = try ctx.unwrap(try store.notes(notebookID: notebook.id).first)
                try ctx.equal(loaded.payload?.quizItems.first?.answer, "Budget pressure")
                try ctx.equal(loaded.kind, .quiz)
            }
        ])
    }
}
