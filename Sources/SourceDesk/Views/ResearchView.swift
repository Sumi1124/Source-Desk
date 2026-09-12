import SwiftUI
import SourceDeskCore

/// Source-grounded chat. The main surface of the application.
@MainActor
struct ResearchView: View {
    @Environment(AppState.self) private var app
    @Environment(ChatViewModel.self) private var chat

    @State private var draft = ""
    @State private var scope: AnswerScope = .notebookSources
    @FocusState private var composerFocused: Bool

    private var session: ChatSession? { chat.currentSession }

    /// The scope to show: the session's, then the notebook's, then the default. One
    /// source of truth, so the composer, the persisted session and the engine all agree.
    private var currentStoredScope: AnswerScope {
        session?.scope ?? app.selectedNotebook?.defaultScope ?? app.settings.defaultAnswerScope
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if chat.messages.isEmpty && !chat.isStreaming {
                    emptyState
                } else {
                    transcript
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = app.lastError, !error.isWarning {
                ErrorCard(title: error.title, message: error.message, recovery: error.recovery) {
                    app.lastError = nil
                }
                .padding(.horizontal, Design.spacingMedium)
                .padding(.bottom, Design.spacingSmall)
            }

            composer
        }
        .onChange(of: app.selectedSessionID) { _, _ in chat.loadMessages() }
        .onChange(of: app.selectedNotebookID) { _, _ in
            chat.loadMessages()
            scope = currentStoredScope
        }
        .onChange(of: app.selectedSessionID) { _, _ in
            // Switching sessions must show that session's scope, not the previous one's.
            scope = currentStoredScope
        }
        .onAppear {
            scope = currentStoredScope
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: Design.spacingSmall) {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.selectedNotebook?.title ?? "Notebook")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(app.sources.count) source\(app.sources.count == 1 ? "" : "s")")
                    if let session {
                        Text("·")
                        Text(session.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(Design.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: Design.spacingSmall)

            Picker("Answer source", selection: $scope) {
                ForEach(AnswerScope.allCases, id: \.self) { value in
                    Text(value.shortName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .help(scope.explanation)
            .onChange(of: scope) { _, newValue in
                if let session, session.scope != newValue {
                    app.setSessionScope(session, scope: newValue)
                } else if session == nil {
                    // Before a session exists there is nothing to record the choice on,
                    // so it is stored as the notebook's preference. Otherwise picking
                    // "Sources + Web" was forgotten the moment it was used.
                    app.setDefaultScope(newValue)
                }
            }

            Menu {
                if let session {
                    Button("Rename Session…") {
                        NotificationCenter.default.post(name: .renameSession, object: session.id)
                    }
                }
                Button("New Session") { createSession() }
                Divider()
                ForEach(app.sessions) { item in
                    Button(item.title) {
                        app.selectedSessionID = item.id
                        chat.loadMessages()
                    }
                }
                Divider()
                Button("Delete This Session", role: .destructive) {
                    if let session { app.deleteSession(session.id) }
                }
                .disabled(session == nil)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch between research sessions in this notebook")

            Button {
                createSession()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.accessoryBar)
            .help("Start a new session")
        }
        .padding(.horizontal, Design.spacingMedium)
        .padding(.vertical, Design.spacingSmall)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.spacingLarge) {
                    ForEach(chat.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }

                    if chat.isStreaming {
                        StreamingAnswerView(
                            text: chat.streamingText,
                            reasoning: chat.streamingReasoning,
                            stage: chat.stage
                        )
                        .id("streaming")
                    }

                    if !chat.notices.isEmpty || !chat.suggestedFollowUps.isEmpty {
                        footer
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Design.spacingLarge)
                .padding(.vertical, Design.spacingLarge)
                .frame(maxWidth: Design.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: chat.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.streamingText) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: Footer (notices, retrieval summary, follow-ups)

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            if !chat.notices.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(chat.notices, id: \.self) { notice in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text(notice)
                                .font(Design.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let trace = chat.messages.last(where: { $0.role == .assistant })?.retrieval, !trace.hits.isEmpty {
                RetrievalSummary(trace: trace)
            }

            if !chat.suggestedFollowUps.isEmpty {
                HStack(spacing: Design.spacingSmall) {
                    ForEach(chat.suggestedFollowUps, id: \.self) { suggestion in
                        Button(suggestion) {
                            draft = suggestion
                            composerFocused = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        Group {
            if app.sources.isEmpty {
                EmptyStateView(
                    symbol: "text.magnifyingglass",
                    title: "Ask questions about your sources",
                    message: "This notebook has no sources yet. Add a website, a PDF, a document, or paste text — answers are generated from what you add, with citations.",
                    primaryAction: ("Add a Website", { NotificationCenter.default.post(name: .addWebsite, object: nil) }),
                    secondaryAction: ("Add Files", { NotificationCenter.default.post(name: .addFiles, object: nil) }),
                    footnote: "Sources are stored on this Mac. Nothing is uploaded unless you choose a cloud model."
                )
            } else {
                EmptyStateView(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "Start a research session",
                    message: "Ask anything about the \(app.sources.count) source\(app.sources.count == 1 ? "" : "s") in this notebook. Answers cite the passages they came from, and every citation is clickable.",
                    footnote: "Tip: press ⌘K for the command palette, or ⌘2 to manage sources."
                )
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: Design.spacingSmall) {
            ModelPrivacyLine(scope: scope)

            HStack(alignment: .bottom, spacing: Design.spacingSmall) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(composerPlaceholder)
                            .font(Design.answerBody)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(Design.answerBody)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 38, maxHeight: 160)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .focused($composerFocused)
                        .onSubmit(submit)
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                if chat.isStreaming {
                    Button("Stop") { chat.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        submit()
                    } label: {
                        Label("Ask", systemImage: "arrow.up.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Ask (⌘↩)")
                }
            }

            if scope == .notebookSources && app.settings.searchEngine != .none && !app.isOnline {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash").font(.system(size: 9))
                    Text("Offline: answers use your saved sources and (if selected) a local model.")
                        .font(Design.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Design.spacingMedium)
        .padding(.vertical, Design.spacingSmall)
        .background(.bar)
    }

    private var composerPlaceholder: String {
        switch scope {
        case .notebookSources: return "Ask about your sources…"
        case .notebookAndWeb: return "Ask using your sources and the web…"
        case .webOnly: return "Search the web…"
        }
    }

    private func submit() {
        let question = draft
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        chat.ask(question, scope: scope)
    }

    private func createSession() {
        if let created = app.createSession() {
            app.setSessionScope(created, scope: scope)
            chat.loadMessages()
        }
    }
}

/// The line above the composer: exactly which model will answer, and what that means
/// for privacy.
@MainActor
struct ModelPrivacyLine: View {
    @Environment(AppState.self) private var app
    let scope: AnswerScope

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: app.currentProvider?.isLocal == true ? "desktopcomputer" : "cloud")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(app.modelStatusLine)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if scope.usesWeb {
                Divider().frame(height: 10)
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                Text("queries go to \(app.settings.searchEngine.displayName)")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .help(scope.explanation)
    }
}

/// The retrieval summary under an answer: what was searched, what was found, how it
/// was ranked. This is the "show your work" panel that makes answers inspectable.
@MainActor
struct RetrievalSummary: View {
    let trace: RetrievalTrace
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(summaryLine)
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Design.spacingMedium) {
                        Text("\(trace.hits.count) passage\(trace.hits.count == 1 ? "" : "s") used")
                        Text("\(Format.tokens(trace.usedTokens)) of \(Format.tokens(trace.contextBudget)) tokens")
                        Text("\(trace.candidateCount) candidates")
                    }
                    .font(Design.caption)
                    .foregroundStyle(.secondary)

                    ForEach(Array(trace.hits.enumerated()), id: \.element.chunkID) { index, hit in
                        HStack(alignment: .top, spacing: 6) {
                            Text("[Source \(index + 1)]")
                                .font(Design.monoCaption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.sourceTitle)
                                    .font(.system(size: 11, weight: .medium))
                                Text(hit.preview)
                                    .font(Design.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(scoreLine(hit))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 1)
                    }

                    if !trace.notes.isEmpty {
                        ForEach(trace.notes, id: \.self) { note in
                            Text(note)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(Design.spacingSmall)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private var summaryLine: String {
        var parts: [String] = ["Retrieved \(trace.hits.count) passage\(trace.hits.count == 1 ? "" : "s")"]
        var methods: [String] = []
        if trace.semanticEnabled { methods.append("semantic") }
        if trace.keywordEnabled { methods.append("keyword") }
        if !methods.isEmpty { parts.append("via \(methods.joined(separator: " + "))") }
        if trace.rerankEnabled { parts.append("reranked") }
        if trace.webResultCount > 0 { parts.append("+ \(trace.webResultCount) web result\(trace.webResultCount == 1 ? "" : "s")") }
        parts.append("· \(Format.milliseconds(trace.durationMilliseconds))")
        return parts.joined(separator: " ")
    }

    private func scoreLine(_ hit: RetrievalTrace.Hit) -> String {
        var parts: [String] = []
        if hit.semanticScore > 0 { parts.append("semantic \(String(format: "%.2f", hit.semanticScore))") }
        if hit.keywordScore > 0 { parts.append("keyword \(String(format: "%.2f", hit.keywordScore))") }
        if let rerank = hit.rerankScore { parts.append("reranked \(String(format: "%.2f", rerank))") }
        if let page = hit.pageNumber { parts.insert("page \(page)", at: 0) }
        if let heading = hit.headingPath, !heading.isEmpty { parts.append(heading) }
        if let model = hit.embeddingModel { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Message rendering

/// A message with its citations. Answer text is rendered with the citation markers
/// turned into clickable chips that select the source in the inspector.
@MainActor
struct MessageView: View {
    @Environment(AppState.self) private var app
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .assistant:
            assistantMessage
        case .system:
            EmptyView()
        }
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Image(systemName: "person.circle")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.content)
                    .font(Design.answerBody)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.relative(message.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var assistantMessage: some View {
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(message.isError ? Color.red : Color.accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                if message.isError {
                    ErrorCard(
                        title: "This answer could not be generated",
                        message: message.errorMessage ?? "The provider did not return anything.",
                        recovery: message.errorRecovery
                    )
                } else {
                    MarkdownAnswer(text: message.content, citations: message.citations)

                    if !message.citations.isEmpty {
                        CitationList(citations: message.citations)
                    }

                    if let trace = message.retrieval, !trace.hits.isEmpty {
                        RetrievalSummary(trace: trace)
                    }
                }

                footer
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: Design.spacingSmall) {
            if let provider = message.providerID, let model = message.modelName {
                Text("\(providerDisplayName(provider)) · \(model)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let latency = message.latencyMilliseconds {
                Text(Format.milliseconds(latency))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let tokens = message.completionTokens {
                Text("\(Format.tokens(tokens)) tokens out")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !message.isError {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy the answer")

                Button {
                    if let notebookID = app.selectedNotebookID {
                        app.saveNote(NotebookNote(
                            notebookID: notebookID,
                            title: ChatViewModel.sessionTitle(from: message.content),
                            body: noteBody,
                            kind: .manual,
                            sourceIDs: message.citations.compactMap(\.sourceID),
                            providerID: message.providerID,
                            modelName: message.modelName
                        ))
                        app.statusMessage = "Saved to Notes"
                    }
                } label: {
                    Image(systemName: "note.text.badge.plus").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Save this answer as a note")
            }
        }
    }

    private var noteBody: String {
        var body = message.content
        if !message.citations.isEmpty {
            body += "\n\n**Sources**\n"
            for citation in message.citations {
                var line = "- \(citation.marker) \(citation.title)"
                if let page = citation.pageNumber { line += " (page \(page))" }
                if let url = citation.url { line += " — \(url)" }
                body += line + "\n"
            }
        }
        return body
    }

    private func providerDisplayName(_ id: String) -> String {
        app.providers.provider(id: id)?.displayName ?? id
    }
}

/// The answer text, with `[Source N]` markers rendered as clickable links.
///
/// Rendering the answer as one `Text` built from an `AttributedString` — with each
/// marker turned into a link on a private URL scheme — is what makes citations both
/// *clickable* and *correctly wrapped*. A hand-rolled flow layout of text fragments
/// clips any run wider than the column, which is exactly what happens to a real
/// sentence; text layout is not something to reimplement.
@MainActor
struct MarkdownAnswer: View {
    @Environment(AppState.self) private var app
    let text: String
    let citations: [Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.citationScheme,
                  let marker = url.host()?.removingPercentEncoding
                    ?? url.absoluteString.components(separatedBy: "//").last else {
                return .systemAction
            }
            select(marker: marker)
            return .handled
        })
    }

    static let citationScheme = "sourcedesk-citation"

    private func select(marker: String) {
        guard let citation = citations.first(where: { $0.marker == marker }) else { return }
        app.activeCitations = citations
        if let sourceID = citation.sourceID { app.selectedSourceID = sourceID }
        app.section = .sources
    }

    /// Splits the answer into blocks (paragraphs, list items, headings, quotes,
    /// tables and code) then renders each as attributed text.
    private var blocks: [AnswerBlock] { AnswerBlock.parse(text) }

    @ViewBuilder
    private func blockView(_ block: AnswerBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            inlineContent(block)
                .font(.system(size: level <= 2 ? 14 : 13, weight: .semibold))
                .padding(.top, 4)
        case .listItem:
            HStack(alignment: .top, spacing: 7) {
                Text("•").font(Design.answerBody).foregroundStyle(.secondary)
                inlineContent(block)
            }
        case .numberedItem(let number):
            HStack(alignment: .top, spacing: 7) {
                Text("\(number).").font(Design.answerBody).foregroundStyle(.secondary).monospacedDigit()
                inlineContent(block)
            }
        case .quote:
            HStack(alignment: .top, spacing: Design.spacingSmall) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
                inlineContent(block).foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
        case .code:
            Text(block.plainText)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
        case .table:
            TableBlock(rows: block.plainText.components(separatedBy: "\n"))
        case .paragraph:
            inlineContent(block)
        }
    }

    /// One `Text` per block, with markers as links so they wrap and remain clickable.
    private func inlineContent(_ block: AnswerBlock) -> Text {
        Text(block.attributed(citations: citations, scheme: Self.citationScheme))
            .font(Design.answerBody)
    }
}

/// A single citation reference inside answer text.
@MainActor
struct CitationChip: View {
    @Environment(AppState.self) private var app
    let marker: String
    let citation: Citation?

    var body: some View {
        Button {
            if let citation {
                app.activeCitations = [citation]
                if let sourceID = citation.sourceID {
                    app.selectedSourceID = sourceID
                }
                app.section = .sources
            }
        } label: {
            Text(shortLabel)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Design.citationColor(citation?.kind ?? .notebook).opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Design.citationColor(citation?.kind ?? .notebook).opacity(0.3), lineWidth: 0.5)
                )
                .foregroundStyle(citation == nil ? Color.secondary : Design.citationColor(citation!.kind))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var shortLabel: String {
        let digits = marker.filter(\.isNumber)
        return "\(marker.lowercased().contains("web") ? "Web" : "Source") \(digits)"
    }

    private var helpText: String {
        guard let citation else { return "This marker did not resolve to a retrieved passage." }
        var parts = [citation.title]
        if let page = citation.pageNumber { parts.append("page \(page)") }
        if let url = citation.url { parts.append(url) }
        return parts.joined(separator: " · ")
    }
}

/// The citation list under an answer: every source actually used, with its excerpt.
@MainActor
struct CitationList: View {
    @Environment(AppState.self) private var app
    let citations: [Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Sources used")
            ForEach(citations) { citation in
                Button {
                    app.activeCitations = [citation]
                    if let sourceID = citation.sourceID { app.selectedSourceID = sourceID }
                } label: {
                    HStack(alignment: .top, spacing: Design.spacingSmall) {
                        Image(systemName: citation.kind.symbolName)
                            .font(.system(size: 10))
                            .foregroundStyle(Design.citationColor(citation.kind))
                            .frame(width: 14)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(citation.marker)
                                    .font(Design.monoCaption)
                                    .foregroundStyle(Design.citationColor(citation.kind))
                                Text(citation.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                            if !citation.provenance.isEmpty {
                                Text(citation.provenance)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Text(citation.excerpt)
                                .font(Design.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        if citation.url != nil {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Design.spacingSmall)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }
}

/// The in-progress answer, with the current stage named. Streaming is not decoration
/// here: a local model on a long context genuinely takes a while, and saying which
/// stage it is in is the difference between "working" and "hung".
@MainActor
struct StreamingAnswerView: View {
    let text: String
    let reasoning: String
    let stage: AnswerEngine.Stage?

    var body: some View {
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                if text.isEmpty {
                    HStack(spacing: Design.spacingSmall) {
                        ProgressView().controlSize(.small)
                        Text(stage?.displayName ?? "Thinking")
                            .font(Design.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    MarkdownAnswer(text: text, citations: [])
                    if let stage, stage != .generating {
                        Text(stage.displayName)
                            .font(Design.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !reasoning.isEmpty {
                    DisclosureGroup {
                        Text(reasoning)
                            .font(Design.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Model reasoning")
                            .font(Design.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Answer block parsing

/// Splits answer text into renderable blocks. Deliberately small: it understands the
/// subset of Markdown the prompts ask for, and treats anything else as prose.
struct AnswerBlock {
    enum Kind {
        case paragraph
        case heading(level: Int)
        case listItem
        case numberedItem(number: Int)
        case quote
        case code
        case table
    }

    enum Run {
        case text(String)
        case marker(String)
    }

    var kind: Kind
    var runs: [Run]

    var plainText: String {
        runs.map { run in
            switch run {
            case .text(let value): return value
            case .marker(let marker): return marker
            }
        }.joined()
    }

    /// Renders the block as an `AttributedString` in which every citation marker is a
    /// link. SwiftUI lays out a single attributed string correctly — wrapping, line
    /// breaking and selection all behave — while still delivering taps on the marker.
    func attributed(citations: [Citation], scheme: String) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            switch run {
            case .text(let value):
                result.append(AttributedString(value))
            case .marker(let marker):
                var piece = AttributedString(marker)
                let citation = citations.first { $0.marker == marker }
                let tint = Design.citationColor(citation?.kind ?? .notebook)
                piece.foregroundColor = tint
                piece.font = .system(size: 12, weight: .medium)
                // A private scheme keeps this from ever opening a browser.
                if let url = URL(string: "\(scheme)://\(marker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")") {
                    piece.link = url
                }
                result.append(piece)
            }
        }
        return result
    }

    static func parse(_ text: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var tableLines: [String] = []
        var inCode = false

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines = []
            guard !joined.isEmpty else { return }
            blocks.append(AnswerBlock(kind: .paragraph, runs: splitRuns(joined)))
        }

        func flushTable() {
            guard !tableLines.isEmpty else { return }
            blocks.append(AnswerBlock(kind: .table, runs: [.text(tableLines.joined(separator: "\n"))]))
            tableLines = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(AnswerBlock(kind: .code, runs: [.text(codeLines.joined(separator: "\n"))]))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph(); flushTable()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph(); flushTable()
                continue
            }

            if line.hasPrefix("|"), line.hasSuffix("|") {
                flushParagraph()
                // Skip the separator row of a Markdown table.
                let stripped = line.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces)
                if !stripped.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) {
                    tableLines.append(line)
                }
                continue
            }
            if !tableLines.isEmpty { flushTable() }

            if let heading = headingLevel(line) {
                flushParagraph()
                let content = String(line.dropFirst(heading + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                blocks.append(AnswerBlock(kind: .heading(level: heading), runs: splitRuns(Markdownish.stripInlineMarkup(content))))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(AnswerBlock(kind: .quote, runs: splitRuns(Markdownish.stripInlineMarkup(String(line.dropFirst(2))))))
                continue
            }

            if let item = StudyToolsService.parseListItemForDisplay(line) {
                flushParagraph()
                blocks.append(AnswerBlock(kind: item.kind, runs: splitRuns(item.text)))
                continue
            }

            paragraphLines.append(line)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(AnswerBlock(kind: .code, runs: [.text(codeLines.joined(separator: "\n"))]))
        }
        flushParagraph()
        flushTable()
        return blocks
    }

    static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        return level
    }

    /// Splits a line into prose runs and citation markers.
    static func splitRuns(_ text: String) -> [Run] {
        guard let regex = try? NSRegularExpression(pattern: CitationResolver.markerPattern, options: [.caseInsensitive]) else {
            return [.text(text)]
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [.text(text)] }

        var runs: [Run] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let piece = nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !piece.isEmpty { runs.append(.text(piece)) }
            }
            runs.append(.marker(CitationResolver.normalizeMarker(nsText.substring(with: match.range))))
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tail = nsText.substring(from: cursor)
            if !tail.isEmpty { runs.append(.text(tail)) }
        }
        return runs
    }
}

/// Minimal table rendering for Markdown tables in answers.
@MainActor
struct TableBlock: View {
    let rows: [String]

    private var parsed: [[String]] {
        rows.map { row in
            row.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { index, cells in
                HStack(spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: 11.5, weight: index == 0 ? .semibold : .regular))
                            .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                    }
                }
                .background(index == 0 ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                if index < parsed.count - 1 { Divider() }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

/// A flow layout: wraps citation chips onto the next line instead of clipping them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(maxWidth, max(0, widest)), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

extension StudyToolsService {
    /// Shared list-item recognition so answers and notes render the same way.
    static func parseListItemForDisplay(_ line: String) -> (kind: AnswerBlock.Kind, text: String)? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (.listItem, Markdownish.stripInlineMarkup(text))
        }
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber, digits.count < 3 {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
        let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let number = Int(digits) else { return nil }
        return (.numberedItem(number: number), Markdownish.stripInlineMarkup(text))
    }
}

extension Notification.Name {
    static let renameSession = Notification.Name("sourcedesk.renameSession")
}
