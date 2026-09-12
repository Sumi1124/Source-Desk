import SwiftUI
import SourceDeskCore

/// The right column. Its contents follow the selection: a source, a citation, a
/// note, or the current session's retrieval detail.
struct InspectorPanelView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tabTitle)
                    .font(Design.sectionTitle)
                Spacer()
                if app.section == .sources, let source = app.selectedSource {
                    SourceQuickActions(source: source)
                }
            }
            .padding(.horizontal, Design.spacingMedium)
            .padding(.vertical, Design.spacingSmall)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Design.spacingLarge) {
                    switch app.section {
                    case .sources:
                        if let source = app.selectedSource {
                            SourceInspector(source: source)
                        } else {
                            placeholder("No source selected", "Choose a source to see what was stored, and how it will be cited.")
                        }
                    case .research:
                        ResearchInspector()
                    case .notes:
                        NotesInspector()
                    case .studyTools:
                        StudyToolsInspector()
                    case .search:
                        placeholder("Web search", "Results appear in the centre column. Click a result to inspect or add it.")
                    }
                }
                .padding(Design.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tabTitle: String {
        switch app.section {
        case .sources: return app.selectedSource == nil ? "Inspector" : "Source"
        case .research: return "Answer detail"
        case .notes: return "Note"
        case .studyTools: return "Study material"
        case .search: return "Search"
        }
    }

    private func placeholder(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Design.spacingLarge)
    }
}

private struct SourceQuickActions: View {
    @Environment(AppState.self) private var app
    let source: Source

    var body: some View {
        HStack(spacing: 2) {
            if source.url != nil {
                Button {
                    app.refreshSource(source)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Re-download this page")
            }
            Button {
                app.reindexSource(source.id)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Re-chunk and re-embed from the stored text")
            Menu {
                Button(source.includeInRetrieval ? "Exclude from answers" : "Include in answers") {
                    app.toggleSourceInRetrieval(source)
                }
                if let url = source.url, let parsed = URL(string: url) {
                    Button("Open in Browser") { NSWorkspace.shared.open(parsed) }
                }
                if let path = source.filePath {
                    Button("Reveal Original") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Divider()
                Button("Delete Source", role: .destructive) { app.deleteSource(source.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// Everything SourceDesk knows about one source: where it came from, what it holds,
/// how it was processed, and how it will be cited.
struct SourceInspector: View {
    @Environment(AppState.self) private var app
    let source: Source

    @State private var showFullText = false
    @State private var showPassages = false
    @State private var fullText: String = ""
    @State private var chunks: [SourceChunk] = []
    @State private var notesDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            // Title and provenance
            VStack(alignment: .leading, spacing: 5) {
                Text(source.title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    StatusPill(text: source.status.displayName, color: Design.statusColor(source.status))
                    StatusPill(text: source.kind.displayName, color: .secondary, symbol: source.kind.symbolName)
                    if !source.includeInRetrieval {
                        StatusPill(text: "excluded", color: .orange, symbol: "eye.slash")
                    }
                }
                if let author = source.author, !author.isEmpty {
                    Text(author).font(Design.caption).foregroundStyle(.secondary)
                }
                if let url = source.url, let parsed = URL(string: url) {
                    Link(destination: parsed) {
                        Text(url)
                            .font(Design.monoCaption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                if let site = source.siteName, source.url == nil {
                    Text(site).font(Design.caption).foregroundStyle(.secondary)
                }
            }

            if let error = source.errorMessage {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader("Problem")
                    ErrorCard(title: "This source could not be fully added",
                              message: error, recovery: source.errorRecovery,
                              isWarning: source.status == .partial)
                }
            }

            // Contents
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Contents")
                DetailRow(label: "Passages", value: Format.count(source.chunkCount))
                if source.wordCount > 0 { DetailRow(label: "Words", value: Format.count(source.wordCount)) }
                if let pages = source.pageCount { DetailRow(label: "Pages", value: Format.count(pages)) }
                if source.plainTextBytes > 0 {
                    DetailRow(label: "Stored text", value: Format.bytes(source.plainTextBytes))
                }
                if source.originalBytes > 0 {
                    DetailRow(label: "Downloaded", value: Format.bytes(source.originalBytes))
                }
                if let method = source.extractionMethod {
                    DetailRow(label: "Extracted by", value: method)
                }
                if let ms = source.fetchMilliseconds {
                    DetailRow(label: "Fetch time", value: Format.milliseconds(ms))
                }
            }

            // Dates
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Timeline")
                DetailRow(label: "Added", value: Format.shortDate(source.addedAt))
                if let fetched = source.fetchedAt {
                    DetailRow(label: "Fetched", value: Format.shortDate(fetched))
                }
                if let published = source.publishedAt {
                    DetailRow(label: "Published", value: Format.shortDate(published))
                }
                DetailRow(label: "Checked", value: Format.relative(source.updatedAt))
            }

            // Privacy
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Privacy")
                PrivacyNotice(level: .local, detailOverride: "The stored text lives in \(app.paths.displayPath(app.paths.contentDirectory(for: source.id)))")
                if app.settings.storeOriginalDownloads, source.filePath != nil {
                    Text("The original file is kept in the same folder, so the source survives the file being moved.")
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Extracted text
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Extracted text")
                Button(showFullText ? "Hide" : "Show \(Format.count(source.wordCount)) words") {
                    if !showFullText && fullText.isEmpty {
                        fullText = app.sourceText(for: source)
                    }
                    showFullText.toggle()
                }
                .buttonStyle(.link)
                .font(Design.caption)

                if showFullText {
                    ScrollView {
                        Text(fullText.isEmpty ? "No stored text." : fullText)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                }
            }

            // Passages, so the retrieval unit is visible
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Passages sent to the model")
                Button(showPassages ? "Hide" : "Show how this source is split") {
                    if !showPassages && chunks.isEmpty {
                        chunks = app.chunks(for: source.id)
                    }
                    showPassages.toggle()
                }
                .buttonStyle(.link)
                .font(Design.caption)

                if showPassages {
                    if chunks.isEmpty {
                        Text("This source has no passages yet — re-index it from the actions above.")
                            .font(Design.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: Design.spacingSmall) {
                            ForEach(chunks.prefix(40)) { chunk in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text("#\(chunk.ordinal + 1)")
                                            .font(Design.monoCaption)
                                            .foregroundStyle(.tertiary)
                                        if let page = chunk.pageNumber {
                                            Text("page \(page)").font(.system(size: 10)).foregroundStyle(.tertiary)
                                        }
                                        Text("\(chunk.tokenCount) tokens")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let heading = chunk.headingPath, !heading.isEmpty {
                                        Text(heading)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(TextMath.preview(chunk.text, limit: 180))
                                        .font(Design.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
                            }
                            if chunks.count > 40 {
                                Text("Showing the first 40 of \(Format.count(chunks.count)) passages.")
                                    .font(Design.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            // Personal notes on the source
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Your note on this source")
                TextEditor(text: $notesDraft)
                    .font(.system(size: 11))
                    .frame(height: 70)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                HStack {
                    Spacer()
                    Button("Save Note") {
                        var copy = source
                        copy.notes = notesDraft
                        if let store = app.store {
                            try? store.upsert(source: copy)
                            app.reloadNotebookContent()
                            app.statusMessage = "Source note saved"
                        }
                    }
                    .controlSize(.small)
                    .disabled(notesDraft == source.notes)
                }
            }
        }
        .onAppear { notesDraft = source.notes }
        .onChange(of: source.id) { _, _ in
            notesDraft = source.notes
            showFullText = false
            showPassages = false
            fullText = ""
            chunks = []
        }
    }
}

/// Inspector content while the research section is showing: the citations behind the
/// answer the user is reading.
struct ResearchInspector: View {
    @Environment(AppState.self) private var app
    @Environment(ChatViewModel.self) private var chat

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            if app.activeCitations.isEmpty {
                VStack(alignment: .leading, spacing: Design.spacingSmall) {
                    Text("No citations yet")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Ask a question and the passages behind the answer appear here — with their source, page and excerpt, so you can check the answer rather than trust it.")
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Design.spacingMedium)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader("Citations in this answer")
                    ForEach(app.activeCitations) { citation in
                        CitationDetail(citation: citation)
                    }
                }
            }

            if let trace = app.activeTrace {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader("Retrieval")
                    DetailRow(label: "Query", value: trace.query)
                    DetailRow(label: "Candidates", value: Format.count(trace.candidateCount))
                    DetailRow(label: "Used", value: "\(trace.hits.count) passages")
                    DetailRow(label: "Context", value: "\(Format.tokens(trace.usedTokens)) / \(Format.tokens(trace.contextBudget)) tokens")
                    DetailRow(label: "Duration", value: Format.milliseconds(trace.durationMilliseconds))
                    DetailRow(label: "Semantic", value: trace.semanticEnabled ? "on" : "off", tint: trace.semanticEnabled ? .green : .secondary)
                    DetailRow(label: "Keyword", value: trace.keywordEnabled ? "on" : "off")
                    DetailRow(label: "Reranked", value: trace.rerankEnabled ? "on" : "off")
                    if !trace.notes.isEmpty {
                        ForEach(trace.notes, id: \.self) { note in
                            Text(note)
                                .font(Design.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !chat.messages.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader("This session")
                    DetailRow(label: "Messages", value: Format.count(chat.messages.count))
                    if let session = chat.currentSession {
                        DetailRow(label: "Scope", value: session.scope.displayName)
                        DetailRow(label: "Started", value: Format.relative(session.createdAt))
                    }
                }
            }
        }
    }
}

/// A full citation with everything needed to verify it: source, page, section,
/// excerpt, and a way to open the original.
struct CitationDetail: View {
    @Environment(AppState.self) private var app
    let citation: Citation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(citation.marker)
                    .font(Design.monoCaption)
                    .foregroundStyle(Design.citationColor(citation.kind))
                Text(citation.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                if citation.kind == .web {
                    StatusPill(text: "web", color: .blue, symbol: "globe")
                }
            }

            if let url = citation.url, let parsed = URL(string: url) {
                Link(destination: parsed) {
                    Text(url).font(Design.monoCaption).lineLimit(2).truncationMode(.middle)
                }
            }

            if !citation.provenance.isEmpty {
                Text(citation.provenance)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(citation.excerpt)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: Design.spacingSmall) {
                if let sourceID = citation.sourceID {
                    Button("Open source") {
                        app.selectedSourceID = sourceID
                        app.section = .sources
                    }
                    .buttonStyle(.link)
                    .font(Design.caption)
                }
                Button("Copy excerpt") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(citation.excerpt, forType: .string)
                }
                .buttonStyle(.link)
                .font(Design.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.rowCornerRadius).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Inspector content for notes: note metadata, and for quiz/flashcards, the
/// structured items the note carries.
struct NotesInspector: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            if let note = app.selectedNote {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader("Details")
                    DetailRow(label: "Kind", value: note.kind.displayName)
                    DetailRow(label: "Created", value: Format.shortDate(note.createdAt))
                    DetailRow(label: "Updated", value: Format.relative(note.updatedAt))
                    if let model = note.modelName {
                        DetailRow(label: "Model", value: model)
                    }
                    if !note.sourceIDs.isEmpty {
                        DetailRow(label: "Sources", value: "\(note.sourceIDs.count)")
                    }
                }

                if let payload = note.payload, !payload.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader("Structured content")
                        if !payload.flashcards.isEmpty {
                            DetailRow(label: "Cards", value: Format.count(payload.flashcards.count))
                        }
                        if !payload.quizItems.isEmpty {
                            DetailRow(label: "Questions", value: Format.count(payload.quizItems.count))
                        }
                    }
                }

                if !note.sourceIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader("Built from")
                        ForEach(note.sourceIDs, id: \.self) { id in
                            if let source = app.sources.first(where: { $0.id == id }) {
                                Button {
                                    app.selectedSourceID = source.id
                                    app.section = .sources
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: source.kind.symbolName).font(.system(size: 10))
                                        Text(source.title).font(Design.caption).lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Design.spacingSmall) {
                    Text("No note selected")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Select a note to see where it came from, or generate study material from the Study Tools section.")
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Design.spacingMedium)
            }
        }
    }
}

struct StudyToolsInspector: View {
    @Environment(AppState.self) private var app
    @Environment(StudyToolsViewModel.self) private var study

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Material")
                DetailRow(label: "Sources", value: "\(app.sources.count)")
                DetailRow(label: "Passages", value: Format.count(app.sources.reduce(0) { $0 + $1.chunkCount }))
                if let ids = study.effectiveSourceIDs {
                    DetailRow(label: "Selected", value: "\(ids.count) of \(app.sources.count)")
                } else {
                    DetailRow(label: "Selected", value: "all sources")
                }
            }

            if let note = study.currentNote, let payload = note.payload, !payload.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader("Generated")
                    DetailRow(label: "Cards", value: Format.count(payload.flashcards.count))
                    DetailRow(label: "Questions", value: Format.count(payload.quizItems.count))
                    DetailRow(label: "Model", value: note.modelName ?? "—")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Tools")
                ForEach(StudyToolsService.availableTools, id: \.self) { tool in
                    HStack(spacing: 5) {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                        Text(tool.displayName)
                            .font(Design.caption)
                            .foregroundStyle(tool == study.selectedTool ? .primary : .secondary)
                        Spacer(minLength: 0)
                        if tool == study.selectedTool {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}
