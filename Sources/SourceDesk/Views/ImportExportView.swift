import SwiftUI
import SourceDeskCore

/// Notebook export, with a preview of exactly what will be written.
struct ExportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var includeOriginals = true
    @State private var includeEmbeddings = true
    @State private var includeMarkdown = true
    @State private var isExporting = false
    @State private var progress = 0.0
    @State private var result: NotebookArchive.ExportResult?
    @State private var error: AppState.PresentedError?

    private var notebook: Notebook? { app.selectedNotebook }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingMedium) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export notebook")
                    .font(.system(size: 15, weight: .semibold))
                Text("Exports to an open, documented archive: a plain zip you can open with any tool. API keys and application settings are never included.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notebook {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader("Contents")
                    DetailRow(label: "Notebook", value: notebook.title)
                    DetailRow(label: "Sources", value: "\(app.sources.count) sources · \(Format.count(app.sources.reduce(0) { $0 + $1.chunkCount })) passages")
                    DetailRow(label: "Conversations", value: "\(app.sessions.count) session\(app.sessions.count == 1 ? "" : "s")")
                    DetailRow(label: "Notes", value: "\(app.notes.count)")
                    DetailRow(label: "Stored text", value: Format.bytes(app.sources.reduce(0) { $0 + $1.plainTextBytes }))
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Options")
                    Toggle("Include original downloaded files", isOn: $includeOriginals)
                    Toggle("Include stored vectors (skips re-embedding on import)", isOn: $includeEmbeddings)
                    Toggle("Include readable Markdown copies of chats and notes", isOn: $includeMarkdown)
                }

                VStack(alignment: .leading, spacing: 3) {
                    SectionHeader("Archive layout")
                    Text("""
                    \(NotebookArchive.sanitize(notebook.title))/
                      notebook.json          notebook, sources, sessions, notes
                      sources/<id>/          content.txt, original files
                      chats/*.md             readable transcripts
                      notes/*.md             readable notes
                      embeddings/*.jsonl     optional vectors
                    """)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                if isExporting {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }

                if let result {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Exported \(Format.bytes(result.byteCount))", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                        Text(app.paths.displayPath(result.url))
                            .font(Design.monoCaption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if let error {
                    ErrorCard(title: error.title, message: error.message, recovery: error.recovery) { self.error = nil }
                }
            } else {
                Text("Select a notebook first.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                if let result {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.url])
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Choose Location and Export…") { beginExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(notebook == nil || isExporting)
            }
        }
        .padding(Design.spacingLarge)
        .frame(width: 620, height: 560)
    }

    private func beginExport() {
        guard let notebook, let store = app.store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(NotebookArchive.sanitize(notebook.title)).\(NotebookArchive.fileExtension)"
        panel.title = "Export notebook"
        panel.message = "Save the notebook archive."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        result = nil
        progress = 0
        let options = NotebookArchive.ExportOptions(
            includeOriginalFiles: includeOriginals,
            includeEmbeddings: includeEmbeddings,
            includeMarkdownCopies: includeMarkdown
        )

        Task {
            do {
                let outcome = try NotebookArchive.export(
                    notebookID: notebook.id,
                    from: store,
                    to: destination,
                    options: options
                ) { value in
                    Task { @MainActor in self.progress = value }
                }
                result = outcome
                app.statusMessage = "Exported “\(notebook.title)” · \(Format.bytes(outcome.byteCount))"
            } catch let err as SourceDeskError {
                error = AppState.PresentedError(err)
            } catch {
                self.error = AppState.PresentedError(title: "Export failed", message: error.localizedDescription)
            }
            isExporting = false
        }
    }
}

/// Notebook import, with a preview of the archive before anything is written.
struct ImportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var archiveURL: URL?
    @State private var manifest: NotebookArchive.Manifest?
    @State private var isImporting = false
    @State private var progress = 0.0
    @State private var result: NotebookArchive.ImportResult?
    @State private var error: AppState.PresentedError?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingMedium) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import notebook")
                    .font(.system(size: 15, weight: .semibold))
                Text("Importing always creates a new notebook with its own identity, so importing twice never overwrites existing work.")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Choose a .nbk Archive…") { chooseFile() }

            if let archiveURL {
                Text(app.paths.displayPath(archiveURL))
                    .font(Design.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let manifest {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader("Archive contents")
                    DetailRow(label: "Notebook", value: manifest.notebook.title)
                    DetailRow(label: "Exported", value: Format.shortDate(manifest.exportedAt))
                    DetailRow(label: "By", value: manifest.generator)
                    DetailRow(label: "Sources", value: "\(manifest.counts.sources)")
                    DetailRow(label: "Passages", value: Format.count(manifest.counts.chunks))
                    DetailRow(label: "Vectors", value: Format.count(manifest.counts.embeddings))
                    DetailRow(label: "Conversations", value: "\(manifest.counts.sessions) · \(manifest.counts.messages) messages")
                    DetailRow(label: "Notes", value: "\(manifest.counts.notes)")
                    if !manifest.embeddingModels.isEmpty {
                        DetailRow(label: "Embedding models", value: manifest.embeddingModels.joined(separator: ", "))
                    }
                }
            }

            if isImporting {
                ProgressView(value: progress).progressViewStyle(.linear)
                Text("Restoring sources, passages, conversations and notes…")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }

            if let result {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Imported “\(result.notebook.title)”", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                    DetailRow(label: "Sources", value: "\(result.sourceCount)")
                    DetailRow(label: "Passages", value: Format.count(result.chunkCount))
                    DetailRow(label: "Messages", value: "\(result.messageCount)")
                    if !result.skipped.isEmpty {
                        SectionHeader("Not restored")
                        ForEach(result.skipped, id: \.title) { item in
                            Text("\(item.title): \(item.reason)")
                                .font(Design.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let error {
                ErrorCard(title: error.title, message: error.message, recovery: error.recovery) { self.error = nil }
            }

            Spacer()

            HStack {
                if result != nil {
                    Button("Open It") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Import") {
                    performImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(archiveURL == nil || manifest == nil || isImporting)
            }
        }
        .padding(Design.spacingLarge)
        .frame(width: 620, height: 560)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import notebook"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveURL = url
        error = nil
        result = nil
        do {
            manifest = try NotebookArchive.inspect(url)
        } catch let err as SourceDeskError {
            manifest = nil
            error = AppState.PresentedError(err)
        } catch {
            manifest = nil
            self.error = AppState.PresentedError(title: "Couldn't read that archive", message: error.localizedDescription)
        }
    }

    private func performImport() {
        guard let url = archiveURL, let store = app.store else { return }
        isImporting = true
        progress = 0
        error = nil
        Task {
            do {
                let outcome = try NotebookArchive.import(from: url, into: store) { value in
                    Task { @MainActor in self.progress = value }
                }
                result = outcome
                app.reloadAll()
                app.selectNotebook(outcome.notebook.id)
                app.statusMessage = "Imported “\(outcome.notebook.title)” · \(outcome.sourceCount) sources"
            } catch let err as SourceDeskError {
                error = AppState.PresentedError(err)
            } catch {
                self.error = AppState.PresentedError(title: "Import failed", message: error.localizedDescription)
            }
            isImporting = false
        }
    }
}
