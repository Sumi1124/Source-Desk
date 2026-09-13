import SwiftUI
import SourceDeskCore
import UniformTypeIdentifiers

/// The three-column shell: sidebar, working area, inspector.
@MainActor
struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(ChatViewModel.self) private var chat

    @State private var addWebsiteVisible = false
    @State private var addPastedTextVisible = false
    @State private var exportVisible = false
    @State private var importVisible = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                onAddWebsite: { addWebsiteVisible = true },
                onAddFiles: { presentFileImporter() },
                onAddPastedText: { addPastedTextVisible = true }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: Design.sidebarWidth, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let progress = app.ingestion {
                    ResearchProgressBar(progress: progress) { app.cancelResearch() }
                        .padding(.horizontal, Design.spacingMedium)
                        .padding(.top, Design.spacingSmall)
                }
                HStack(spacing: 0) {
                    WorkingAreaView(
                        onAddWebsite: { addWebsiteVisible = true },
                        onAddFiles: { presentFileImporter() },
                        onAddPastedText: { addPastedTextVisible = true }
                    )
                    if app.settings.showInspector {
                        Divider()
                        InspectorPanelView()
                            .frame(width: Design.inspectorWidth)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
            .toolbar { toolbarContent }
        }
        .sheet(isPresented: $addWebsiteVisible) {
            AddWebsiteSheet { url, title in
                app.addSources(.website(url: url, title: title))
            }
        }
        .sheet(isPresented: $addPastedTextVisible) {
            AddPastedTextSheet { title, text in
                app.addSources(.pastedText(title: title, text: text, url: nil))
            }
        }
        .sheet(isPresented: $exportVisible) {
            ExportSheet()
        }
        .sheet(isPresented: $importVisible) {
            ImportSheet()
        }
        .sheet(isPresented: cloudConsentBinding) {
            CloudConsentSheet()
        }
        .sheet(isPresented: $app.onboardingVisible) {
            OnboardingView { outcome in
                app.completeOnboarding(
                    createStarterNotebook: outcome.createStarterNotebook,
                    model: outcome.selectedModel,
                    providerID: outcome.selectedProviderID
                )
            }
            .interactiveDismissDisabled(false)
        }
        // Research lives here rather than in the command palette, which is dismissed as
        // soon as its command runs.
        .sheet(item: $app.researchRequest) { request in
            ResearchSheet(kind: request.kind) { topic, count in
                app.researchAndAddSources(
                    topic: topic,
                    resultCount: count,
                    createNote: request.kind.noteKind
                )
            }
        }
        .overlay {
            if app.commandPaletteVisible {
                CommandPaletteView()
            }
        }
        .alert(item: errorBinding) { error in
            Alert(
                title: Text(error.title),
                message: Text([error.message, error.recovery].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK")) { app.lastError = nil }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportNotebook)) { _ in exportVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: .importNotebook)) { _ in importVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: .addWebsite)) { _ in addWebsiteVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: .addFiles)) { _ in presentFileImporter() }
        .onReceive(NotificationCenter.default.publisher(for: .addPastedText)) { _ in addPastedTextVisible = true }
    }

    // MARK: Bindings

    private var errorBinding: Binding<AppState.PresentedError?> {
        Binding(
            get: { app.lastError },
            set: { app.lastError = $0 }
        )
    }

    private var cloudConsentBinding: Binding<Bool> {
        Binding(
            get: { app.cloudConsentPromptNotebookID != nil },
            set: { if !$0 { app.cloudConsentPromptNotebookID = nil } }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Section", selection: sectionBinding) {
                // `Label` with a systemImage makes a segmented picker draw icon-only
                // segments, so the symbol's name — "bubble.left.and.text.bubble.right" — was
                // what VoiceOver announced. The segments now read as text, which is both
                // clearer on screen and correct for assistive clients.
                ForEach(AppState.Section.allCases) { section in
                    Text(section.displayName).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .accessibilityLabel("Section")
            .accessibilityValue(app.section.displayName)
            .help("Switch between research, sources, notes, study tools and search")
        }

        ToolbarItem(placement: .principal) {
            ModelMenu()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            AppToolbarActions(
                onCommandPalette: { app.commandPaletteVisible = true },
                onAddWebsite: { addWebsiteVisible = true },
                onAddFiles: { presentFileImporter() },
                onAddPastedText: { addPastedTextVisible = true },
                onFindSources: {
                    app.section = .sources
                    NotificationCenter.default.post(name: .openFindSources, object: nil)
                },
                onResearch: { app.requestResearch(kind: .addSources) },
                onResearchNote: { app.requestResearch(kind: .createNote) },
                onExport: { exportVisible = true },
                onImport: { importVisible = true }
            )
        }
    }

    /// The toolbar's trailing controls: network state, the command palette, and the add menu.
    ///
    /// Extracted from the `ToolbarContentBuilder` into a plain view so the same controls can be
    /// composed outside a window. SwiftUI installs `.toolbar { }` items only for a real scene,
    /// so an offscreen capture of this app showed a title bar with an empty toolbar — the one
    /// image a reader judges. Sharing the views means the capture cannot drift from the app.
    @MainActor
    struct AppToolbarActions: View {
        @Environment(AppState.self) private var app

        let onCommandPalette: () -> Void
        let onAddWebsite: () -> Void
        let onAddFiles: () -> Void
        let onAddPastedText: () -> Void
        let onFindSources: () -> Void
        let onResearch: () -> Void
        let onResearchNote: () -> Void
        let onExport: () -> Void
        let onImport: () -> Void

        var body: some View {
            HStack(spacing: Design.spacingSmall) {
                NetworkIndicator()

                Button(action: onCommandPalette) {
                    Image(systemName: "command")
                }
                // VoiceOver does not read .help(), so an icon-only control needs its own label.
                .accessibilityLabel("Command palette")
                .help("Command palette (⌘K)")

            Menu {
                Button("Find Sources by Topic…", action: onFindSources)
                Button("Add Website…", action: onAddWebsite)
                Button("Add Files…", action: onAddFiles)
                Button("Paste Text…", action: onAddPastedText)
                Divider()
                // Research adds the top results without asking; Find Sources shows the
                // AI's picks for approval first. Both are useful, so both are offered and
                // named for the difference.
                Button("Research a Topic (auto-add)…", action: onResearch)
                Button("Research & Write a Note…", action: onResearchNote)
                Divider()
                Button("Export Notebook…", action: onExport)
                Button("Import Notebook…", action: onImport)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
            .help("Add sources, research a topic, or move notebooks")

            Button {
                app.updateSettings { $0.showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .accessibilityLabel(app.settings.showInspector ? "Hide the inspector" : "Show the inspector")
            .help(app.settings.showInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    private var sectionBinding: Binding<AppState.Section> {
        Binding(get: { app.section }, set: { app.section = $0 })
    }

    private func presentFileImporter() {
        let panel = NSOpenPanel()
        panel.title = "Add sources"
        panel.message = "Choose documents to add. Folders are scanned for supported files."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .pdf, .plainText, .text, .html, .rtf, .epub,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            UTType(filenameExtension: "docx") ?? .data
        ]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        // A single folder means "import this folder"; anything else is a file batch.
        if urls.count == 1, let first = urls.first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            app.addSources(.folder(first))
        } else {
            app.addSources(.files(urls))
        }
    }
}

/// The centre column.
@MainActor
struct WorkingAreaView: View {
    @Environment(AppState.self) private var app
    let onAddWebsite: () -> Void
    let onAddFiles: () -> Void
    let onAddPastedText: () -> Void
    /// Draws the Sources filter as a field in the pane rather than in the window toolbar.
    /// True only when the view is composed outside a real window (the screenshot pass).
    var inlineSearchField = false

    var body: some View {
        VStack(spacing: 0) {
            if let ingestion = app.ingestion {
                VStack {
                    ProgressBanner(
                        title: ingestion.title,
                        stage: ingestion.stage,
                        fraction: ingestion.overall,
                        detail: ingestion.itemCount > 1 ? "Item \(ingestion.itemIndex) of \(ingestion.itemCount)" : nil,
                        onCancel: nil
                    )
                }
                .padding(Design.spacingMedium)
                .padding(.bottom, 0)
            }

            if let error = app.lastError, error.isWarning {
                VStack {
                    ErrorCard(title: error.title, message: error.message, recovery: error.recovery,
                              isWarning: true) { app.lastError = nil }
                }
                .padding(.horizontal, Design.spacingMedium)
                .padding(.top, Design.spacingSmall)
            }

            Group {
                if app.store == nil {
                    EmptyStateView(
                        symbol: "externaldrive.badge.xmark",
                        title: "Your library could not be opened",
                        message: app.lastError?.message ?? "SourceDesk could not open its storage folder.",
                        footnote: "Check that ~/Library/Application Support/SourceDesk is writable, then relaunch."
                    )
                } else if app.selectedNotebookID == nil {
                    EmptyStateView(
                        symbol: "books.vertical",
                        title: "No notebook selected",
                        message: "Notebooks hold their own sources, conversations, notes and study material. Create one to begin.",
                        primaryAction: ("New Notebook", { _ = app.createNotebook(title: "Untitled notebook") }),
                        secondaryAction: ("Import a Notebook…", { NotificationCenter.default.post(name: .importNotebook, object: nil) })
                    )
                } else {
                    switch app.section {
                    case .research:
                        ResearchView()
                    case .sources:
                        SourcesView(onAddWebsite: onAddWebsite, onAddFiles: onAddFiles,
                                    onAddPastedText: onAddPastedText,
                                    inlineSearchField: inlineSearchField)
                    case .notes:
                        NotesView()
                    case .studyTools:
                        StudyToolsView()
                    case .search:
                        SearchPanelView()
                    }
                }
            }
        }
        .frame(minWidth: Design.minimumCentreWidth, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The model picker in the toolbar: switches provider and model in one place, and
/// states the privacy consequence of the choice.
@MainActor
struct ModelMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            ForEach(app.providers.all, id: \.identifier) { provider in
                let section = app.menuSection(for: provider)
                Section(section.displayName) {
                    // An unconfigured provider is still listed: the user needs to see
                    // what the choice contains. Choosing a model the provider cannot run
                    // reports what is missing instead of quietly implying it will answer.
                    if let statusLine = section.statusLine {
                        Text(statusLine)
                    }

                    if section.rows.isEmpty {
                        if let emptyLine = section.emptyLine { Text(emptyLine) }
                    } else {
                        ForEach(section.rows) { row in
                            Button {
                                select(provider: provider, model: row.model)
                            } label: {
                                if isSelected(provider: provider, model: row.model) {
                                    Label("\(row.model.name) — \(row.model.detailLine)", systemImage: "checkmark")
                                } else {
                                    Text("\(row.model.name) — \(row.model.detailLine)")
                                }
                            }
                        }
                    }

                    Button("Use \(section.displayName)") {
                        app.updateSettings { $0.preferredProviderID = provider.identifier }
                        Task { await app.loadModels(for: provider.identifier) }
                    }
                }
            }
            Divider()
            Button("Refresh Model Lists") {
                Task { await app.refreshAllModels() }
            }
            SettingsLink {
                Text("AI Provider Settings…")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: app.currentProvider?.isLocal == true ? "desktopcomputer" : "cloud")
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.currentModelName.isEmpty ? "Choose a model" : app.currentModelName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(app.currentProvider?.displayName ?? "No provider")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(app.modelStatusLine)
        .task { await app.loadModels(for: app.settings.preferredProviderID) }
    }

    private func statusText(for provider: AIProvider) -> String {
        switch app.modelDiscoveryState[provider.identifier] {
        case .notConfigured(let reason): return reason
        case .unreachable(let reason): return reason
        case .unavailable(let reason): return reason
        case .ready: return app.probedProviders.contains(provider.identifier) ? "No models found" : "Checking…"
        case nil: return provider.isLocal ? "Local provider" : "Cloud provider"
        }
    }

    private func isSelected(provider: AIProvider, model: ModelDescriptor) -> Bool {
        app.settings.preferredProviderID == provider.identifier
            && app.settings.model(for: provider.identifier) == model.name
    }

    /// Selecting a model the provider cannot currently run still records the choice —
    /// the user may be about to add a key — but says plainly what is missing rather
    /// than letting the picker imply the model is usable.
    private func select(provider: AIProvider, model: ModelDescriptor) {
        app.updateSettings {
            $0.preferredProviderID = provider.identifier
            $0.modelSelection[provider.identifier] = model.name
        }
        if let availability = app.modelDiscoveryState[provider.identifier],
           !availability.isReady,
           let reason = availability.reason {
            app.statusMessage = "\(provider.displayName): \(reason)"
        }
    }
}

/// A small, always-visible connectivity state. Offline is not an error condition —
/// it is a mode, and the app says which features it affects.
@MainActor
struct NetworkIndicator: View {
    @Environment(AppState.self) private var app
    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(app.isOnline ? Design.statusOnline : Design.statusWarning)
                    .frame(width: 6, height: 6)
                Text(app.isOnline ? "Online" : "Offline")
                    .font(Design.caption)
            }
        }
        .buttonStyle(.accessoryBar)
        .help(app.isOnline ? "Connected. Cloud models and web search are available." : "Offline. Notebooks, saved sources, local search and local models still work.")
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                Text(app.isOnline ? "Connected" : "Working offline")
                    .font(.system(size: 12, weight: .semibold))
                Text(app.isOnline
                     ? "Web search, website downloads and cloud AI providers are available."
                     : "Notebooks, saved sources, local search and local models keep working. Web search, new downloads and cloud providers are unavailable until you reconnect.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 280)
                    .fixedSize(horizontal: false, vertical: true)
                if app.settings.localOnlyMode {
                    Divider()
                    Label("Local-Only Mode is on: cloud providers are disabled.", systemImage: "lock.fill")
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 280, alignment: .leading)
                }
            }
            .padding(Design.spacingMedium)
        }
    }
}

/// One-time confirmation before any source text is sent to a cloud provider.
@MainActor
struct CloudConsentSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingMedium) {
            HStack(spacing: Design.spacingSmall) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 18))
                Text("Send source content to \(app.currentProvider?.displayName ?? "a cloud provider")?")
                    .font(.system(size: 14, weight: .semibold))
            }

            Text("To answer from your sources, SourceDesk sends the passages it retrieved — not your whole library — to the selected provider. Your notebook, files and database stay on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                let passageCount = (try? app.store?.chunkCount(notebookID: app.selectedNotebookID ?? "")) ?? 0
                Label("This notebook has \(Format.count(app.sources.count, "source")), \(Format.count(passageCount, "passage")).", systemImage: "doc.on.doc")
                Label("Approval applies to this notebook only.", systemImage: "checkmark.shield")
                Label("You can revoke it at any time in Settings → Privacy.", systemImage: "lock.rotation")
            }
            .font(Design.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Use a local model instead") {
                    let local = app.providers.localProviders.first
                    if let local {
                        app.updateSettings { $0.preferredProviderID = local.identifier }
                    }
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Approve for this notebook") {
                    if let id = app.cloudConsentPromptNotebookID {
                        app.approveCloudConsent(for: id)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Design.spacingLarge)
        .frame(width: 520)
    }
}
