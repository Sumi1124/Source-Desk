import Foundation
import SwiftUI
import SourceDeskCore

/// The application's single coordinator.
///
/// It owns the store, the provider registry, the network monitor and the settings,
/// and it is the only place that constructs services. Views observe it; they never
/// touch the database or a provider directly, which is what keeps the UI layer free
/// of retrieval or persistence logic.
@Observable
@MainActor
public final class AppState {

    // MARK: Stored state

    private(set) var paths: AppPaths
    private(set) var store: NotebookStore?
    private(set) var settingsStore: SettingsStore?
    private(set) var settings = AppSettings()

    /// Everything the sidebar lists.
    var notebooks: [Notebook] = []
    var sources: [Source] = []
    var sessions: [ChatSession] = []
    var notes: [NotebookNote] = []

    var selectedNotebookID: RecordID?
    var selectedSourceID: RecordID?
    var selectedSessionID: RecordID?
    var selectedNoteID: RecordID?

    /// Which section of the centre column is showing.
    enum Section: String, CaseIterable, Identifiable {
        case research, sources, notes, studyTools, search
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .research: return "Research"
            case .sources: return "Sources"
            case .notes: return "Notes"
            case .studyTools: return "Study Tools"
            case .search: return "Search"
            }
        }
        var symbolName: String {
            switch self {
            case .research: return "bubble.left.and.text.bubble.right"
            case .sources: return "doc.on.doc"
            case .notes: return "note.text"
            case .studyTools: return "graduationcap"
            case .search: return "magnifyingglass"
            }
        }
    }
    var section: Section = .research

    // MARK: Runtime state

    private(set) var providers: ProviderRegistry
    let network = NetworkMonitor()
    var networkStatus: NetworkMonitor.Status = .unknown
    var isOnline: Bool { networkStatus == .online || networkStatus == .unknown }

    /// Models available per provider, discovered lazily.
    var availableModels: [String: [ModelDescriptor]] = [:]
    var modelDiscoveryState: [String: ProviderAvailability] = [:]
    /// Which providers have been probed this session.
    var probedProviders: Set<String> = []

    /// Long-running work the UI shows progress for.
    var ingestion: IngestionProgress?
    var isGenerating = false
    var generationStage: AnswerEngine.Stage?
    var statusMessage: String?
    var lastError: PresentedError?

    /// Banners and one-time confirmations.
    var cloudConsentPromptNotebookID: RecordID?

    /// The most recent answer, so the inspector can show its sources.
    var activeCitations: [Citation] = []
    var activeTrace: RetrievalTrace?

    var commandPaletteVisible = false

    // MARK: Ingestion progress

    struct IngestionProgress: Equatable {
        var title: String
        var stage: String
        var overall: Double
        var itemIndex: Int
        var itemCount: Int
    }

    // MARK: Errors

    struct PresentedError: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
        var recovery: String?
        var isWarning: Bool = false

        init(_ error: SourceDeskError, isWarning: Bool = false) {
            self.title = "Couldn't complete that"
            self.message = error.errorDescription ?? "\(error)"
            self.recovery = error.recoverySuggestion
            self.isWarning = isWarning
        }

        init(title: String, message: String, recovery: String? = nil, isWarning: Bool = false) {
            self.title = title
            self.message = message
            self.recovery = recovery
            self.isWarning = isWarning
        }
    }

    // MARK: Lifecycle

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.providers = ProviderRegistry.standard(ollamaEndpoint: URL(string: "http://127.0.0.1:11434")!)
        network.observe { [weak self] status in
            Task { @MainActor in self?.networkStatus = status }
        }
    }

    /// Opens the library. Called once at launch and again if the storage location
    /// changes in Settings.
    func start() {
        do {
            let store = try NotebookStore(paths: paths)
            self.store = store
            let settingsStore = SettingsStore(store: store)
            self.settingsStore = settingsStore
            self.settings = settingsStore.load()
            self.providers = makeProviders()
            DiagnosticsLog.shared.configure(level: settings.logLevel, directory: paths.logsRoot)
            DiagnosticsLog.shared.info("Opened library at \(paths.root.path)", category: "lifecycle")
            reloadAll()
            if selectedNotebookID == nil, let first = notebooks.first {
                selectNotebook(first.id)
            }
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't open your library", message: error.localizedDescription)
        }
    }

    private func makeProviders() -> ProviderRegistry {
        var providers: [AIProvider] = [
            OllamaProvider(endpoint: settings.ollamaEndpointURL, host: .local),
            OpenAIProvider(baseURL: settings.openAIBaseURLValue),
            AnthropicProvider(baseURL: settings.anthropicBaseURLValue)
        ]
        // Ollama's hosted API, or any other remote Ollama host the user configured.
        // Declared as cloud so consent, offline checks and privacy labelling always
        // apply to it, regardless of the host it points at.
        let hosted = OllamaProvider(endpoint: settings.ollamaCloudEndpointURL, host: .cloud)
        // Guard against listing the same provider twice if both endpoints resolve to
        // the same kind of host.
        if !providers.contains(where: { $0.identifier == hosted.identifier }) {
            providers.append(hosted)
        }
        return ProviderRegistry(providers: providers)
    }

    // MARK: Services

    var embedder: EmbeddingProvider? {
        EmbeddingProviderFactory.make(
            choice: settings.embeddingChoice,
            ollamaModel: settings.ollamaEmbeddingModel,
            ollamaEndpoint: settings.ollamaEndpointURL
        )
    }

    var searchProvider: SearchProvider? {
        SearchProviderFactory.make(choice: settings.searchEngine)
    }

    var webSearch: WebSearchService? {
        guard let provider = searchProvider else { return nil }
        return WebSearchService(
            provider: provider,
            downloader: WebDownloader(options: WebDownloader.Options(
                maximumBytes: settings.maximumPageBytes,
                timeout: settings.requestTimeoutSeconds,
                respectRobotsTxt: settings.respectRobotsTxt
            ))
        )
    }

    func ingestionService() -> SourceIngestionService? {
        guard let store else { return nil }
        return SourceIngestionService(
            store: store,
            configuration: SourceIngestionService.Configuration(
                chunking: settings.chunkingConfiguration,
                download: WebDownloader.Options(
                    maximumBytes: settings.maximumPageBytes,
                    timeout: settings.requestTimeoutSeconds,
                    respectRobotsTxt: settings.respectRobotsTxt
                ),
                document: DocumentExtractor.Options(maximumBytes: settings.maximumImportBytes),
                embeddingsEnabled: settings.embeddingChoice != .disabled
            ),
            embedder: embedder
        )
    }

    func answerEngine(notebookID: RecordID) -> AnswerEngine? {
        guard let store else { return nil }
        return AnswerEngine(
            store: store,
            providers: providers,
            embedder: embedder,
            search: settings.searchEngine == .none ? nil : webSearch,
            configuration: settings.researchConfiguration(notebookID: notebookID),
            networkIsOnline: { [isOnline] in isOnline }
        )
    }

    func studyService(notebookID: RecordID) -> StudyToolsService? {
        guard let store else { return nil }
        return StudyToolsService(
            store: store,
            providers: providers,
            embedder: embedder,
            configuration: settings.studyConfiguration(notebookID: notebookID),
            networkIsOnline: { [isOnline] in isOnline }
        )
    }

    // MARK: Loading

    func reloadAll() {
        reloadNotebooks()
        reloadNotebookContent()
    }

    func reloadNotebooks() {
        guard let store else { return }
        do {
            notebooks = try store.notebooks()
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't load notebooks", message: error.localizedDescription)
        }
    }

    func reloadNotebookContent() {
        guard let store, let notebookID = selectedNotebookID else {
            sources = []; sessions = []; notes = []
            return
        }
        do {
            sources = try store.sources(notebookID: notebookID)
            sessions = try store.sessions(notebookID: notebookID)
            notes = try store.notes(notebookID: notebookID)
            if selectedSourceID == nil { selectedSourceID = sources.first?.id }
            if selectedSessionID == nil { selectedSessionID = sessions.first?.id }
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't load this notebook", message: error.localizedDescription)
        }
    }

    // MARK: Notebooks

    func createNotebook(title: String, summary: String = "") -> Notebook? {
        guard let store else { return nil }
        let notebook = Notebook(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled notebook" : title,
            summary: summary,
            accentIndex: notebooks.count % 6
        )
        do {
            let saved = try store.upsert(notebook: notebook)
            reloadNotebooks()
            selectNotebook(saved.id)
            statusMessage = "Created “\(saved.title)”"
            return saved
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't create the notebook", message: error.localizedDescription)
        }
        return nil
    }

    func selectNotebook(_ id: RecordID) {
        guard id != selectedNotebookID else { return }
        selectedNotebookID = id
        selectedSourceID = nil
        selectedSessionID = nil
        selectedNoteID = nil
        activeCitations = []
        activeTrace = nil
        if let store, let notebook = try? store.notebook(id: id) {
            try? store.touchNotebook(id: id, opened: true)
            statusMessage = notebook.summary.isEmpty ? nil : notebook.summary
        }
        reloadNotebooks()
        reloadNotebookContent()
    }

    var selectedNotebook: Notebook? {
        notebooks.first { $0.id == selectedNotebookID }
    }

    var selectedSource: Source? {
        sources.first { $0.id == selectedSourceID }
    }

    func toggleFavorite(_ notebook: Notebook) {
        guard let store else { return }
        var copy = notebook
        copy.isFavorite.toggle()
        do {
            try store.upsert(notebook: copy)
            reloadNotebooks()
        } catch {
            lastError = PresentedError(title: "Couldn't update the notebook", message: error.localizedDescription)
        }
    }

    func renameNotebook(_ notebook: Notebook, to title: String) {
        guard let store else { return }
        var copy = notebook
        copy.title = title
        try? store.upsert(notebook: copy)
        reloadNotebooks()
    }

    func deleteNotebook(_ id: RecordID) {
        guard let store else { return }
        do {
            try store.deleteNotebook(id: id)
            if selectedNotebookID == id {
                selectedNotebookID = nil
                selectedSourceID = nil
                selectedSessionID = nil
                activeCitations = []
            }
            reloadNotebooks()
            reloadNotebookContent()
            if selectedNotebookID == nil, let first = notebooks.first { selectNotebook(first.id) }
            statusMessage = "Notebook deleted"
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't delete the notebook", message: error.localizedDescription)
        }
    }

    func setDefaultScope(_ scope: AnswerScope) {
        guard let store, let id = selectedNotebookID, var notebook = selectedNotebook else { return }
        notebook.defaultScope = scope
        try? store.upsert(notebook: notebook)
        reloadNotebooks()
    }

    // MARK: - Research (search the web, add the sources, make the note)

    /// What a research run did, so the UI can report it honestly.
    struct ResearchOutcome: Equatable {
        var topic: String
        var searched: Int
        var added: Int
        var failed: Int
        var noteTitle: String?
        var noteError: String?
        var wasCancelled: Bool = false

        var summary: String {
            if wasCancelled { return "Research cancelled — kept \(added) of \(searched) sources." }
            if added == 0 { return "No sources could be added for “\(topic)”." }
            var text = "Added \(added) of \(searched) sources for “\(topic)”"
            if failed > 0 { text += " (\(failed) failed)" }
            if let noteTitle { text += " · note: \(noteTitle)" }
            return text + "."
        }
    }

    /// The last research run, for a progress sheet or a status line.
    var researchOutcome: ResearchOutcome?

    /// The running research job, so a long run can be cancelled.
    private(set) var researchTask: Task<Void, Never>?

    func cancelResearch() {
        researchTask?.cancel()
        researchTask = nil
        ingestion = nil
    }

    /// Which research sheet the UI should present, if any.
    ///
    /// The command palette is dismissed the moment a command runs, so a sheet attached
    /// to the palette would be torn down with it. The palette asks for the sheet here
    /// and `RootView` presents it, which keeps the sheet alive for the whole run.
    var researchRequest: ResearchRequest?

    struct ResearchRequest: Identifiable, Equatable {
        let id = UUID()
        var kind: ResearchSheetKind
    }

    enum ResearchSheetKind: String, Equatable, CaseIterable {
        case addSources
        case createNote

        var title: String {
            switch self {
            case .addSources: return "Research & Add Sources"
            case .createNote: return "Research & Create Note"
            }
        }

        var prompt: String {
            switch self {
            case .addSources:
                return "Enter a topic. SourceDesk searches the web, then downloads and indexes the top results as sources you can cite."
            case .createNote:
                return "Enter a topic. SourceDesk searches the web, adds the top results as sources, then writes a summary note from them."
            }
        }

        var noteKind: NoteKind? {
            switch self {
            case .addSources: return nil
            case .createNote: return .summary
            }
        }
    }

    /// Called by the command palette.
    func requestResearch(kind: ResearchSheetKind) {
        section = .research
        researchRequest = ResearchRequest(kind: kind)
    }

    /// Searches the web for a topic and adds the results as real sources.
    ///
    /// This is the "go find me material on X" workflow: it searches, then hands each
    /// result to the ordinary ingestion pipeline, so a researched source is
    /// indistinguishable from one the user pasted in — downloaded, extracted, cleaned,
    /// chunked, embedded and citable.
    ///
    /// It deliberately does *not* build sources out of search snippets. A snippet is a
    /// fragment of marketing copy lifted from a results page, so treating it as the
    /// source would mean citing text the author never wrote in that form. If a page
    /// cannot be downloaded, the source is reported as failed rather than quietly
    /// saved with no content.
    @discardableResult
    func researchAndAddSources(
        topic: String,
        notebookID: RecordID? = nil,
        resultCount: Int = 5,
        createNote: NoteKind? = nil
    ) -> Task<Void, Never>? {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { return nil }
        guard let targetNotebookID = notebookID ?? selectedNotebookID else {
            lastError = PresentedError(
                title: "No notebook is open",
                message: "Research adds its sources to a notebook.",
                recovery: "Create or open a notebook, then try again."
            )
            return nil
        }
        guard let service = ingestionService() else {
            lastError = PresentedError(title: "SourceDesk is not ready", message: "The library is still opening.")
            return nil
        }
        guard let searchProvider = searchProvider else {
            lastError = PresentedError(
                title: "Web search is not available",
                message: "No search provider is configured.",
                recovery: "Choose a search provider in Settings → Search."
            )
            return nil
        }
        guard searchProvider.isConfigured else {
            lastError = PresentedError(
                title: "\(searchProvider.displayName) needs a configuration",
                message: searchProvider.configurationHint ?? "This search provider is not ready to use.",
                recovery: "Open Settings → Search to configure it, or pick a different provider."
            )
            return nil
        }

        let count = min(max(1, resultCount), 20)
        let chunking = settings.chunkingConfiguration

        // Returned so the caller can cancel or await it; the UI keeps a handle so a
        // long run over many pages can be stopped.
        cancelResearch()
        let task = Task { @MainActor in
            let searchLimit = count
            var outcome = ResearchOutcome(topic: trimmedTopic, searched: 0, added: 0, failed: 0)
            isGenerating = true
            researchOutcome = nil
            defer {
                isGenerating = false
                ingestion = nil
                researchOutcome = outcome
            }

            do {
                // 1. Search.
                statusMessage = "Searching the web for “\(trimmedTopic)”…"
                statusMessage = "Searching the web for “\(trimmedTopic)”…"

                // 2. Ingest each result through the normal pipeline. The core owns the
                // per-result decisions (dedupe, "downloaded but empty", failures) so the
                // same rules apply here and in tests.
                let research = try await service.searchAndIngest(
                    query: trimmedTopic,
                    provider: searchProvider,
                    notebookID: targetNotebookID,
                    limit: searchLimit
                ) { [weak self] progress in
                    let stage = progress.stage.displayName
                    let title = progress.title
                    Task { @MainActor in
                        self?.ingestion = IngestionProgress(
                            title: title.isEmpty ? trimmedTopic : title,
                            stage: stage,
                            overall: progress.itemIndex > 1
                                ? Double(progress.itemIndex - 1) / Double(max(1, progress.itemCount))
                                : 0,
                            itemIndex: progress.itemIndex,
                            itemCount: progress.itemCount
                        )
                    }
                }

                outcome.searched = research.searched
                outcome.added = research.added.count
                outcome.failed = research.failed.count
                if research.cancelled { outcome.wasCancelled = true }
                reloadNotebookContent()

                guard outcome.added > 0 else {
                    statusMessage = "Nothing could be added for “\(trimmedTopic)”"
                    lastError = PresentedError(
                        title: "No usable pages",
                        message: "The search found \(outcome.searched) results, but none could be downloaded and read.",
                        recovery: "This can happen with JavaScript-only or access-restricted sites. Try a different topic."
                    )
                    return
                }

                // 3. Optional study note, grounded in what was just added.
                if let noteKind = createNote {
                    statusMessage = "Writing \(noteKind.displayName)…"
                    do {
                        let title = try await makeResearchNote(
                            topic: trimmedTopic,
                            kind: noteKind,
                            notebookID: targetNotebookID
                        )
                        outcome.noteTitle = title
                        statusMessage = "Added \(outcome.added) sources and created “\(title)”."
                    } catch let error as SourceDeskError {
                        // The sources are safe; only the note failed. Say so rather than
                        // implying the whole run was lost.
                        outcome.noteError = error.errorDescription
                        statusMessage = "Added \(outcome.added) sources; the note could not be generated."
                        lastError = PresentedError(error)
                    }
                    reloadNotebookContent()
                } else {
                    statusMessage = outcome.summary
                }
            } catch let error as SourceDeskError {
                statusMessage = "Research stopped"
                lastError = PresentedError(error)
            } catch is CancellationError {
                outcome.wasCancelled = true
                statusMessage = outcome.summary
            } catch {
                statusMessage = "Research stopped"
                lastError = PresentedError(title: "Research stopped", message: error.localizedDescription)
            }
        }
        researchTask = task
        return task
    }

    /// Generates a study note over a notebook's current sources.
    ///
    /// Returns the saved note's title, or throws so the caller can distinguish "the
    /// sources are fine but the note failed" from "the research failed".
    private func makeResearchNote(
        topic: String,
        kind: NoteKind,
        notebookID: RecordID
    ) async throws -> String {
        guard let study = studyService(notebookID: notebookID) else {
            throw SourceDeskError.noSources(notebook: selectedNotebook?.title ?? "this notebook")
        }
        // Passing no source IDs lets the note cover everything in the notebook, which is
        // what was just added. `generateOnce` surfaces the failure directly instead of
        // requiring the caller to walk the event stream for it.
        let outcome = try await study.generateOnce(
            tool: kind,
            notebookID: notebookID,
            sourceIDs: nil,
            focus: topic,
            title: "Research: \(topic)"
        )
        return outcome.note.title
    }

    func addSources(_ request: SourceIngestionService.Request, notebookID: RecordID? = nil) {

        guard let service = ingestionService(), let id = notebookID ?? selectedNotebookID else { return }
        Task {
            ingestion = IngestionProgress(title: "Preparing", stage: "Queued", overall: 0, itemIndex: 0, itemCount: 1)
            let result = await service.ingest(request: request, notebookID: id) { progress in
                Task { @MainActor in
                    self.ingestion = IngestionProgress(
                        title: progress.title,
                        stage: progress.stage.displayName,
                        overall: progress.overall,
                        itemIndex: progress.itemIndex + 1,
                        itemCount: progress.itemCount
                    )
                }
            }
            ingestion = nil
            reloadNotebookContent()

            if result.cancelled {
                statusMessage = "Import cancelled"
            } else if result.results.count == 1, let first = result.results.first {
                if let error = first.error {
                    lastError = PresentedError(error)
                } else {
                    statusMessage = "Added “\(first.source.title)” · \(first.chunkCount) passages"
                    if let notice = first.notices.first { lastError = PresentedError(title: "Added with a caveat", message: notice, isWarning: true) }
                    selectedSourceID = first.source.id
                }
            } else if !result.results.isEmpty {
                let added = result.added.count
                let failed = result.failed.count
                statusMessage = failed == 0
                    ? "Added \(added) sources · \(result.chunkCount) passages"
                    : "Added \(added) sources · \(failed) failed"
                if failed > 0 {
                    let first = result.failed[0]
                    lastError = PresentedError(title: "\(failed) source\(failed == 1 ? "" : "s") could not be added",
                                               message: "“\(first.source.title)”: \(first.error.errorDescription ?? "")",
                                               recovery: first.error.recoverySuggestion)
                }
            }
        }
    }

    func deleteSource(_ id: RecordID) {
        guard let store else { return }
        do {
            try store.deleteSource(id: id)
            if selectedSourceID == id { selectedSourceID = nil }
            reloadNotebookContent()
            statusMessage = "Source deleted"
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't delete the source", message: error.localizedDescription)
        }
    }

    func toggleSourceInRetrieval(_ source: Source) {
        guard let store else { return }
        var copy = source
        copy.includeInRetrieval.toggle()
        try? store.upsert(source: copy)
        reloadNotebookContent()
    }

    func refreshSource(_ source: Source) {
        guard let url = source.url else { return }
        addSources(.website(url: url, title: source.title))
    }

    /// Rebuilds chunks and vectors, used after retrieval settings change.
    func reindexSource(_ id: RecordID) {
        guard let service = ingestionService() else { return }
        Task {
            ingestion = IngestionProgress(title: "Re-indexing", stage: "Chunking", overall: 0.2, itemIndex: 1, itemCount: 1)
            let result = await service.reindex(sourceID: id) { progress in
                Task { @MainActor in
                    self.ingestion = IngestionProgress(title: progress.title, stage: progress.stage.displayName,
                                                       overall: progress.overall, itemIndex: 1, itemCount: 1)
                }
            }
            ingestion = nil
            reloadNotebookContent()
            if let error = result.error {
                lastError = PresentedError(error)
            } else {
                statusMessage = "Re-indexed “\(result.source.title)” · \(result.chunkCount) passages"
            }
        }
    }

    func sourceText(for source: Source) -> String {
        guard let contentPath = source.contentPath else { return "" }
        return (try? FileStore.readText(at: URL(fileURLWithPath: contentPath))) ?? ""
    }

    func chunks(for sourceID: RecordID) -> [SourceChunk] {
        (try? store?.chunks(sourceID: sourceID)) ?? []
    }

    func deleteAllSources() {
        guard let store, let id = selectedNotebookID else { return }
        let ids = sources.map(\.id)
        do {
            try store.deleteSources(ids: ids)
            selectedSourceID = nil
            reloadNotebookContent()
            statusMessage = "Removed \(ids.count) sources from “\(selectedNotebook?.title ?? "notebook")”"
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't remove the sources", message: error.localizedDescription)
        }
    }

    // MARK: Models

    func loadModels(for providerID: String, force: Bool = false) async {
        guard let provider = providers.provider(id: providerID) else { return }
        if !force, probedProviders.contains(providerID), availableModels[providerID] != nil { return }
        probedProviders.insert(providerID)

        let availability = await provider.availability()
        modelDiscoveryState[providerID] = availability

        // The model list and the *right to use* a provider are separate questions, and
        // conflating them made the picker useless: Ollama's hosted catalogue can be
        // listed without a key, and Anthropic's model names are static, so both showed
        // an empty section that looked like a broken provider. List whatever can be
        // listed; the availability state is what stops the user actually running a
        // model, and it is displayed alongside.
        do {
            let models = try await provider.availableModels()
            availableModels[providerID] = models
            // Adopt a sensible default model for a provider the user has just chosen, but
            // only when it could actually answer — otherwise choosing a provider without
            // a key would silently rewrite the user's model choice.
            if availability.isReady,
               settings.model(for: providerID).isEmpty,
               let first = models.first(where: { !$0.supportsEmbeddings }) ?? models.first {
                settings.modelSelection[providerID] = first.name
                saveSettings()
            }
        } catch let error as SourceDeskError {
            // A provider that cannot even be listed keeps its availability state, which
            // already explains why; recording unreachable here would overwrite a more
            // useful "no API key is stored" with a network-sounding message.
            if availability.isReady {
                modelDiscoveryState[providerID] = .unreachable(reason: error.errorDescription ?? "")
            }
            availableModels[providerID] = []
        } catch {
            if availability.isReady {
                modelDiscoveryState[providerID] = .unreachable(reason: error.localizedDescription)
            }
            availableModels[providerID] = []
        }
    }

    /// The picker section for one provider, built by the core policy so the rules live
    /// in one place and can be tested without a UI.
    func menuSection(for provider: AIProvider) -> ModelMenuPolicy.Section {
        ModelMenuPolicy.section(
            providerID: provider.identifier,
            displayName: provider.displayName,
            models: availableModels[provider.identifier] ?? [],
            availability: modelDiscoveryState[provider.identifier],
            hasBeenProbed: probedProviders.contains(provider.identifier)
        )
    }

    func refreshAllModels() async {
        for provider in providers.all {
            await loadModels(for: provider.identifier, force: true)
        }
    }

    var currentProvider: AIProvider? {
        providers.provider(id: settings.preferredProviderID)
    }

    var currentModelName: String { settings.model(for: settings.preferredProviderID) }

    /// A short, honest description of what the selected model means for privacy and
    /// capability, shown above the composer.
    var modelStatusLine: String {
        guard let provider = currentProvider else { return "No provider selected" }
        let model = currentModelName.isEmpty ? "no model selected" : currentModelName
        if provider.isLocal {
            return "\(provider.displayName) · \(model) — runs on this Mac"
        }
        return "\(provider.displayName) · \(model) — cloud, sources you send leave this Mac"
    }

    // MARK: Settings

    func saveSettings() {
        do {
            try settingsStore?.save(settings)
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't save settings", message: error.localizedDescription)
        }
        applySettingsSideEffects()
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var previous = settings
        mutate(&settings)
        do {
            try settingsStore?.save(settings)
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't save settings", message: error.localizedDescription)
        }
        if SettingsStore.requiresReindex(from: previous, to: settings) {
            statusMessage = "Chunking or embedding settings changed — re-index a source to apply them."
        }
        applySettingsSideEffects()
    }

    private func applySettingsSideEffects() {
        providers = makeProviders()
        DiagnosticsLog.shared.configure(level: settings.logLevel, directory: paths.logsRoot)
        // Changing the storage location is not applied live: the user is told to
        // restart, which avoids a half-migrated library.
    }

    func approveCloudConsent(for notebookID: RecordID) {
        updateSettings { $0.approveCloud(for: notebookID) }
        cloudConsentPromptNotebookID = nil
        statusMessage = "Cloud sending approved for this notebook"
    }

    func revokeCloudConsent(for notebookID: RecordID) {
        updateSettings { $0.revokeCloud(for: notebookID) }
        statusMessage = "Cloud sending revoked for this notebook"
    }

    // MARK: Notes

    func saveNote(_ note: NotebookNote) {
        guard let store else { return }
        do {
            try store.upsert(note: note)
            reloadNotebookContent()
            selectedNoteID = note.id
        } catch let error as SourceDeskError {
            lastError = PresentedError(error)
        } catch {
            lastError = PresentedError(title: "Couldn't save the note", message: error.localizedDescription)
        }
    }

    func deleteNote(_ id: RecordID) {
        guard let store else { return }
        try? store.deleteNote(id: id)
        if selectedNoteID == id { selectedNoteID = nil }
        reloadNotebookContent()
    }

    func createNote(title: String = "New note") -> NotebookNote? {
        guard let id = selectedNotebookID else { return nil }
        let note = NotebookNote(notebookID: id, title: title, kind: .manual)
        saveNote(note)
        return note
    }

    // MARK: Sessions

    func createSession() -> ChatSession? {
        guard let store, let notebookID = selectedNotebookID else { return nil }
        let session = ChatSession(
            notebookID: notebookID,
            scope: selectedNotebook?.defaultScope ?? settings.defaultAnswerScope,
            providerID: settings.preferredProviderID,
            modelName: currentModelName
        )
        do {
            let saved = try store.upsert(session: session)
            reloadNotebookContent()
            selectedSessionID = saved.id
            activeCitations = []
            activeTrace = nil
            return saved
        } catch {
            lastError = PresentedError(title: "Couldn't start a session", message: error.localizedDescription)
            return nil
        }
    }

    func deleteSession(_ id: RecordID) {
        guard let store else { return }
        try? store.deleteSession(id: id)
        if selectedSessionID == id { selectedSessionID = nil }
        activeCitations = []
        activeTrace = nil
        reloadNotebookContent()
    }

    func messages(for sessionID: RecordID) -> [ChatMessage] {
        (try? store?.messages(sessionID: sessionID)) ?? []
    }

    func renameSession(_ session: ChatSession, to title: String) {
        guard let store else { return }
        var copy = session
        copy.title = title
        try? store.upsert(session: copy)
        reloadNotebookContent()
    }

    func setSessionScope(_ session: ChatSession, scope: AnswerScope) {
        guard let store else { return }
        var copy = session
        copy.scope = scope
        try? store.upsert(session: copy)
        reloadNotebookContent()
    }

    // MARK: Notes on screen

    var selectedNote: NotebookNote? {
        notes.first { $0.id == selectedNoteID }
    }

    // MARK: Diagnostics

    func libraryStats() -> StoreStats {
        (try? store?.stats()) ?? StoreStats()
    }

    func refreshStats() -> StoreStats {
        let stats = libraryStats()
        return stats
    }

    func optimizeLibrary() {
        do {
            try store?.optimize()
            statusMessage = "Library optimised"
        } catch {
            lastError = PresentedError(title: "Couldn't optimise the library", message: error.localizedDescription)
        }
    }

    func clearCache() {
        let removed = (try? store?.clearCache()) ?? 0
        statusMessage = "Cleared \(ByteCountFormatter.string(fromByteCount: removed, countStyle: .file)) of cache"
    }
}
