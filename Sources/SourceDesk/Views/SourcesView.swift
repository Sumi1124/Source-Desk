import SwiftUI
import SourceDeskCore

/// Source management: what is in this notebook, what state each source is in, and
/// what to do about the ones that failed.
struct SourcesView: View {
    @Environment(AppState.self) private var app

    let onAddWebsite: () -> Void
    let onAddFiles: () -> Void
    let onAddPastedText: () -> Void

    @State private var filter = Filter.all
    @State private var searchText = ""
    @State private var sortOrder = SortOrder.added
    @State private var confirmDeleteAll = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, ready, issues, excluded
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: return "All"
            case .ready: return "Ready"
            case .issues: return "Needs attention"
            case .excluded: return "Excluded"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case added, title, size, passages
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .added: return "Date added"
            case .title: return "Title"
            case .size: return "Size"
            case .passages: return "Passages"
            }
        }
    }

    private var visibleSources: [Source] {
        var list = app.sources
        switch filter {
        case .all: break
        case .ready: list = list.filter { $0.status == .ready || $0.status == .partial }
        case .issues: list = list.filter { $0.status == .failed || $0.status == .partial || $0.status.isBusy }
        case .excluded: list = list.filter { !$0.includeInRetrieval }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || ($0.url ?? "").localizedCaseInsensitiveContains(searchText)
                    || $0.notes.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOrder {
        case .added: list.sort { $0.addedAt > $1.addedAt }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .size: list.sort { $0.plainTextBytes > $1.plainTextBytes }
        case .passages: list.sort { $0.chunkCount > $1.chunkCount }
        }
        return list
    }

    private var totalBytes: Int64 { app.sources.reduce(0) { $0 + $1.plainTextBytes } }
    private var totalPassages: Int { app.sources.reduce(0) { $0 + $1.chunkCount } }
    private var issueCount: Int { app.sources.filter { $0.status == .failed }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if app.sources.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: "No sources in this notebook",
                    message: "Add websites, PDFs, documents or pasted text. There is no limit on how many — add as much as your disk allows.",
                    primaryAction: ("Add a Website", onAddWebsite),
                    secondaryAction: ("Add Files", onAddFiles),
                    footnote: "You can also paste text, or drop files onto this window."
                )
            } else {
                List(selection: sourceSelection) {
                    if issueCount > 0 && filter != .issues {
                        Section {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                Text("\(issueCount) source\(issueCount == 1 ? "" : "s") could not be added.")
                                    .font(Design.caption)
                                Button("Show") { filter = .issues }
                                    .buttonStyle(.link)
                                    .font(Design.caption)
                            }
                        }
                    }

                    ForEach(visibleSources) { source in
                        SourceRow(source: source)
                            .tag(source.id)
                            .contextMenu { contextMenu(for: source) }
                    }
                }
                .listStyle(.inset)

                if visibleSources.isEmpty {
                    EmptyStateView(
                        symbol: "line.3.horizontal.decrease.circle",
                        title: "Nothing matches",
                        message: "No sources match “\(searchText)” with the \(filter.displayName.lowercased()) filter.",
                        primaryAction: ("Clear Filters", {
                            searchText = ""
                            filter = .all
                        })
                    )
                }
            }
        }
        .confirmationDialog("Remove all sources?", isPresented: $confirmDeleteAll) {
            Button("Remove all \(app.sources.count) sources", role: .destructive) {
                app.deleteAllSources()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The extracted text, stored files and passages for every source in this notebook will be deleted from this Mac. The notebook, its chats and its notes stay.")
        }
    }

    private var header: some View {
        HStack(spacing: Design.spacingSmall) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sources")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(app.sources.count) source\(app.sources.count == 1 ? "" : "s") · \(Format.count(totalPassages)) passages · \(Format.bytes(totalBytes)) of text")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Design.spacingSmall)

            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)

            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)

            Menu {
                Button("Add Website…", action: onAddWebsite)
                Button("Add Files…", action: onAddFiles)
                Button("Import Folder…", action: onAddFiles)
                Button("Paste Text…", action: onAddPastedText)
                Divider()
                Button("Remove All Sources…", role: .destructive) { confirmDeleteAll = true }
                    .disabled(app.sources.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, Design.spacingMedium)
        .padding(.vertical, Design.spacingSmall)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search sources")
    }

    private var sourceSelection: Binding<RecordID?> {
        Binding(
            get: { app.selectedSourceID },
            set: { app.selectedSourceID = $0 }
        )
    }

    @ViewBuilder
    private func contextMenu(for source: Source) -> some View {
        if let url = source.url {
            Button("Open in Browser") {
                if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            }
            Button("Refresh from the web") { app.refreshSource(source) }
            Divider()
        }
        Button("Re-index (re-chunk and re-embed)") { app.reindexSource(source.id) }
        Button(source.includeInRetrieval ? "Exclude from answers" : "Include in answers") {
            app.toggleSourceInRetrieval(source)
        }
        if let path = source.filePath {
            Button("Reveal Original File") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Button("Reveal Stored Text") {
            if let path = source.contentPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Divider()
        Button("Delete Source", role: .destructive) { app.deleteSource(source.id) }
    }
}

/// One source row: title, provenance, size, status.
struct SourceRow: View {
    @Environment(AppState.self) private var app
    let source: Source

    var body: some View {
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Image(systemName: source.kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(source.includeInRetrieval ? .secondary : .tertiary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(source.title)
                        .font(Design.rowTitle)
                        .lineLimit(1)
                        .foregroundStyle(source.includeInRetrieval ? .primary : .secondary)
                    if !source.includeInRetrieval {
                        StatusPill(text: "excluded", color: .secondary, symbol: "eye.slash")
                    }
                }

                HStack(spacing: 6) {
                    Text(source.displaySubtitle)
                    if app.settings.showSourceWordCounts && source.chunkCount > 0 {
                        Text("·")
                        Text("\(source.chunkCount) passages")
                    }
                    if source.plainTextBytes > 0 {
                        Text("·")
                        Text(Format.bytes(source.plainTextBytes))
                    }
                }
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if source.url != nil {
                    Text(source.url ?? "")
                        .font(Design.monoCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let error = source.errorMessage {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(Design.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                if source.status.isBusy {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(source.status.displayName)
                            .font(Design.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    StatusPill(text: source.status.displayName, color: Design.statusColor(source.status))
                }
                Text(Format.relative(source.addedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - Add sheets

/// Website ingest sheet. Shows the URL, an optional title override, and — before
/// anything is fetched — what will happen to the page.
struct AddWebsiteSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let onAdd: (String, String?) -> Void

    /// Two ways in: paste an address, or describe what you want and let the search plus
    /// the selected AI find candidate pages. The second exists because "I want sources
    /// about X" is the actual starting point for research, and asking the user to go and
    /// find URLs first puts the work back on them.
    private enum Mode: String, CaseIterable {
        case address
        case topic

        var label: String { self == .address ? "Address" : "Find by topic" }
    }

    @State private var mode: Mode = .address
    @State private var urlText = ""
    @State private var titleText = ""
    @State private var urlPreview: URLPreview?
    @State private var topicText = ""
    @State private var keepCount = 4
    /// Which of the AI's picks the user has left ticked.
    @State private var approved: Set<String> = []

    private struct URLPreview {
        var host: String
        var path: String
        var isDuplicate: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingMedium) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a website")
                    .font(.system(size: 15, weight: .semibold))
                Text(mode == .address
                     ? "SourceDesk downloads the page, extracts the readable text, and stores it on this Mac."
                     : "Describe a topic. DuckDuckGo finds candidates, your selected AI model chooses the useful ones, and SourceDesk downloads what you approve.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .topic {
                topicModeContent
            } else {
                addressModeContent
            }
        }
        .padding(Design.spacingLarge)
        .frame(width: 580)
        .onChange(of: urlText) { _, _ in updatePreview() }
        .onChange(of: mode) { _, _ in
            // Switching modes abandons a half-finished discovery so the two cannot be
            // mistaken for one another.
            app.cancelDiscovery()
            app.discoveryPlan = nil
            approved = []
        }
        .onAppear { updatePreview() }
    }

    // MARK: Address mode

    @ViewBuilder
    private var addressModeContent: some View {
        LabelledField(label: "Address", help: "A full http:// or https:// address.") {
            TextField("https://example.com/article", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
        }

        LabelledField(label: "Title (optional)", help: "Leave empty to use the page's own title.") {
            TextField("Title", text: $titleText)
                .textFieldStyle(.roundedBorder)
        }

        if let preview = urlPreview {
            VStack(alignment: .leading, spacing: 4) {
                if preview.isDuplicate {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("Already in this notebook — re-adding refreshes the stored copy.")
                            .font(Design.caption)
                            .foregroundStyle(.orange)
                    }
                }
                DetailRow(label: "Host", value: preview.host)
                if !preview.path.isEmpty {
                    DetailRow(label: "Path", value: preview.path, monospaced: true)
                }
            }
            .padding(Design.spacingSmall)
            .background(RoundedRectangle(cornerRadius: Design.rowCornerRadius).fill(Color(nsColor: .controlBackgroundColor)))
        }

        VStack(alignment: .leading, spacing: 4) {
            Label("The page is fetched once, now, and stored locally.", systemImage: "checkmark.circle")
            Label("robots.txt is respected; a site that refuses automated access is reported, not bypassed.", systemImage: "hand.raised")
            Label("Sign-in and paywalled pages cannot be read — save those as a PDF and import the file.", systemImage: "lock")
        }
        .font(Design.caption)
        .foregroundStyle(.secondary)

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Add Website") { add() }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Find-by-topic mode

    @ViewBuilder
    private var topicModeContent: some View {
        if let reason = app.discoveryUnavailableReason {
            // Say what is missing *before* the user types a topic, rather than letting them
            // press the button and get a failure.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }

        LabelledField(label: "Topic", help: "What you want sources about.") {
            TextField("e.g. \"causes of the industrial decline\"", text: $topicText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { plan() }
        }

        HStack(spacing: Design.spacingSmall) {
            Text("Results to keep")
                .font(Design.caption)
                .foregroundStyle(.secondary)
            Picker("Results to keep", selection: $keepCount) {
                ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)
            Text("the AI picks this many from the search results")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if app.discoveryPlan != nil {
                Button("Search Again") { plan() }
                    .controlSize(.small)
            }
        }

        progressSection
        planSection

        VStack(alignment: .leading, spacing: 4) {
            Label("Searching uses DuckDuckGo, which needs no key.", systemImage: "magnifyingglass")
            Label("Your topic and the search result titles are sent to \(app.currentProvider?.displayName ?? "your model") so it can choose between them.", systemImage: "sparkles")
            Label("Nothing is downloaded until you approve a result.", systemImage: "checkmark.circle")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)

        HStack {
            Spacer()
            Button("Cancel") {
                app.cancelDiscovery()
                dismiss()
            }
            Button(planButtonTitle) { plan() }
                .disabled(topicText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || app.discoveryUnavailableReason != nil
                          || isWorking)
            Button("Add \(approved.count) Selected") { addSelected() }
                .buttonStyle(.borderedProminent)
                .disabled(approved.isEmpty || isWorking)
        }
    }

    private var isWorking: Bool {
        switch app.discoveryPhase {
        case .searching, .askingAI, .fetching: return true
        case .idle, .planning, .done: return false
        }
    }

    private var planButtonTitle: String {
        switch app.discoveryPhase {
        case .planning, .done: return "Search Again"
        default: return "Find Sources"
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        switch app.discoveryPhase {
        case .idle:
            EmptyView()
        case .fetching(let index, let total, let title):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Design.spacingSmall) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(index) of \(total)").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Cancel") { app.cancelDiscovery() }.controlSize(.small)
                }
                Text(title).font(Design.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: Double(index - 1), total: Double(max(1, total)))
                    .progressViewStyle(.linear)
            }
            .padding(Design.spacingSmall)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        default:
            HStack(spacing: Design.spacingSmall) {
                ProgressView().controlSize(.small)
                Text(app.discoveryPhase.label).font(.system(size: 11))
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var planSection: some View {
        if let plan = app.discoveryPlan {
            VStack(alignment: .leading, spacing: 6) {
                if let notice = plan.aiNotice {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(notice)
                            .font(Design.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if plan.keptCount > 0 {
                    Text("The model chose these \(plan.keptCount) from \(plan.searchedCount) results.")
                        .font(.system(size: 11, weight: .medium))
                }

                if plan.queryWasRewritten {
                    Text("Searched for “\(plan.query)”")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                if plan.selections.isEmpty {
                    Text("Nothing was selected. Try different wording.")
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(plan.selections, id: \.result.id) { selection in
                                resultRow(selection)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ selection: SourceDiscoveryService.Selection) -> some View {
        let isOn = approved.contains(selection.result.url)
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { value in
                    if value { approved.insert(selection.result.url) }
                    else { approved.remove(selection.result.url) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(selection.result.title.isEmpty ? selection.result.url : selection.result.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                Text(selection.result.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reason = selection.reason {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(.tint)
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.spacingSmall)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func updatePreview() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host(), !host.isEmpty else {
            urlPreview = nil
            return
        }
        let isDuplicate = app.sources.contains { $0.url == trimmed }
        urlPreview = URLPreview(host: host, path: url.path, isDuplicate: isDuplicate)
    }

    private func add() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(trimmed, title.isEmpty ? nil : title)
        dismiss()
    }

    private func plan() {
        let trimmed = topicText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        approved = []
        app.planSources(topic: trimmed, keep: keepCount)
    }

    private func addSelected() {
        guard let plan = app.discoveryPlan else { return }
        let chosen = plan.selections
            .filter { approved.contains($0.result.url) }
            .map(\.result)
        guard !chosen.isEmpty else { return }
        // The sheet stays open so progress is visible; it closes with Cancel/Close once
        // the download reports finished.
        app.addPlannedSources(chosen)
    }
}

/// Paste text sheet. This is the escape hatch for any page the app legitimately
/// cannot fetch, and it is why "JavaScript-only page" is not a dead end.
struct AddPastedTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String, String) -> Void

    @State private var title = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingMedium) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste text")
                    .font(.system(size: 15, weight: .semibold))
                Text("Everything you paste is stored on this Mac and treated as a source with the same citations as any other.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabelledField(label: "Title") {
                TextField("Notes, an article, a transcript…", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            LabelledField(label: "Text", help: "Markdown headings and lists are detected, so structure survives into citations.") {
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .frame(minHeight: 220)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }

            HStack {
                Text("\(TextMath.wordCount(text)) words")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Text") {
                    onAdd(title.trimmingCharacters(in: .whitespacesAndNewlines), text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
            }
        }
        .padding(Design.spacingLarge)
        .frame(width: 620, height: 500)
    }
}
