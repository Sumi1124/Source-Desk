import Foundation
import SourceDeskCore

/// Development utility: fills a library with realistic content so the application
/// can be exercised by hand and screenshotted.
///
///   SOURCEDESK_SEED_ROOT=/tmp/sd-demo swift run SourceDeskHarness --seed-demo
public enum DemoSeed {

    /// The fixed instant every demo date is computed from, so screenshots show the same
    /// relative ages on every run. The renderer pins `Format.referenceNow` to this value.
    public static let demoNow = Date(timeIntervalSince1970: 1_787_000_000)

    /// Fills a library with realistic demo content.
    ///
    /// - Parameter root: the library folder. Defaults to `$SOURCEDESK_SEED_ROOT`, or
    ///   a scratch path, so it can never write into a real library by accident.
    public static func run(root explicitRoot: String? = nil) throws {
        let root = explicitRoot
            ?? ProcessInfo.processInfo.environment["SOURCEDESK_SEED_ROOT"]
            ?? "/tmp/sd-demo/Library/Application Support/SourceDesk"
        let paths = AppPaths(root: URL(fileURLWithPath: root))
        let store = try NotebookStore(paths: paths)
        let settingsStore = SettingsStore(store: store)
        let embedder = BuiltInEmbedder()

        print("Seeding library at \(paths.root.path)")

        // Relative ages are fixed rather than random: these values are screenshotted, and a
        // random spread produced a different "added" age on every run.
        let demoNow = Self.demoNow

        // Two notebooks, so the sidebar shows structure.
        let primary = try store.upsert(notebook: Notebook(
            title: "Industrial Decline",
            summary: "Why inspection throughput fell across the seven regions",
            lastOpenedAt: demoNow,
            isFavorite: true
        ))
        let secondary = try store.upsert(notebook: Notebook(
            title: "Reading Notes: Regulatory Reform",
            summary: "Background reading for the reform chapter",
            createdAt: demoNow,
            updatedAt: demoNow,
            accentIndex: 2
        ))

        let documents: [(notebook: Notebook, title: String, kind: SourceKind, url: String?, text: String)] = [
            (primary, "Inspectorate Annual Report 2024", .pdf, "https://inspectorate.example.gov/reports/2024",
             """
             # Findings

             The review board examined inspection throughput across all seven regions.

             ## The decline

             Throughput fell by nineteen percent after the inspection schedule was reorganised in March. The board identified two causes: an administrative reorganisation and a shortage of qualified inspectors.

             Budget pressure meant two regional offices closed, concentrating work in the remaining four. Permit applications took an average of forty one days to process in the following quarter, against a baseline of twenty two days.

             ## Recommendations

             The board recommended retaining the regional offices and recruiting twelve additional inspectors before the next fiscal year.
             """),
            (primary, "News: Permits slow to a crawl in the north", .website, "https://news.example.com/permits-delay",
             """
             Applicants in the northern region waited more than six weeks for a routine permit this spring.

             Officials blamed staffing shortages and a new centralised scheduling system introduced in March. Independent analysts argued the decline began earlier, when the central office reorganised its inspection schedule.

             A spokesperson said the backlog would be cleared within ninety days.
             """),
            (primary, "Administrative reform and regulatory output", .docx, nil,
             """
             # Abstract

             This study examines regulatory output following administrative reorganisation. Using inspection logs from 2015 to 2024, we find a persistent decline in throughput of seventeen to twenty two percent.

             We argue the effect is driven by coordination costs rather than budget constraints alone.

             ## Method

             We compared inspection logs with the previous baseline and controlled for regional staffing levels.
             """),
            (primary, "Interview transcript: former regional inspector", .pastedText, nil,
             """
             The reorganisation sounded simple. In practice it meant every inspection had to be scheduled through a central desk that did not know the districts.

             We lost about a day a week to scheduling alone. Nobody cut the budget; the money was still there. What changed was how long it took to get to the work.
             """),
            (secondary, "Regulatory Reform in Comparative Perspective", .pdf, nil,
             """
             # Introduction

             Comparative studies of regulatory reform suggest that centralisation produces short-term output losses and longer-term gains in consistency.

             ## Evidence

             Three of the four cases examined show an initial decline of between ten and twenty five percent in inspection volume, recovering within three years.
             """),
        ]

        var documentIndex = 0

        for document in documents {
            documentIndex += 1
            let addedAt = demoNow.addingTimeInterval(-Double(documentIndex) * 86_400)
            var source = try store.upsert(source: Source(
                notebookID: document.notebook.id,
                kind: document.kind,
                title: document.title,
                url: document.url,
                wordCount: TextMath.wordCount(document.text),
                pageCount: document.kind == .pdf ? 14 : nil,
                status: .ready,
                addedAt: addedAt,
                extractionMethod: document.kind == .website ? "readability" : (document.kind == .pdf ? "pdfkit" : "plain text"),
                fetchMilliseconds: document.kind == .website ? 412 : nil
            ))

            let blocks = Markdownish.parse(document.text)
            let extracted = ExtractedDocument(
                title: document.title,
                method: source.extractionMethod ?? "seed",
                pages: [ExtractedPage(number: source.pageCount != nil ? 1 : 0, blocks: blocks)]
            )
            try FileStore.write(document.text, to: paths.extractedTextURL(for: source.id))
            source.contentPath = paths.extractedTextURL(for: source.id).path

            let chunks = TextChunker.chunk(
                document: extracted,
                sourceID: source.id,
                notebookID: document.notebook.id,
                configuration: TextChunker.Configuration(targetTokens: 180, maximumTokens: 280, overlapTokens: 40)
            )
            let embeddings = chunks.map { chunk in
                ChunkEmbedding(chunkID: chunk.id, sourceID: source.id, notebookID: document.notebook.id,
                               model: embedder.identifier, vector: embedder.embedOne(chunk.text))
            }
            try store.replaceChunks(sourceID: source.id, notebookID: document.notebook.id, chunks: chunks, embeddings: embeddings)
            source.chunkCount = chunks.count
            _ = try store.upsert(source: source)
            print("  source: \(document.title) — \(Format.count(chunks.count, "passage"))")
        }

        // A failed source, so the error handling is visible in the UI. Its title is written
        // the way a real one would be — a page that fails still had a name, and repeating the
        // URL as the title made the row look like a bug rather than a state.
        _ = try store.upsert(source: Source(
            notebookID: primary.id,
            kind: .website,
            title: "Analysis: regional inspection capacity (subscriber access)",
            url: "https://www.example.com/paywalled-analysis",
            status: .failed,
            errorMessage: "The page is behind a subscription paywall.",
            errorRecovery: "Sign in through your browser and save the article as a PDF, then import that file."
        ))

        // A conversation with citations and a retrieval trace.
        let session = try store.upsert(session: ChatSession(
            notebookID: primary.id,
            title: "What caused the decline?",
            scope: .notebookSources,
            providerID: "ollama",
            modelName: "llama3.2:3b"
        ))
        try store.upsert(message: ChatMessage(
            sessionID: session.id, notebookID: primary.id, role: .user,
            content: "What caused the decline in inspection throughput?",
            createdAt: demoNow.addingTimeInterval(-300)
        ))

        let sources = try store.sources(notebookID: primary.id)
        if let report = sources.first(where: { $0.title.contains("Inspectorate") }) {
            let chunks = try store.chunks(sourceID: report.id)
            if let chunk = chunks.first(where: { $0.text.contains("nineteen percent") }) ?? chunks.first {
                let citation = Citation(
                    kind: .notebook, marker: "[Source 1]", sourceID: report.id, chunkID: chunk.id,
                    title: report.title, location: report.url, url: report.url,
                    pageNumber: chunk.pageNumber, headingPath: chunk.headingPath,
                    excerpt: TextMath.preview(chunk.text, limit: 500), score: 0.87
                )
                let news = sources.first(where: { $0.title.contains("News") })
                let newsChunk = news.flatMap { try? store.chunks(sourceID: $0.id).first(where: { $0.text.contains("six weeks") }) }
                var citations = [citation]
                if let news, let newsChunk {
                    citations.append(Citation(
                        kind: .notebook, marker: "[Source 2]", sourceID: news.id, chunkID: newsChunk.id,
                        title: news.title, url: news.url, excerpt: TextMath.preview(newsChunk.text, limit: 400), score: 0.71
                    ))
                }

                let hits = citations.enumerated().map { index, item in
                    RetrievalTrace.Hit(
                        chunkID: item.chunkID ?? "", sourceID: item.sourceID ?? "", sourceTitle: item.title,
                        semanticScore: index == 0 ? 0.71 : 0.62, keywordScore: index == 0 ? 5.4 : 3.1,
                        fusedScore: index == 0 ? 0.92 : 0.66, rerankScore: item.score,
                        pageNumber: item.pageNumber, headingPath: item.headingPath,
                        preview: item.excerpt, embeddingModel: embedder.identifier, usedInContext: true
                    )
                }

                try store.upsert(message: ChatMessage(
                    sessionID: session.id, notebookID: primary.id, role: .assistant,
                    content: """
                    The sources identify two causes working together. [Source 1]

                    - **An administrative reorganisation.** Inspections were moved to a central scheduling desk in March, which added coordination overhead to every job and slowed processing. [Source 1]
                    - **A shortage of qualified inspectors.** Two regional offices closed under budget pressure, concentrating the remaining work into four offices. [Source 1]

                    Permit processing shows the same pattern: an average of forty one days, against a baseline of twenty two. [Source 1] Regional reporting adds that applicants in the north waited more than six weeks for a routine permit. [Source 2]

                    Independent analysts quoted alongside the official account argue the decline began earlier than March, when the reorganisation was announced rather than implemented. The sources disagree on timing, not on cause.
                    """,
                    createdAt: demoNow.addingTimeInterval(-280),
                    citations: citations,
                    retrieval: RetrievalTrace(
                        query: "What caused the decline in inspection throughput?",
                        candidateCount: 34, hits: hits, usedTokens: 1_842, contextBudget: 8_192,
                        semanticEnabled: true, keywordEnabled: true, rerankEnabled: true,
                        webResultCount: 0,
                        notes: ["Hybrid retrieval ran; per-source limit capped this source at 3 passages."],
                        durationMilliseconds: 38
                    ),
                    providerID: "ollama", modelName: "llama3.2:3b",
                    latencyMilliseconds: 2_140, promptTokens: 2_010, completionTokens: 168
                ))
            }
        }

        // Notes, including a study set with structured content.
        try store.upsert(note: NotebookNote(
            notebookID: primary.id,
            title: "Summary · Inspectorate Annual Report 2024",
            body: """
            ### Overview
            The inspectorate's annual review of inspection throughput across seven regions, covering the period after the March reorganisation. [Source 1]

            ### Main points
            - Throughput fell nineteen percent after the inspection schedule was reorganised in March. [Source 1]
            - Two causes are named: an administrative reorganisation and a shortage of qualified inspectors. [Source 1]
            - Two regional offices closed, concentrating work in the remaining four. [Source 1]
            - Permit processing averaged forty one days, against a twenty two day baseline. [Source 1]

            ### What the sources do not settle
            Whether the decline began before or after the reorganisation was implemented. [Source 1] [Source 2]
            """,
            kind: .summary,
            sourceIDs: sources.prefix(2).map(\.id),
            providerID: "ollama", modelName: "llama3.2:3b"
        ))

        try store.upsert(note: NotebookNote(
            notebookID: primary.id,
            title: "Flashcards · causes and figures",
            body: "Q: What caused the decline?\nA: An administrative reorganisation and a shortage of qualified inspectors. [Source 1]",
            kind: .flashcards,
            sourceIDs: sources.prefix(2).map(\.id),
            providerID: "ollama", modelName: "llama3.2:3b",
            payload: NotePayload(flashcards: [
                Flashcard(front: "By what percentage did inspection throughput fall?",
                          back: "Nineteen percent, after the inspection schedule was reorganised in March.", sourceMarker: "[Source 1]"),
                Flashcard(front: "How long did permit applications take after the reorganisation?",
                          back: "An average of forty one days, against a twenty two day baseline.", sourceMarker: "[Source 1]"),
                Flashcard(front: "What did the news report add to the official account?",
                          back: "That applicants in the north waited more than six weeks, and that analysts place the start of the decline earlier.", sourceMarker: "[Source 2]")
            ])
        ))

        try store.upsert(note: NotebookNote(
            notebookID: primary.id,
            title: "Quiz · the decline in detail",
            body: "1. What caused the decline in inspection throughput?",
            kind: .quiz,
            sourceIDs: sources.prefix(2).map(\.id),
            payload: NotePayload(quizItems: [
                QuizItem(question: "What caused the decline in inspection throughput?",
                         choices: ["Budget pressure alone", "An administrative reorganisation and a shortage of inspectors",
                                   "A fall in demand for permits", "A change in legislation"],
                         answerIndex: 1,
                         explanation: "The board identified both an administrative reorganisation and a shortage of qualified inspectors. [Source 1]",
                         sourceMarker: "[Source 1]"),
                QuizItem(question: "How did permit processing times change?",
                         choices: ["They fell to twenty two days", "They stayed at twenty two days",
                                   "They rose to forty one days", "They rose to ninety days"],
                         answerIndex: 2,
                         explanation: "Applications averaged forty one days in the following quarter, against a baseline of twenty two. [Source 1]",
                         sourceMarker: "[Source 1]")
            ])
        ))

        // Settings that reflect a realistic local-first configuration.
        var settings = settingsStore.load()
        settings.preferredProviderID = "ollama"
        settings.modelSelection["ollama"] = "llama3.2:3b"
        settings.searchEngine = .duckduckgo
        settings.appearance = .system
        settings.showInspector = true
        try settingsStore.save(settings)

        print("Done.")
        print("  notebooks: \(try store.notebooks().count)")
        print("  sources:   \(try store.db.scalarInt("SELECT COUNT(*) FROM sources;"))")
        print("  chunks:    \(try store.db.scalarInt("SELECT COUNT(*) FROM chunks;"))")
        print("  notes:     \(try store.db.scalarInt("SELECT COUNT(*) FROM notes;"))")
        print("  messages:  \(try store.db.scalarInt("SELECT COUNT(*) FROM messages;"))")
    }
}
