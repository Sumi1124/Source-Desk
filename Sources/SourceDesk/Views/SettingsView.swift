import SwiftUI
import SourceDeskCore

/// Settings, organised around the decisions a user actually makes: which model
/// answers, whether the web is used, where data lives, what may leave the Mac, how
/// retrieval behaves, and what the app looks like.
@MainActor
struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        TabView {
            ProvidersSettings()
                .tabItem { Label("AI Providers", systemImage: "cpu") }
            SearchSettings()
                .tabItem { Label("Search", systemImage: "globe") }
            RetrievalSettings()
                .tabItem { Label("Retrieval", systemImage: "square.stack.3d.up") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 780, height: 620)
    }
}

/// A consistent settings pane wrapper: a scrolling form with a title and a
/// description, so every pane explains itself before showing controls.
@MainActor
struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.spacingLarge) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(Design.spacingLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Providers

@MainActor
struct ProvidersSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        SettingsPane(
            title: "AI Providers",
            subtitle: "SourceDesk is local-first: a model on this Mac answers by default. Cloud providers are optional and are only used when you select them."
        ) {
            // Local-first ordering is deliberate.
            ForEach(app.providers.all, id: \.identifier) { provider in
                ProviderCard(provider: provider)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Local server")
                LabelledField(
                    label: "Ollama endpoint",
                    help: "Where SourceDesk looks for a local model server. Ollama is detected automatically; SourceDesk never installs or downloads models for you."
                ) {
                    HStack {
                        TextField("http://127.0.0.1:11434", text: Binding(
                            get: { app.settings.ollamaEndpoint },
                            set: { value in app.updateSettings { $0.ollamaEndpoint = value } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Test Connection") {
                            Task { await app.loadModels(for: "ollama", force: true) }
                        }
                    }
                }
                if let state = app.modelDiscoveryState["ollama"], !state.isReady {
                    Text(state.reason ?? "")
                        .font(Design.caption)
                        .foregroundStyle(.orange)
                }

                LabelledField(
                    label: "Ollama Cloud endpoint",
                    help: "Ollama's hosted API serves the same routes at a remote host, for models too large to run on this Mac. Point this at any other remote Ollama host if you prefer. Requires an API key; content sent here leaves this Mac."
                ) {
                    HStack {
                        TextField("https://ollama.com", text: Binding(
                            get: { app.settings.ollamaCloudEndpoint },
                            set: { value in app.updateSettings { $0.ollamaCloudEndpoint = value } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Test Connection") {
                            Task { await app.loadModels(for: "ollama-cloud", force: true) }
                        }
                    }
                }
                if let state = app.modelDiscoveryState["ollama-cloud"], !state.isReady {
                    Text(state.reason ?? "")
                        .font(Design.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Generation")
                LabelledField(label: "Temperature", help: "Lower is more literal and better grounded in sources. 0.2 is a good default for research.") {
                    HStack {
                        Slider(value: Binding(
                            get: { app.settings.temperature },
                            set: { value in app.updateSettings { $0.temperature = value } }
                        ), in: 0...1, step: 0.05)
                        Text(String(format: "%.2f", app.settings.temperature))
                            .font(Design.monoCaption)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabelledField(label: "Maximum answer tokens", help: "Caps how long a single answer can be. 2,048 is roughly 1,500 words.") {
                    Stepper(value: Binding(
                        get: { app.settings.maxResponseTokens },
                        set: { value in app.updateSettings { $0.maxResponseTokens = value } }
                    ), in: 256...32_768, step: 256) {
                        Text("\(Format.count(app.settings.maxResponseTokens)) tokens")
                            .font(Design.caption)
                    }
                }
            }
        }
    }
}

/// One provider's configuration, with an honest statement of what it can and cannot do.
@MainActor
struct ProviderCard: View {
    @Environment(AppState.self) private var app
    let provider: AIProvider

    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var revealKeyField = false

    private var keychainKey: KeychainService.Key? {
        switch provider.identifier {
        case "openai": return .openAIAPIKey
        case "anthropic": return .anthropicAPIKey
        case "ollama-cloud": return .ollamaAPIKey
        default: return nil
        }
    }

    /// Whether this provider needs a credential, which is exactly when it has a
    /// keychain entry.
    private var requiresKey: Bool { keychainKey != nil }

    /// A clearer privacy line than a bare local/cloud switch.
    private var privacyLine: String {
        if let ollama = provider as? OllamaProvider, ollama.isCloud {
            return "Runs Ollama's hosted models on ollama.com"
        }
        return provider.isLocal ? "Runs on this Mac" : "Sends retrieved passages to a cloud service"
    }

    private var isSelected: Bool { app.settings.preferredProviderID == provider.identifier }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            HStack(spacing: Design.spacingSmall) {
                Image(systemName: provider.isLocal ? "desktopcomputer" : "cloud")
                    .font(.system(size: 13))
                    .foregroundStyle(provider.isLocal ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(privacyLine)
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    StatusPill(text: "in use", color: .accentColor, symbol: "checkmark.circle.fill")
                } else {
                    Button("Use This Provider") {
                        app.updateSettings { $0.preferredProviderID = provider.identifier }
                        Task { await app.loadModels(for: provider.identifier, force: true) }
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: Design.spacingSmall) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                Text(stateText)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") {
                    Task { await app.loadModels(for: provider.identifier, force: true) }
                }
                .controlSize(.small)
            }

            if let hint = provider.configurationHint {
                Text(hint)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // API key entry, for cloud providers only. The key goes to the Keychain.
            if let keychainKey {
                HStack(spacing: Design.spacingSmall) {
                    if let hint = KeychainService().maskedHint(for: keychainKey) {
                        StatusPill(text: "key saved \(hint)", color: .green, symbol: "checkmark.shield.fill")
                        Button("Remove Key") {
                            KeychainService().delete(keychainKey)
                            keySaved = false
                            Task { await app.loadModels(for: provider.identifier, force: true) }
                        }
                        .controlSize(.small)
                    } else {
                        if revealKeyField {
                            SecureField("Paste API key", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                                .onSubmit { saveKey(keychainKey) }
                            Button("Save Key") { saveKey(keychainKey) }
                                .controlSize(.small)
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        } else {
                            Button("Add API Key…") { revealKeyField = true }
                                .controlSize(.small)
                        }
                    }
                }
                Text("Keys are stored in the macOS Keychain, never in a notebook, a settings file or an export.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Models for this provider.
            let models = app.availableModels[provider.identifier] ?? []
            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models").font(.system(size: 11, weight: .medium))
                    ForEach(models.filter { !$0.supportsEmbeddings }) { model in
                        HStack(spacing: Design.spacingSmall) {
                            Image(systemName: app.settings.model(for: provider.identifier) == model.name ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.name).font(.system(size: 11, weight: .medium))
                                Text(model.detailLine).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let note = model.capabilityNote {
                                Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            app.updateSettings {
                                $0.preferredProviderID = provider.identifier
                                $0.modelSelection[provider.identifier] = model.name
                            }
                        }
                    }
                    let embeddingModels = models.filter(\.supportsEmbeddings)
                    if !embeddingModels.isEmpty {
                        Text("Embedding models: \(embeddingModels.map(\.name).joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(Design.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .task { await app.loadModels(for: provider.identifier) }
    }

    private var stateColor: Color {
        switch app.modelDiscoveryState[provider.identifier] {
        case .ready: return .green
        case .notConfigured: return .secondary
        case .unreachable, .unavailable: return .orange
        case nil: return .secondary
        }
    }

    private var stateText: String {
        switch app.modelDiscoveryState[provider.identifier] {
        case .ready: return "Ready — \((app.availableModels[provider.identifier] ?? []).count) model(s) available"
        case .notConfigured(let reason): return reason
        case .unreachable(let reason): return reason
        case .unavailable(let reason): return reason
        case nil: return "Not checked yet"
        }
    }

    private func saveKey(_ key: KeychainService.Key) {
        if KeychainService().store(keyDraft, for: key) {
            keyDraft = ""
            keySaved = true
            revealKeyField = false
            app.statusMessage = "\(provider.displayName) key saved to the Keychain"
            Task { await app.loadModels(for: provider.identifier, force: true) }
        } else {
            app.lastError = AppState.PresentedError(
                title: "Couldn't save the key",
                message: "The macOS Keychain refused to store the credential.",
                recovery: "Unlock the login keychain in Keychain Access, then try again."
            )
        }
    }
}

// MARK: - Search

@MainActor
struct SearchSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SettingsPane(
            title: "Search",
            subtitle: "Web search is optional. When it is on, the queries you make are sent to the provider you choose here."
        ) {
            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Search provider")
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    HStack(alignment: .top, spacing: Design.spacingSmall) {
                        Image(systemName: app.settings.searchEngine == engine ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(app.settings.searchEngine == engine ? Color.accentColor : .secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(engine.displayName).font(.system(size: 12, weight: .medium))
                                if engine.requiresKey {
                                    StatusPill(text: "API key", color: .orange, symbol: "key")
                                }
                            }
                            Text(engine.detail)
                                .font(Design.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { app.updateSettings { $0.searchEngine = engine } }
                }
            }

            if app.settings.searchEngine == .brave {
                SearchKeyField(key: .braveSearchAPIKey, label: "Brave Search API key",
                               help: "Create a key at brave.com/search/api. The free tier is enough for personal research.")
            }
            if app.settings.searchEngine == .tavily {
                SearchKeyField(key: .tavilySearchAPIKey, label: "Tavily API key",
                               help: "Create a key at tavily.com. Tavily returns page content with each result, so answers need fewer extra fetches.")
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Behaviour")
                LabelledField(label: "Results per search", help: "How many web results to retrieve for a question.") {
                    Stepper(value: Binding(
                        get: { app.settings.searchResultCount },
                        set: { value in app.updateSettings { $0.searchResultCount = value } }
                    ), in: 2...20) {
                        Text("\(app.settings.searchResultCount)")
                            .font(Design.caption)
                    }
                }
                Toggle("Fetch full page text for search results", isOn: Binding(
                    get: { app.settings.enrichWebResults },
                    set: { value in app.updateSettings { $0.enrichWebResults = value } }
                ))
                Text("When on, SourceDesk reads the top results so answers use real page text rather than a snippet. robots.txt is respected.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Default answer scope")
                Picker("", selection: Binding(
                    get: { app.settings.defaultAnswerScope },
                    set: { value in app.updateSettings { $0.defaultAnswerScope = value } }
                )) {
                    ForEach(AnswerScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(app.settings.defaultAnswerScope.explanation)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
struct SearchKeyField: View {
    @Environment(AppState.self) private var app
    let key: KeychainService.Key
    let label: String
    let help: String

    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        LabelledField(label: label, help: help) {
            HStack(spacing: Design.spacingSmall) {
                if let hint = KeychainService().maskedHint(for: key) {
                    StatusPill(text: "saved \(hint)", color: .green, symbol: "checkmark.shield.fill")
                    Button("Remove") {
                        KeychainService().delete(key)
                        app.statusMessage = "\(label) removed"
                    }
                    .controlSize(.small)
                } else if editing {
                    SecureField("Paste key", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Button("Save") {
                        _ = KeychainService().store(draft, for: key)
                        draft = ""
                        editing = false
                        app.statusMessage = "\(label) saved to the Keychain"
                    }
                    .controlSize(.small)
                } else {
                    Button("Add \(label)…") { editing = true }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Retrieval

@MainActor
struct RetrievalSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SettingsPane(
            title: "Retrieval",
            subtitle: "How SourceDesk finds the passages it sends to the model. These settings trade recall against speed and cost, and can be changed later — sources can be re-indexed at any time."
        ) {
            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Passages")
                LabelledField(label: "Passages in the answer", help: "How many retrieved passages are offered to the model. More improves recall but costs context.") {
                    Stepper(value: Binding(
                        get: { app.settings.retrievalResultCount },
                        set: { value in app.updateSettings { $0.retrievalResultCount = value } }
                    ), in: 1...40) {
                        Text(Format.count(app.settings.retrievalResultCount, "passage")).font(Design.caption)
                    }
                }
                LabelledField(label: "Candidates considered", help: "How many passages each retriever pulls before fusion and reranking.") {
                    Stepper(value: Binding(
                        get: { app.settings.retrievalCandidateCount },
                        set: { value in app.updateSettings { $0.retrievalCandidateCount = value } }
                    ), in: 5...400, step: 5) {
                        Text("\(app.settings.retrievalCandidateCount) candidates").font(Design.caption)
                    }
                }
                LabelledField(label: "Passages per source", help: "Caps how much of the answer can come from one document, so a long report cannot bury a short memo.") {
                    Stepper(value: Binding(
                        get: { app.settings.maxChunksPerSource },
                        set: { value in app.updateSettings { $0.maxChunksPerSource = value } }
                    ), in: 1...20) {
                        Text("\(app.settings.maxChunksPerSource) per source").font(Design.caption)
                    }
                }
                LabelledField(label: "Context budget", help: "Maximum tokens of source material in one prompt. Keep this inside your model's context window.") {
                    Stepper(value: Binding(
                        get: { app.settings.contextTokenBudget },
                        set: { value in app.updateSettings { $0.contextTokenBudget = value } }
                    ), in: 500...100_000, step: 500) {
                        Text("\(Format.count(app.settings.contextTokenBudget)) tokens").font(Design.caption)
                    }
                }
                LabelledField(label: "Minimum score", help: "Passages scoring below this are dropped rather than padding the answer with irrelevant material.") {
                    HStack {
                        Slider(value: Binding(
                            get: { app.settings.minimumRelevanceScore },
                            set: { value in app.updateSettings { $0.minimumRelevanceScore = value } }
                        ), in: 0...0.6, step: 0.01)
                        Text(String(format: "%.2f", app.settings.minimumRelevanceScore))
                            .font(Design.monoCaption)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Search methods")
                Toggle("Semantic search (embeddings)", isOn: Binding(
                    get: { app.settings.semanticSearchEnabled },
                    set: { value in app.updateSettings { $0.semanticSearchEnabled = value } }
                ))
                Toggle("Keyword search (full-text index)", isOn: Binding(
                    get: { app.settings.keywordSearchEnabled },
                    set: { value in app.updateSettings { $0.keywordSearchEnabled = value } }
                ))
                Text("Hybrid retrieval runs both and merges the rankings, so losing one method degrades recall rather than breaking search.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Embeddings")
                Picker("", selection: Binding(
                    get: { app.settings.embeddingChoice },
                    set: { value in app.updateSettings { $0.embeddingChoice = value } }
                )) {
                    ForEach(EmbeddingChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(app.settings.embeddingChoice.explanation)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if app.settings.embeddingChoice == .ollama {
                    LabelledField(label: "Embedding model", help: "Any embedding model your Ollama install has pulled, for example nomic-embed-text or mxbai-embed-large.") {
                        TextField("nomic-embed-text", text: Binding(
                            get: { app.settings.ollamaEmbeddingModel },
                            set: { value in app.updateSettings { $0.ollamaEmbeddingModel = value } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    }
                }
                Button("Re-index All Sources in This Notebook") {
                    for source in app.sources {
                        app.reindexSource(source.id)
                    }
                }
                .controlSize(.small)
                .disabled(app.sources.isEmpty)
                Text("Changing the embedding model, chunk size or overlap requires re-indexing for the new settings to take effect. Sources keep working either way.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Ranking")
                Picker("", selection: Binding(
                    get: { app.settings.rerankStrategy },
                    set: { value in app.updateSettings { $0.rerankStrategy = value } }
                )) {
                    ForEach(RerankStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(app.settings.rerankStrategy.explanation)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Chunking")
                LabelledField(label: "Chunk size", help: "Target size of each passage. Smaller passages retrieve precisely; larger ones read better.") {
                    Stepper(value: Binding(
                        get: { app.settings.chunkTargetTokens },
                        set: { value in app.updateSettings { $0.chunkTargetTokens = value } }
                    ), in: 64...2_000, step: 32) {
                        Text("\(app.settings.chunkTargetTokens) tokens").font(Design.caption)
                    }
                }
                LabelledField(label: "Overlap", help: "Text repeated between adjacent passages so a sentence split across the boundary is still found.") {
                    Stepper(value: Binding(
                        get: { app.settings.chunkOverlapTokens },
                        set: { value in app.updateSettings { $0.chunkOverlapTokens = value } }
                    ), in: 0...400, step: 10) {
                        Text("\(app.settings.chunkOverlapTokens) tokens").font(Design.caption)
                    }
                }
                Toggle("Prefix passages with their heading", isOn: Binding(
                    get: { app.settings.includeHeadingContextInChunks },
                    set: { value in app.updateSettings { $0.includeHeadingContextInChunks = value } }
                ))
            }
        }
    }
}

// MARK: - Storage

@MainActor
struct StorageSettings: View {
    @Environment(AppState.self) private var app
    @State private var stats = StoreStats()
    @State private var integrity = ""

    var body: some View {
        SettingsPane(
            title: "Storage",
            subtitle: "Everything SourceDesk stores lives in one folder on this Mac. Point it at another disk to move your library; the contents are portable."
        ) {
            locationSection
            databaseSection
            cacheSection
            limitsSection
        }
        .onAppear { refresh() }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            SectionHeader("Location")
            HStack {
                Text(app.paths.displayPath(app.paths.root))
                    .font(Design.monoCaption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.paths.root])
                }
                .controlSize(.small)
            }
            Text("To move your library, quit SourceDesk, move the folder, then set the new path here and relaunch.")
                .font(Design.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var databaseSection: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            SectionHeader("Database")
            DetailRow(label: "Notebooks", value: Format.count(stats.notebookCount))
            DetailRow(label: "Sources", value: Format.count(stats.sourceCount))
            DetailRow(label: "Passages", value: Format.count(stats.chunkCount))
            DetailRow(label: "Vectors", value: Format.count(stats.embeddingCount))
            DetailRow(label: "Messages", value: Format.count(stats.messageCount))
            DetailRow(label: "Notes", value: Format.count(stats.noteCount))
            DetailRow(label: "Stored text", value: Format.bytes(stats.contentBytes))
            DetailRow(label: "Database size", value: Format.bytes(stats.databaseBytes))
            if !stats.embeddingModels.isEmpty {
                DetailRow(label: "Embedding models", value: stats.embeddingModels.joined(separator: ", "))
            }
            databaseButtons
            if !integrity.isEmpty {
                DetailRow(label: "Integrity", value: integrity, tint: integrity == "ok" ? .green : .orange)
            }
        }
    }

    private var databaseButtons: some View {
        HStack(spacing: Design.spacingSmall) {
            Button("Refresh") { refresh() }
                .controlSize(.small)
            Button("Run Integrity Check") {
                integrity = (try? app.store?.db.integrityCheck()) ?? "unavailable"
                app.statusMessage = "Integrity check: \(integrity)"
            }
            .controlSize(.small)
            Button("Optimise Database") { app.optimizeLibrary() }
                .controlSize(.small)
        }
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            SectionHeader("Cache")
            Text("Downloaded pages and intermediate files are cached so imports are not repeated. Clearing the cache never touches sources, notes or conversations.")
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear Cache") { app.clearCache() }
                    .controlSize(.small)
                Spacer()
                Text(Format.bytes(FileStore.totalSize(of: app.paths.cacheRoot)))
                    .font(Design.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            SectionHeader("Limits")
            importLimitField
            pageLimitField
        }
    }

    private var importLimitField: some View {
        LabelledField(
            label: "Maximum import size",
            help: "Files larger than this are refused with an explanation rather than silently truncated. There is no product limit on how many sources you add."
        ) {
            Stepper(value: importSizeBinding, in: 10 * 1024 * 1024...(4 * 1024 * 1024 * 1024), step: 64 * 1024 * 1024) {
                Text(Format.bytes(app.settings.maximumImportBytes)).font(Design.caption)
            }
        }
    }

    private var pageLimitField: some View {
        LabelledField(
            label: "Maximum page size",
            help: "Web pages larger than this are refused, so a single enormous page cannot fill your disk."
        ) {
            Stepper(value: pageSizeBinding, in: 1024 * 1024...(200 * 1024 * 1024), step: 1024 * 1024) {
                Text(Format.bytes(app.settings.maximumPageBytes)).font(Design.caption)
            }
        }
    }

    private var importSizeBinding: Binding<Int64> {
        Binding(
            get: { app.settings.maximumImportBytes },
            set: { value in app.updateSettings { $0.maximumImportBytes = value } }
        )
    }

    private var pageSizeBinding: Binding<Int64> {
        Binding(
            get: { app.settings.maximumPageBytes },
            set: { value in app.updateSettings { $0.maximumPageBytes = value } }
        )
    }

    private func refresh() {
        stats = app.libraryStats()
    }
}

// MARK: - Privacy

@MainActor
struct PrivacySettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SettingsPane(
            title: "Privacy",
            subtitle: "SourceDesk is built so that nothing leaves your Mac unless you choose a feature that requires it. These controls make that guarantee explicit."
        ) {
            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Local-only mode")
                Toggle("Never send source content to a cloud provider", isOn: Binding(
                    get: { app.settings.localOnlyMode },
                    set: { value in app.updateSettings { $0.localOnlyMode = value } }
                ))
                Text("While this is on, cloud providers are unavailable and SourceDesk says so rather than quietly falling back. Local models, local search and every study tool keep working.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Cloud confirmation")
                Toggle("Ask before sending source content to a cloud provider", isOn: Binding(
                    get: { app.settings.confirmBeforeCloudSend },
                    set: { value in app.updateSettings { $0.confirmBeforeCloudSend = value } }
                ))
                Text("Approval is granted per notebook, so one click cannot expose an entire library.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)

                if app.settings.confirmBeforeCloudSend, !app.settings.cloudApprovedNotebooks.isEmpty {
                    SectionHeader("Notebooks approved for cloud use")
                    ForEach(app.settings.cloudApprovedNotebooks, id: \.self) { id in
                        HStack {
                            Image(systemName: "cloud")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(app.notebooks.first { $0.id == id }?.title ?? "Deleted notebook")
                                .font(Design.caption)
                            Spacer()
                            Button("Revoke") { app.revokeCloudConsent(for: id) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Web fetching")
                Toggle("Respect robots.txt when downloading pages", isOn: Binding(
                    get: { app.settings.respectRobotsTxt },
                    set: { value in app.updateSettings { $0.respectRobotsTxt = value } }
                ))
                Text("On by default. SourceDesk never attempts to bypass a sign-in, a paywall or an access control — it reports the problem and suggests importing the content another way.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Keep a copy of original downloaded files", isOn: Binding(
                    get: { app.settings.storeOriginalDownloads },
                    set: { value in app.updateSettings { $0.storeOriginalDownloads = value } }
                ))
                Text("Keeping the original means a source survives the file being moved or deleted, and can be re-extracted without re-downloading.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("What leaves this Mac")
                privacyRow(.local, "Notebooks, sources, passages, vectors, notes, conversations, settings",
                           "Stored in \(app.paths.displayPath(app.paths.root))")
                privacyRow(.cloud, "Retrieved passages and your question",
                           app.currentProvider?.isLocal == true
                           ? "Nothing — the selected model runs on this Mac."
                           : "Sent to \(app.currentProvider?.displayName ?? "the selected provider") when you ask a question with a cloud model selected.")
                privacyRow(.web, "Your search query",
                           app.settings.searchEngine == .none
                           ? "Nothing — web search is off."
                           : "Sent to \(app.settings.searchEngine.displayName) when web search is enabled for a question.")
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Credentials")
                Text("API keys are stored in the macOS Keychain, scoped to this app. They are never written to the notebook database, a settings file, a log, or an exported notebook. Removing a key here deletes it from the Keychain.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Design.spacingSmall) {
                    ForEach(KeychainService.Key.allCases, id: \.self) { key in
                        StatusPill(text: key.providerName,
                                   color: KeychainService().hasSecret(for: key) ? .green : .secondary,
                                   symbol: KeychainService().hasSecret(for: key) ? "checkmark.shield.fill" : "shield.slash")
                    }
                }
            }
        }
    }

    private func privacyRow(_ level: PrivacyLevel, _ what: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Image(systemName: level == .local ? "lock.fill" : (level == .cloud ? "arrow.up.right.circle.fill" : "globe"))
                .font(.system(size: 11))
                .foregroundStyle(Design.privacyColor(level))
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(level.rawValue.capitalized): \(what)")
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: - Appearance

@MainActor
struct AppearanceSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SettingsPane(
            title: "Appearance",
            subtitle: "SourceDesk follows macOS conventions. These are the few places the interface adapts to how you read."
        ) {
            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Theme")
                Picker("", selection: Binding(
                    get: { app.settings.appearance },
                    set: { value in app.updateSettings { $0.appearance = value } }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Layout")
                Toggle("Show the inspector panel", isOn: Binding(
                    get: { app.settings.showInspector },
                    set: { value in app.updateSettings { $0.showInspector = value } }
                ))
                Text("The inspector shows the selected source, the citations behind the current answer, and note provenance.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Reading")
                LabelledField(label: "Answer text size", help: "Applies to answers and notes.") {
                    HStack {
                        Slider(value: Binding(
                            get: { app.settings.chatFontSize },
                            set: { value in app.updateSettings { $0.chatFontSize = value } }
                        ), in: 11...18, step: 1)
                        Text("\(Int(app.settings.chatFontSize)) pt")
                            .font(Design.monoCaption)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Show word and passage counts in the source list", isOn: Binding(
                    get: { app.settings.showSourceWordCounts },
                    set: { value in app.updateSettings { $0.showSourceWordCounts = value } }
                ))
            }
        }
    }
}

// MARK: - Advanced

@MainActor
struct AdvancedSettings: View {
    @Environment(AppState.self) private var app
    @State private var logLines: [String] = []

    var body: some View {
        SettingsPane(
            title: "Advanced",
            subtitle: "Fine-grained control for large libraries, unusual hardware, or self-hosted providers. The defaults work for most research notes."
        ) {
            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Self-hosted or compatible providers")
                LabelledField(label: "OpenAI-compatible base URL",
                             help: "Point OpenAI support at any gateway implementing /v1/chat/completions — a proxy, a self-hosted server, or another vendor's compatible endpoint. Leave empty for the official API.") {
                    TextField("https://api.openai.com/v1", text: Binding(
                        get: { app.settings.openAIBaseURLOverride },
                        set: { value in app.updateSettings { $0.openAIBaseURLOverride = value } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                }
                LabelledField(label: "Anthropic base URL", help: "For a compliant gateway in front of the Messages API.") {
                    TextField("https://api.anthropic.com/v1", text: Binding(
                        get: { app.settings.anthropicBaseURL },
                        set: { value in app.updateSettings { $0.anthropicBaseURL = value } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                }
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Performance")
                LabelledField(label: "Concurrent imports", help: "How many sources are processed at once. Lower this on a Mac with little memory.") {
                    Stepper(value: Binding(
                        get: { app.settings.maximumConcurrentIngestions },
                        set: { value in app.updateSettings { $0.maximumConcurrentIngestions = value } }
                    ), in: 1...8) {
                        Text("\(app.settings.maximumConcurrentIngestions)").font(Design.caption)
                    }
                }
                LabelledField(label: "Request timeout", help: "Applies to provider calls and page downloads. Local models on a large context legitimately take minutes.") {
                    Stepper(value: Binding(
                        get: { app.settings.requestTimeoutSeconds },
                        set: { value in app.updateSettings { $0.requestTimeoutSeconds = value } }
                    ), in: 10...900, step: 10) {
                        Text("\(Int(app.settings.requestTimeoutSeconds)) s").font(Design.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("System prompt")
                Text("Replaces SourceDesk's own grounding instructions. Leave empty for the default, which requires answers to cite retrieved material and to say when it cannot.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: Binding(
                    get: { app.settings.systemPromptOverride },
                    set: { value in app.updateSettings { $0.systemPromptOverride = value } }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 110)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                HStack {
                    Text("Preview of the default instructions")
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Default") {
                        logLines = PromptBuilder.researchSystemPrompt(PromptBuilder.Grounding(
                            notebookAvailable: true, webAvailable: true, sourceCount: 1,
                            scope: .notebookAndWeb, cloudProviderName: nil
                        )).components(separatedBy: .newlines)
                    }
                    .controlSize(.small)
                }
                if !logLines.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Diagnostics")
                Picker("", selection: Binding(
                    get: { app.settings.logLevel },
                    set: { value in app.updateSettings { $0.logLevel = value } }
                )) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Text("Logs stay on this Mac in \(app.paths.displayPath(app.paths.logsRoot)). Nothing is transmitted anywhere.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: Design.spacingSmall) {
                    Button("Show Recent Log") {
                        logLines = DiagnosticsLog.shared.recentLines(limit: 200)
                    }
                    Button("Reveal Log Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.paths.logsRoot])
                    }
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Reset")
                HStack(spacing: Design.spacingSmall) {
                    Button("Reset All Settings to Defaults") {
                        app.updateSettings { current in current = AppSettings() }
                        app.statusMessage = "Settings reset to defaults"
                    }
                    Button("Re-Index Every Source in This Notebook") {
                        for source in app.sources { app.reindexSource(source.id) }
                    }
                    .disabled(app.sources.isEmpty)
                }
                .controlSize(.small)
                Text("Resetting settings never touches notebooks, sources, notes or conversations.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

@MainActor
struct AboutSettings: View {
    @Environment(AppState.self) private var app
    @State private var stats = StoreStats()

    var body: some View {
        SettingsPane(
            title: "About SourceDesk",
            subtitle: AppInfo.tagline
        ) {
            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                DetailRow(label: "Version", value: AppInfo.version)
                DetailRow(label: "Platform", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                DetailRow(label: "Library", value: app.paths.displayPath(app.paths.root), monospaced: true)
                DetailRow(label: "Notebooks", value: Format.count(stats.notebookCount))
                DetailRow(label: "Sources", value: Format.count(stats.sourceCount))
                DetailRow(label: "Passages", value: Format.count(stats.chunkCount))
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("How answers stay grounded")
                Text("""
                SourceDesk retrieves passages from your own sources, labels them, and instructs the model to cite them with markers like [Source 1]. After generation every marker is checked against what was actually retrieved: a citation that does not resolve to a real passage is removed from the answer rather than shown.
                """)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("Dependencies")
                Text("No third-party packages. SourceDesk uses only Apple frameworks — SwiftUI, AppKit, PDFKit, Network — plus SQLite and zlib, which ship with macOS.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                SectionHeader("License")
                Text("MIT. SourceDesk is an independent project; it is not affiliated with, and contains no assets or code from, Google NotebookLM or any other product.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { stats = app.libraryStats() }
    }
}
