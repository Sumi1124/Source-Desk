import SwiftUI
import SourceDeskCore

/// The ⌘K command palette.
///
/// It searches across the things a research tool actually needs to reach quickly:
/// notebooks, sources, sessions and notes in the current notebook, plus every
/// command. Results are ranked so an exact notebook-name match never loses to a
/// fuzzy command match.
struct CommandPaletteView: View {
    @Environment(AppState.self) private var app

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { app.commandPaletteVisible = false }

            VStack(spacing: 0) {
                HStack(spacing: Design.spacingSmall) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search notebooks, sources, notes, or run a command…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($fieldFocused)
                        .onSubmit { run(selectedItem) }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Design.spacingMedium)
                .padding(.vertical, 12)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isSelected: index == selection) {
                                    run(item)
                                }
                                .id(index)
                            }
                            if items.isEmpty {
                                VStack(spacing: 4) {
                                    Text("No matches")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Try a notebook name, a source title, or a command like “export”.")
                                        .font(Design.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(Design.spacingLarge)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { _, value in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(value, anchor: .center) }
                    }
                }

                Divider()
                HStack(spacing: Design.spacingMedium) {
                    hint("↑↓", "navigate")
                    hint("↩", "open")
                    hint("esc", "dismiss")
                    Spacer()
                    Text("\(items.count) result\(items.count == 1 ? "" : "s")")
                        .font(Design.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Design.spacingMedium)
                .padding(.vertical, 7)
            }
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { fieldFocused = true }
        .onExitCommand { app.commandPaletteVisible = false }
        .onKeyPress(.downArrow) {
            selection = min(items.count - 1, selection + 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(0, selection - 1)
            return .handled
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .controlBackgroundColor)))
            Text(label).font(Design.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Items

    struct Item: Identifiable {
        enum Kind {
            case notebook(Notebook)
            case source(Source)
            case session(ChatSession)
            case note(NotebookNote)
            case command(Command)
        }
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let kind: Kind
        let score: Int
    }

    struct Command {
        let title: String
        let symbol: String
        let action: () -> Void
    }

    private var items: [Item] {
        var results: [Item] = []

        for notebook in app.notebooks {
            let score = matchScore(notebook.title, query, base: 100)
            guard score > 0 else { continue }
            results.append(Item(id: "nb-\(notebook.id)", title: notebook.title,
                                subtitle: notebook.isFavorite ? "Notebook · favorite" : "Notebook",
                                symbol: "book.closed", kind: .notebook(notebook), score: score))
        }

        for source in app.sources {
            let haystack = source.title + " " + (source.url ?? "")
            let score = matchScore(haystack, query, base: 70)
            guard score > 0 else { continue }
            results.append(Item(id: "src-\(source.id)", title: source.title,
                                subtitle: "Source · \(source.displaySubtitle)",
                                symbol: source.kind.symbolName, kind: .source(source), score: score))
        }

        for note in app.notes {
            let score = matchScore(note.title + " " + note.body, query, base: 60)
            guard score > 0 else { continue }
            results.append(Item(id: "note-\(note.id)", title: note.title,
                                subtitle: "Note · \(note.kind.displayName)",
                                symbol: note.kind.symbolName, kind: .note(note), score: score))
        }

        for session in app.sessions {
            let score = matchScore(session.title, query, base: 50)
            guard score > 0 else { continue }
            results.append(Item(id: "sess-\(session.id)", title: session.title,
                                subtitle: "Session · \(session.scope.shortName)",
                                symbol: "bubble.left.and.text.bubble.right", kind: .session(session), score: score))
        }

        for command in commands {
            // Commands score lower than content, but are always reachable.
            let score = query.isEmpty ? 10 : matchScore(command.title, query, base: 40)
            guard score > 0 || query.isEmpty else { continue }
            results.append(Item(id: "cmd-\(command.title)", title: command.title,
                                subtitle: "Command", symbol: command.symbol,
                                kind: .command(command), score: score))
        }

        return results.sorted { $0.score > $1.score }.prefix(40).map { $0 }
    }

    /// A simple, predictable score: prefix matches beat word matches, which beat
    /// substring matches. An empty query returns everything at its base score.
    private func matchScore(_ haystack: String, _ needle: String, base: Int) -> Int {
        guard !needle.isEmpty else { return base }
        let hay = haystack.lowercased()
        let pin = needle.lowercased()
        if hay.hasPrefix(pin) { return base + 60 }
        if hay.contains(" \(pin)") { return base + 40 }
        if hay.contains(pin) { return base + 25 }
        // All words present in any order.
        let words = pin.split(separator: " ").map(String.init)
        if words.count > 1, words.allSatisfy({ hay.contains($0) }) { return base + 10 }
        return 0
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(title: "New Notebook", symbol: "plus.rectangle.on.folder") {
                app.createNotebook(title: "Untitled notebook")
            },
            Command(title: "New Session", symbol: "square.and.pencil") {
                _ = app.createSession()
            },
            Command(title: "New Note", symbol: "note.text") {
                _ = app.createNote()
            },
            Command(title: "Add Website…", symbol: "globe") {
                NotificationCenter.default.post(name: .addWebsite, object: nil)
            },
            Command(title: "Add Files…", symbol: "doc.badge.plus") {
                NotificationCenter.default.post(name: .addFiles, object: nil)
            },
            Command(title: "Paste Text…", symbol: "doc.on.clipboard") {
                NotificationCenter.default.post(name: .addPastedText, object: nil)
            },
            Command(title: "Export Notebook…", symbol: "square.and.arrow.up") {
                NotificationCenter.default.post(name: .exportNotebook, object: nil)
            },
            Command(title: "Import Notebook…", symbol: "square.and.arrow.down") {
                NotificationCenter.default.post(name: .importNotebook, object: nil)
            },
            Command(title: "Refresh Model Lists", symbol: "arrow.clockwise") {
                Task { await app.refreshAllModels() }
            },
            Command(title: "Research & Add Sources…", symbol: "magnifyingglass.circle") {
                app.requestResearch(kind: .addSources)
            },
            Command(title: "Research & Create Note…", symbol: "note.text.badge.plus") {
                app.requestResearch(kind: .createNote)
            },
            Command(title: "Go to Research", symbol: "bubble.left.and.text.bubble.right") { app.section = .research },
            Command(title: "Go to Sources", symbol: "doc.on.doc") { app.section = .sources },
            Command(title: "Go to Notes", symbol: "note.text") { app.section = .notes },
            Command(title: "Go to Study Tools", symbol: "graduationcap") { app.section = .studyTools },
            Command(title: "Go to Search", symbol: "magnifyingglass") { app.section = .search },
        ]

        list.append(Command(title: app.settings.localOnlyMode ? "Turn Off Local-Only Mode" : "Turn On Local-Only Mode",
                            symbol: "lock") {
            app.updateSettings { $0.localOnlyMode.toggle() }
        })
        list.append(Command(title: app.settings.showInspector ? "Hide Inspector" : "Show Inspector",
                            symbol: "sidebar.right") {
            app.updateSettings { $0.showInspector.toggle() }
        })
        for engine in SearchEngine.allCases where engine != .none {
            list.append(Command(title: "Use \(engine.displayName) for Web Search", symbol: "globe") {
                app.updateSettings { $0.searchEngine = engine }
            })
        }
        for provider in app.providers.all {
            list.append(Command(title: "Switch to \(provider.displayName)", symbol: provider.isLocal ? "desktopcomputer" : "cloud") {
                app.updateSettings { $0.preferredProviderID = provider.identifier }
                Task { await app.loadModels(for: provider.identifier) }
            })
        }
        return list
    }

    private var selectedItem: Item? {
        items.indices.contains(selection) ? items[selection] : items.first
    }

    private func run(_ item: Item?) {
        guard let item else { return }
        switch item.kind {
        case .notebook(let notebook):
            app.selectNotebook(notebook.id)
        case .source(let source):
            app.selectedSourceID = source.id
            app.section = .sources
        case .note(let note):
            app.selectedNoteID = note.id
            app.section = .notes
        case .session(let session):
            app.selectedSessionID = session.id
            app.section = .research
        case .command(let command):
            command.action()
        }
        app.commandPaletteVisible = false
    }
}

private struct PaletteRow: View {
    let item: CommandPaletteView.Item
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.spacingSmall) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.spacingMedium)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}