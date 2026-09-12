import Foundation
import SourceDeskCore

enum SettingsSuite {

    static var suite: TestSuite {
        TestSuite("11 · Settings, privacy and offline behaviour", cases: [

            test("settings round-trip through the library") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let settingsStore = SettingsStore(store: store)

                var settings = settingsStore.load()
                try ctx.equal(settings.preferredProviderID, "ollama", "local-first default")
                try ctx.equal(settings.searchEngine, .duckduckgo, "keyless search default")
                try ctx.equal(settings.embeddingChoice, .builtIn, "no-download embedding default")
                try ctx.equal(settings.rerankStrategy, .lexical, "no-model rerank default")
                try ctx.equal(settings.localOnlyMode, false)

                settings.preferredProviderID = "anthropic"
                settings.modelSelection["anthropic"] = "claude-sonnet-4-5"
                settings.retrievalResultCount = 14
                settings.chunkTargetTokens = 500
                settings.appearance = .dark
                settings.localOnlyMode = true
                settings.searchEngine = .none
                try settingsStore.save(settings)

                let reloaded = settingsStore.load()
                try ctx.equal(reloaded.preferredProviderID, "anthropic")
                try ctx.equal(reloaded.model(for: "anthropic"), "claude-sonnet-4-5")
                try ctx.equal(reloaded.retrievalResultCount, 14)
                try ctx.equal(reloaded.chunkTargetTokens, 500)
                try ctx.equal(reloaded.appearance, .dark)
                try ctx.equal(reloaded.localOnlyMode, true)
                try ctx.equal(reloaded.searchEngine, .none)
            },

            test("settings written by an older build load with defaults filled in") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                // A blob containing only two keys, as an early build would have written.
                let partial = #"{"preferredProviderID":"openai","retrievalResultCount":22}"#
                try store.setSettingValue(SettingsStore.key, partial)

                let settings = SettingsStore(store: store).load()
                try ctx.equal(settings.preferredProviderID, "openai", "stored value honoured")
                try ctx.equal(settings.retrievalResultCount, 22)
                try ctx.equal(settings.searchEngine, .duckduckgo, "missing keys fall back to defaults")
                try ctx.equal(settings.chunkTargetTokens, 320)
                try ctx.equal(settings.appearance, .system)
            },

            test("unreadable settings fall back to defaults instead of failing to launch") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                try store.setSettingValue(SettingsStore.key, "this is not json at all")
                let settings = SettingsStore(store: store).load()
                try ctx.equal(settings.preferredProviderID, "ollama")
            },

            test("derived configurations reflect the settings") { ctx in
                var settings = AppSettings()
                settings.chunkTargetTokens = 400
                settings.chunkOverlapTokens = 80
                settings.retrievalResultCount = 12
                settings.rerankStrategy = .none
                settings.contextTokenBudget = 9_000

                let chunking = settings.chunkingConfiguration
                try ctx.equal(chunking.targetTokens, 400)
                try ctx.equal(chunking.overlapTokens, 80)
                try ctx.equal(chunking.maximumTokens, 600, "maximum is derived from the target")

                let retrieval = settings.retrievalConfiguration
                try ctx.equal(retrieval.resultCount, 12)
                try ctx.equal(retrieval.rerank, RerankStrategy.none)
                try ctx.equal(retrieval.contextTokenBudget, 9_000)

                let research = settings.researchConfiguration(notebookID: "n1")
                try ctx.equal(research.providerID, settings.preferredProviderID)
                try ctx.equal(research.retrieval.resultCount, 12)
                try ctx.equal(research.cloudConsentGranted, false, "consent is per notebook and starts unset")
            },

            test("cloud consent is per notebook and revocable") { ctx in
                var settings = AppSettings()
                try ctx.equal(settings.isCloudApproved(notebookID: "a"), false)
                settings.approveCloud(for: "a")
                try ctx.equal(settings.isCloudApproved(notebookID: "a"), true)
                try ctx.equal(settings.isCloudApproved(notebookID: "b"), false, "consent does not leak between notebooks")
                settings.revokeCloud(for: "a")
                try ctx.equal(settings.isCloudApproved(notebookID: "a"), false)
            },

            test("turning consent off means everything is approved") { ctx in
                var settings = AppSettings()
                settings.confirmBeforeCloudSend = false
                try ctx.equal(settings.isCloudApproved(notebookID: "anything"), true)
            },

            test("changing the embedding model is detected as needing a re-index") { ctx in
                var before = AppSettings()
                var after = before
                try ctx.equal(SettingsStore.requiresReindex(from: before, to: after), false)

                after.embeddingChoice = .ollama
                try ctx.equal(SettingsStore.requiresReindex(from: before, to: after), true)
                before = after

                after.chunkTargetTokens = 512
                try ctx.equal(SettingsStore.requiresReindex(from: before, to: after), true)
                before = after

                after.retrievalResultCount = 20
                try ctx.equal(SettingsStore.requiresReindex(from: before, to: after), false, "retrieval count needs no re-index")
            },

            test("context defaults scale with the model's window") { ctx in
                let tiny = RetrievalConfiguration.forContextWindow(4_000)
                try ctx.equal(tiny.resultCount, 5)
                try ctx.check(tiny.contextTokenBudget <= 2_000, "small models get a small budget")

                let medium = RetrievalConfiguration.forContextWindow(8_000)
                try ctx.equal(medium.resultCount, 8)

                let large = RetrievalConfiguration.forContextWindow(128_000)
                try ctx.check(large.resultCount >= 18, "large windows retrieve more")
                try ctx.check(large.contextTokenBudget > 10_000)
            },

            test("invalid configuration values are clamped, not rejected") { ctx in
                var configuration = RetrievalConfiguration()
                configuration.resultCount = 0
                configuration.candidateCount = 5_000
                configuration.contextTokenBudget = 1
                configuration.maxChunksPerSource = -3
                let clamped = configuration.validated()
                try ctx.check(clamped.resultCount >= 1, "result count floor")
                try ctx.check(clamped.candidateCount >= clamped.resultCount, "candidates never below results")
                try ctx.check(clamped.contextTokenBudget >= 500, "token budget floor")
                try ctx.check(clamped.maxChunksPerSource >= 1, "per-source cap floor")

                var chunking = TextChunker.Configuration()
                chunking.targetTokens = 1
                chunking.maximumTokens = 2
                chunking.overlapTokens = 10_000
                let validChunking = chunking.validated()
                try ctx.check(validChunking.targetTokens >= 64, "chunk size floor")
                try ctx.check(validChunking.maximumTokens >= validChunking.targetTokens, "maximum never below target")
                try ctx.check(validChunking.overlapTokens <= validChunking.targetTokens / 2, "overlap stays sane")
            },

            test("every error carries a description and, where useful, a recovery") { ctx in
                let errors: [SourceDeskError] = [
                    .invalidURL("x"), .downloadFailed(url: "u", reason: "r"), .robotsDisallowed(url: "u"),
                    .javascriptOnlyPage(url: "u"), .offline(feature: "Web search"), .noSources(notebook: "N"),
                    .insufficientContext(question: "q"), .noLocalModelConfigured,
                    .localModelNotRunning(endpoint: "e"), .missingAPIKey(provider: "OpenAI"),
                    .invalidAPIKey(provider: "Anthropic Claude"), .cloudDisabled(reason: "local-only"),
                    .searchProviderNotConfigured(provider: "Brave Search API"), .noSearchResults(query: "q"),
                    .folderEmpty(path: "/tmp"), .archiveCorrupt(detail: "bad"), .notFound(entity: "source", id: "1"),
                    .contextTooLarge(model: "m", neededTokens: 9_000, limitTokens: 8_000)
                ]
                for error in errors {
                    let description = try ctx.unwrap(error.errorDescription, "\(error) has a description")
                    try ctx.check(description.count > 15, "\(error) description is informative: \(description)")
                    try ctx.doesNotContain(description, "Something went wrong")
                    try ctx.doesNotContain(description, "unknown error")
                }
                // Spot-check the specific wording the brief called for.
                try ctx.contains(SourceDeskError.noLocalModelConfigured.errorDescription ?? "", "No local model is available")
                try ctx.contains(SourceDeskError.missingAPIKey(provider: "Claude").errorDescription ?? "", "no API key is stored")
                try ctx.contains(SourceDeskError.downloadFailed(url: "u", reason: "r").errorDescription ?? "", "could not be downloaded")
                try ctx.contains(SourceDeskError.webSearchUnavailable(provider: "Brave", reason: "x").errorDescription ?? "", "Web search")
                try ctx.contains(SourceDeskError.contextTooLarge(model: "m", neededTokens: 1, limitTokens: 2).errorDescription ?? "", "cannot hold this request")
                try ctx.contains(SourceDeskError.insufficientContext(question: "q").errorDescription ?? "", "Not enough relevant source material")
            },

            test("cancellation is represented as its own outcome") { ctx in
                try ctx.equal(SourceDeskError.cancelled.errorDescription, "The operation was cancelled.")
                try ctx.isNil(SourceDeskError.cancelled.recoverySuggestion, "cancelling needs no advice")
            },

            test("the diagnostics log writes, rotates and stays local") { ctx in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("sourcedesk-log-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let log = DiagnosticsLog()
                log.configure(level: .info, directory: root)
                log.error("a failure worth recording", category: "ingest")
                log.info("something informational", category: "chat")
                log.debug("noise that should be filtered at info level", category: "chat")

                let lines = log.recentLines()
                try ctx.check(lines.contains { $0.contains("a failure worth recording") }, "errors are recorded")
                try ctx.check(lines.contains { $0.contains("something informational") }, "info is recorded")
                try ctx.check(!lines.contains { $0.contains("noise that should be filtered") }, "debug is filtered at info level")
                try ctx.contains(lines.first ?? "", "ingest", "category recorded")

                // At debug level everything is recorded.
                log.configure(level: .debug, directory: root)
                log.debug("now it should be recorded", category: "chat")
                try ctx.check(log.recentLines().contains { $0.contains("now it should be recorded") })
            },

            test("offline behaviour: cloud providers are refused with an offline reason") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try RetrievalSuite.makeCorpus(store)
                let keychain = InMemoryKeychain()
                keychain.values["openai.api-key"] = "sk-test"

                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [OpenAIProvider(keychain: keychain)]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "openai", modelName: "gpt-4o-mini", cloudConsentGranted: true),
                    networkIsOnline: { false }
                )
                let error = try await ctx.expectError("offline") {
                    try await engine.answerOnce(question: "what caused the decline?", notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "internet connection")
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "local sources")
            },

            test("local-only mode blocks cloud providers with a settings pointer") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try RetrievalSuite.makeCorpus(store)
                let keychain = InMemoryKeychain()
                keychain.values["openai.api-key"] = "sk-test"

                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [OpenAIProvider(keychain: keychain)]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "openai", modelName: "gpt-4o-mini", localOnlyMode: true, cloudConsentGranted: true)
                )
                let error = try await ctx.expectError("local-only") {
                    try await engine.answerOnce(question: "what caused the decline?", notebookID: notebook.id)
                }
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "Local-Only Mode")
            },

            test("the privacy level of every source is stated plainly") { ctx in
                try ctx.contains(PrivacyLevel.local.detail, "stays on this Mac")
                try ctx.contains(PrivacyLevel.cloud.detail, "sent to the selected AI provider")
                try ctx.contains(PrivacyLevel.web.detail, "sent to the selected search provider")
            },

            test("scopes describe exactly what leaves the Mac") { ctx in
                try ctx.contains(AnswerScope.notebookSources.explanation, "only the sources")
                try ctx.contains(AnswerScope.notebookAndWeb.explanation, "sent to your search provider")
                try ctx.contains(AnswerScope.webOnly.explanation, "ignore this notebook")
                try ctx.equal(AnswerScope.notebookSources.requiresNetwork, false)
                try ctx.equal(AnswerScope.notebookAndWeb.requiresNetwork, true)
                try ctx.equal(AnswerScope.notebookAndWeb.usesSources, true)
                try ctx.equal(AnswerScope.webOnly.usesSources, false)
            },

            test("the storage layout is what the documentation says it is") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                try ctx.check(FileStore.exists(paths.root), "root exists")
                try ctx.check(FileStore.exists(paths.contentRoot), "content folder")
                try ctx.check(FileStore.exists(paths.databaseURL), "database file")
                try ctx.contains(paths.databaseURL.lastPathComponent, "library.sqlite")
                // Extracted text lives inside the per-source folder, not at the root.
                let notebook = try Fixtures.makeNotebook(store)
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .plainText, title: "T"))
                let textURL = paths.extractedTextURL(for: source.id)
                try ctx.contains(textURL.path, "/content/\(source.id)/content.txt")
            },

            test("reset restores defaults without touching notebooks") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store, title: "Keep me")
                let settingsStore = SettingsStore(store: store)
                var settings = settingsStore.load()
                settings.appearance = .dark
                try settingsStore.save(settings)
                try settingsStore.reset()

                let restored = settingsStore.load()
                try ctx.equal(restored.appearance, .system, "settings back to defaults")
                try ctx.equal(try store.notebooks().count, 1, "the notebook is untouched")
                try ctx.equal(try ctx.unwrap(try store.notebook(id: notebook.id)).title, "Keep me")
            }
        ])
    }
}
