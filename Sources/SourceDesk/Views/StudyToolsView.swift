import SwiftUI
import SourceDeskCore

/// Study tools: pick a generator, choose the material, read the result as it is
/// written, and keep it as a note.
@MainActor
struct StudyToolsView: View {
    @Environment(AppState.self) private var app
    @Environment(StudyToolsViewModel.self) private var study

    var body: some View {
        HStack(spacing: 0) {
            toolPicker
                .frame(width: 216)

            Divider()

            VStack(spacing: 0) {
                materialBar
                Divider()

                if let reason = study.blockingReason {
                    VStack {
                        EmptyStateView(
                            symbol: "exclamationmark.circle",
                            title: study.canGenerate ? "Not ready yet" : "This tool needs something first",
                            message: reason,
                            primaryAction: blockingAction.map { action in (action.title, action.action) }
                        )
                    }
                } else if study.isGenerating || !study.streamingText.isEmpty {
                    generatingView
                } else if let note = study.currentNote {
                    resultView(note)
                } else {
                    EmptyStateView(
                        symbol: "graduationcap",
                        title: "Generate study material",
                        message: "Choose a tool on the left. Everything is generated from this notebook's sources only, and every generated document is saved to Notes so you can edit it.",
                        primaryAction: ("Generate \(study.selectedTool.displayName)", { study.generate() }),
                        footnote: "Summaries, key points, flashcards, quizzes, study guides, outlines, FAQs, timelines, quotations, source comparisons and briefings."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var blockingAction: (title: String, action: () -> Void)? {
        if app.sources.isEmpty {
            return ("Add a Website", { NotificationCenter.default.post(name: .addWebsite, object: nil) })
        }
        if study.selectedTool == .comparison && app.sources.count < 2 {
            return ("Choose a different tool", { study.selectedTool = .summary })
        }
        if app.settings.localOnlyMode, let provider = app.currentProvider, !provider.isLocal {
            return ("Switch to a local model", {
                if let local = app.providers.localProviders.first {
                    app.updateSettings { $0.preferredProviderID = local.identifier }
                }
            })
        }
        if let provider = app.currentProvider, !provider.isLocal, !provider.isConfigured {
            return ("Open Provider Settings", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!) })
        }
        return nil
    }

    // MARK: Tool picker

    private var toolPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Tools"))
                .font(Design.sectionTitle)
                .padding(.horizontal, Design.spacingSmall)
                .padding(.top, Design.spacingSmall)
                .padding(.bottom, 6)

            List(selection: Binding(
                get: { study.selectedTool },
                set: { study.selectedTool = $0 }
            )) {
                ForEach(StudyToolsService.availableTools, id: \.self) { tool in
                    HStack(spacing: 6) {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 11))
                            .frame(width: 15)
                        Text(tool.displayName)
                            .font(Design.rowTitle)
                    }
                    .padding(.vertical, 2)
                    .tag(tool)
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text(study.selectedTool.displayName)
                    .font(.system(size: 11, weight: .semibold))
                Text(explanation(for: study.selectedTool))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Design.spacingSmall)
        }
        .background(.thinMaterial)
    }

    private func explanation(for tool: NoteKind) -> String {
        switch tool {
        case .summary: return L("An overview, the main points, and what the material leaves unsettled.")
        case .keyPoints: return L("Eight to twelve specific, checkable points, ordered by importance.")
        case .flashcards: return L("Question-and-answer cards you can step through here.")
        case .quiz: return L("Multiple-choice questions with answers, explanations and scoring.")
        case .studyGuide: return L("Concepts, how they connect, and questions to test yourself.")
        case .outline: return L("A hierarchical outline following the material's own structure.")
        case .faq: return L("Questions a careful reader would ask, with direct answers.")
        case .timeline: return L("A chronological list drawn from dates in the material.")
        case .quotations: return L("Verbatim excerpts, with why each matters.")
        case .comparison: return L("Where two or more sources agree, disagree, and what each adds.")
        case .briefing: return L("The important points, context, and what remains uncertain.")
        case .manual: return L("Free-form notes from the selected material.")
        }
    }

    // MARK: Material bar

    private var materialBar: some View {
        HStack(spacing: Design.spacingSmall) {
            if app.sources.isEmpty {
                Text(L("No sources in this notebook"))
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("All sources (\(app.sources.count))") { study.clearSourceSelection() }
                    Divider()
                    ForEach(app.sources) { source in
                        Button {
                            study.toggleSource(source.id)
                        } label: {
                            HStack {
                                Text(source.title)
                                if study.chosenSourceIDs.contains(source.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                        Text(materialLabel).font(Design.caption)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose which sources the tool uses")
            }

            TextField("Optional focus, e.g. “causes of the delay”", text: Binding(
                get: { study.focusText },
                set: { study.focusText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .frame(maxWidth: 260)

            Spacer()

            if study.isGenerating {
                Button(L("Stop")) { study.cancel() }
                    .controlSize(.small)
            } else {
                Button {
                    study.generate()
                } label: {
                    Label(L("Generate"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!study.canGenerate)
            }
        }
        .padding(.horizontal, Design.spacingMedium)
        .padding(.vertical, Design.spacingSmall)
    }

    private var materialLabel: String {
        if let ids = study.effectiveSourceIDs {
            return "\(Format.count(ids.count, "source")) of \(Format.count(app.sources.count, "source"))"
        }
        return "All sources (\(app.sources.count))"
    }

    // MARK: Generating

    private var generatingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.spacingMedium) {
                HStack(spacing: Design.spacingSmall) {
                    ProgressView().controlSize(.small)
                    Text(study.stage ?? "Working")
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                }
                if study.streamingText.isEmpty {
                    Text(L("Preparing material from your sources…"))
                        .font(Design.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    MarkdownAnswer(text: study.streamingText, citations: [])
                }
            }
            .padding(Design.spacingLarge)
            .frame(maxWidth: Design.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Result

    private func resultView(_ note: NotebookNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.spacingMedium) {
                HStack(spacing: Design.spacingSmall) {
                    StatusPill(text: note.kind.displayName, color: .secondary, symbol: note.kind.symbolName)
                    if let model = note.modelName {
                        Text(model).font(Design.caption).foregroundStyle(.tertiary)
                    }
                }

                if !study.notices.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(study.notices, id: \.self) { notice in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(notice).font(Design.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if let payload = note.payload, !payload.isEmpty {
                    if !payload.flashcards.isEmpty {
                        FlashcardDeck(cards: payload.flashcards,
                                      index: .constant(0),
                                      revealed: .constant(Set(payload.flashcards.map(\.id))))
                    }
                    if !payload.quizItems.isEmpty {
                        QuizRunner(items: payload.quizItems, answers: .constant([:]))
                    }
                }

                MarkdownAnswer(text: note.body, citations: [])

                HStack(spacing: Design.spacingSmall) {
                    Button(L("Open in Notes")) {
                        app.selectedNoteID = note.id
                        app.section = .notes
                    }
                    Button(L("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.body, forType: .string)
                        app.statusMessage = "Copied to the clipboard"
                    }
                    if let url = exportURL(note) {
                        Button(L("Export as Markdown…")) {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "\(NotebookArchive.sanitize(note.title)).md"
                            panel.allowedContentTypes = [.plainText]
                            guard panel.runModal() == .OK, let target = panel.url else { return }
                            _ = try? FileStore.write(note.body, to: target)
                        }
                        .help("Save a copy at \(url.path)")
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(Design.spacingLarge)
            .frame(maxWidth: Design.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func exportURL(_ note: NotebookNote) -> URL? {
        URL(string: "file:///\(NotebookArchive.sanitize(note.title)).md")
    }
}

// MARK: - Standalone web search

/// The web-search panel: search the internet without involving a conversation.
@MainActor
struct SearchPanelView: View {
    @Environment(AppState.self) private var app
    @Environment(SearchPanelViewModel.self) private var search

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.spacingSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search the web", text: Binding(
                    get: { search.query },
                    set: { search.query = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { search.search() }

                if search.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("Search")) { search.search() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(Design.spacingMedium)

            Divider()

            if let reason = search.blockingReason {
                EmptyStateView(
                    symbol: "globe.badge.chevron.backward",
                    title: "Web search is unavailable",
                    message: reason,
                    primaryAction: app.settings.searchEngine == .none
                        ? ("Open Search Settings", { openSettings() })
                        : nil
                )
            } else if let error = search.error {
                VStack {
                    ErrorCard(title: error.title, message: error.message, recovery: error.recovery) {
                        search.error = nil
                    }
                }
                .padding(Design.spacingMedium)
                Spacer()
            } else if search.results.isEmpty && search.lastQuery == nil {
                EmptyStateView(
                    symbol: "globe",
                    title: "Search without starting a conversation",
                    message: "Results come from \(search.providerName). Add any result to this notebook as a source, or save it to Notes.",
                    footnote: "Web results are always labelled separately from your notebook sources."
                )
            } else if search.results.isEmpty {
                EmptyStateView(
                    symbol: "questionmark.circle",
                    title: "No results",
                    message: "The search for “\(search.lastQuery ?? "")” returned nothing usable. Try different wording."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.spacingMedium) {
                        if let notice = search.notice {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(notice).font(Design.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        ForEach(search.results) { result in
                            SearchResultRow(result: result) {
                                search.addAsSource(result)
                            } saveNote: {
                                search.saveAsNote(result)
                            }
                        }
                    }
                    .padding(Design.spacingLarge)
                    .frame(maxWidth: Design.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

@MainActor
struct SearchResultRow: View {
    let result: WebSearchResult
    let addSource: () -> Void
    let saveNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: result.url) {
                Link(destination: url) {
                    Text(result.url)
                        .font(Design.monoCaption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(result.snippet.isEmpty ? result.content : result.snippet)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Design.spacingSmall) {
                StatusPill(text: "web result", color: .blue, symbol: "globe")
                if let site = result.siteName {
                    Text(site).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Add as Source", action: addSource)
                    .controlSize(.small)
                Button("Save to Notes", action: saveNote)
                    .controlSize(.small)
            }
        }
        .padding(Design.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.rowCornerRadius).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }
}
