import SwiftUI
import SourceDeskCore

/// The left column: notebooks, favourites, recent, and a way into Settings.
@MainActor
struct SidebarView: View {
    @Environment(AppState.self) private var app

    let onAddWebsite: () -> Void
    let onAddFiles: () -> Void
    let onAddPastedText: () -> Void

    @State private var searchText = ""
    @State private var renamingNotebookID: RecordID?
    @State private var renameText = ""
    @State private var deleteCandidate: Notebook?

    private var filteredNotebooks: [Notebook] {
        guard !searchText.isEmpty else { return app.notebooks }
        return app.notebooks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.summary.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var favourites: [Notebook] { filteredNotebooks.filter(\.isFavorite) }

    private var recent: [Notebook] {
        filteredNotebooks
            .filter { !$0.isFavorite }
            .sorted { ($0.lastOpenedAt ?? $0.updatedAt) > ($1.lastOpenedAt ?? $1.updatedAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                if !favourites.isEmpty {
                    Section {
                        ForEach(favourites) { notebook in row(notebook) }
                    } header: {
                        SectionHeader("Favorites")
                    }
                }

                Section {
                    if recent.isEmpty && favourites.isEmpty {
                        Text(searchText.isEmpty ? "No notebooks yet" : "No matches")
                            .font(Design.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(recent) { notebook in row(notebook) }
                    }
                } header: {
                    SectionHeader(favourites.isEmpty ? "Notebooks" : "All Notebooks")
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Filter notebooks")

            Divider()

            VStack(spacing: 2) {
                Button {
                    app.createNotebook(title: "Untitled notebook")
                } label: {
                    Label("New Notebook", systemImage: "plus")
                        .font(Design.rowTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .help("Create a notebook (⇧⌘N)")

                Menu {
                    Button("Add Website…", action: onAddWebsite)
                    Button("Add Files…", action: onAddFiles)
                    Button("Paste Text…", action: onAddPastedText)
                } label: {
                    Label("Add Sources…", systemImage: "tray.and.arrow.down")
                        .font(Design.rowTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .font(Design.rowTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .padding(.bottom, 8)
            }
            .padding(.top, 6)
        }
        .background(.thinMaterial)
        .alert("Delete notebook?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
            Button("Delete", role: .destructive) {
                if let notebook = deleteCandidate { app.deleteNotebook(notebook.id) }
                deleteCandidate = nil
            }
        } message: {
            Text("“\(deleteCandidate?.title ?? "")” and all of its sources, conversations and notes will be removed from this Mac. This cannot be undone.")
        }
    }

    private var selectionBinding: Binding<RecordID?> {
        Binding(
            get: { app.selectedNotebookID },
            set: { value in if let value { app.selectNotebook(value) } }
        )
    }

    @ViewBuilder
    private func row(_ notebook: Notebook) -> some View {
        NotebookRow(
            notebook: notebook,
            sourceCount: notebook.id == app.selectedNotebookID ? app.sources.count : nil,
            isRenaming: renamingNotebookID == notebook.id,
            renameText: $renameText,
            onCommitRename: {
                app.renameNotebook(notebook, to: renameText)
                renamingNotebookID = nil
            },
            onCancelRename: { renamingNotebookID = nil }
        )
        .tag(notebook.id)
        .contextMenu {
            Button("Rename…") {
                renameText = notebook.title
                renamingNotebookID = notebook.id
            }
            Button(notebook.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                app.toggleFavorite(notebook)
            }
            Divider()
            Button("Export…") {
                app.selectedNotebookID = notebook.id
                NotificationCenter.default.post(name: .exportNotebook, object: nil)
            }
            Divider()
            Button("Delete", role: .destructive) { deleteCandidate = notebook }
        }
    }
}

/// A notebook row: title, and a one-line summary of what it holds.
private struct NotebookRow: View {
    let notebook: Notebook
    let sourceCount: Int?
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        HStack(spacing: Design.spacingSmall) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Design.accent(forIndex: notebook.accentIndex))
                .frame(width: 3, height: 26)
                .opacity(0.75)

            if isRenaming {
                TextField("Notebook name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.rowTitle)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(notebook.title)
                            .font(Design.rowTitle)
                            .lineLimit(1)
                        if notebook.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                    }
                    Text(subtitle)
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let sourceCount {
            parts.append("\(sourceCount) source\(sourceCount == 1 ? "" : "s")")
        } else if let opened = notebook.lastOpenedAt {
            parts.append(Format.relative(opened))
        } else {
            parts.append(Format.relative(notebook.updatedAt))
        }
        if !notebook.summary.isEmpty {
            parts.append(notebook.summary)
        }
        return parts.joined(separator: " · ")
    }
}
