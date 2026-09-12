import SwiftUI
import SourceDeskCore

/// Notes: manual notes plus everything the study tools produced, with the
/// flashcard and quiz renderers for structured material.
@MainActor
struct NotesView: View {
    @Environment(AppState.self) private var app

    @State private var selectedNoteID: RecordID?
    @State private var searchText = ""
    @State private var kindFilter: NoteKind?
    @State private var editorBody = ""
    @State private var editorTitle = ""
    @State private var isEditing = false
    @State private var flashcardIndex = 0
    @State private var revealedCards: Set<RecordID> = []
    @State private var quizAnswers: [RecordID: Int] = [:]

    private var visibleNotes: [NotebookNote] {
        var list = app.notes
        if let kindFilter { list = list.filter { $0.kind == kindFilter } }
        if !searchText.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || $0.body.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    private var selectedNote: NotebookNote? {
        visibleNotes.first { $0.id == selectedNoteID } ?? app.notes.first { $0.id == selectedNoteID }
    }

    var body: some View {
        HSplitView {
            noteList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            Group {
                if let note = selectedNote {
                    noteDetail(note)
                } else if app.notes.isEmpty {
                    EmptyStateView(
                        symbol: "note.text",
                        title: "No notes yet",
                        message: "Notes hold your own writing and everything the study tools produce. Generate a summary or a quiz, or write a note by hand.",
                        primaryAction: ("New Note", { createNote() }),
                        secondaryAction: ("Open Study Tools", { app.section = .studyTools })
                    )
                } else {
                    EmptyStateView(
                        symbol: "sidebar.left",
                        title: "Nothing selected",
                        message: "Choose a note from the list to read it."
                    )
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: List

    private var noteList: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.spacingSmall) {
                Menu {
                    Button("All notes") { kindFilter = nil }
                    Divider()
                    ForEach(NoteKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) { kindFilter = kind }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: kindFilter?.symbolName ?? "line.3.horizontal.decrease")
                            .font(.system(size: 10))
                        Text(kindFilter?.displayName ?? "All notes")
                            .font(Design.caption)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Text("\(app.notes.count)")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)

                Button {
                    createNote()
                } label: {
                    Image(systemName: "plus").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("New note")
            }
            .padding(.horizontal, Design.spacingSmall)
            .padding(.vertical, 6)

            Divider()

            List(selection: $selectedNoteID) {
                ForEach(visibleNotes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: note.kind.symbolName)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(note.title)
                                .font(Design.rowTitle)
                                .lineLimit(2)
                        }
                        HStack(spacing: 5) {
                            Text(note.kind == .manual ? "Note" : note.kind.displayName)
                            Text("·")
                            Text(Format.relative(note.updatedAt))
                        }
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                        Text(TextMath.preview(note.body, limit: 90))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(note.id)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note.body, forType: .string)
                        }
                        Button(note.isPinned ? "Unpin" : "Pin") {
                            var copy = note
                            copy.isPinned.toggle()
                            app.saveNote(copy)
                        }
                        Button("Delete", role: .destructive) { app.deleteNote(note.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes")
        }
    }

    private func createNote() {
        if let note = app.createNote() {
            selectedNoteID = note.id
            editorTitle = note.title
            editorBody = note.body
            isEditing = true
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func noteDetail(_ note: NotebookNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.spacingSmall) {
                if isEditing {
                    TextField("Title", text: $editorTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Text(note.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Design.spacingSmall)

                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                        editorTitle = note.title
                        editorBody = note.body
                    }
                    Button("Save") {
                        var copy = note
                        copy.title = editorTitle
                        copy.body = editorBody
                        app.saveNote(copy)
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Edit") {
                        editorTitle = note.title
                        editorBody = note.body
                        isEditing = true
                    }
                    Menu {
                        Button("Copy Note") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note.body, forType: .string)
                        }
                        Button("Export Note as Markdown…") { exportNote(note) }
                        Button(note.isPinned ? "Unpin" : "Pin") {
                            var copy = note
                            copy.isPinned.toggle()
                            app.saveNote(copy)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            app.deleteNote(note.id)
                            self.selectedNoteID = nil
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, Design.spacingMedium)
            .padding(.vertical, Design.spacingSmall)

            Divider()

            if isEditing {
                TextEditor(text: $editorBody)
                    .font(.system(size: 13))
                    .padding(Design.spacingSmall)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.spacingMedium) {
                        HStack(spacing: Design.spacingSmall) {
                            StatusPill(text: note.kind.displayName, color: .secondary, symbol: note.kind.symbolName)
                            if let model = note.modelName {
                                Text(model).font(Design.caption).foregroundStyle(.tertiary)
                            }
                            Text(Format.shortDate(note.updatedAt))
                                .font(Design.caption)
                                .foregroundStyle(.tertiary)
                        }

                        if let payload = note.payload, !payload.isEmpty {
                            if !payload.flashcards.isEmpty {
                                FlashcardDeck(
                                    cards: payload.flashcards,
                                    index: $flashcardIndex,
                                    revealed: $revealedCards
                                )
                            }
                            if !payload.quizItems.isEmpty {
                                QuizRunner(items: payload.quizItems, answers: $quizAnswers)
                            }
                            if !note.body.isEmpty {
                                DisclosureGroup("Original generated text") {
                                    MarkdownAnswer(text: note.body, citations: [])
                                        .padding(.top, 4)
                                }
                                .font(Design.caption)
                            }
                        } else if note.body.isEmpty {
                            Text("This note is empty.")
                                .font(Design.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownAnswer(text: note.body, citations: [])
                        }
                    }
                    .padding(Design.spacingLarge)
                    .frame(maxWidth: Design.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: note.id) { _, _ in
            isEditing = false
            flashcardIndex = 0
            revealedCards = []
            quizAnswers = [:]
        }
    }

    private func exportNote(_ note: NotebookNote) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(NotebookArchive.sanitize(note.title)).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let frontMatter = """
        ---
        title: \(note.title)
        kind: \(note.kind.rawValue)
        created: \(ISO8601DateFormatter().string(from: note.createdAt))
        model: \(note.modelName ?? "unknown")
        ---

        """
        do {
            try FileStore.write(frontMatter + note.body, to: url)
            app.statusMessage = "Exported “\(note.title)”"
        } catch let error as SourceDeskError {
            app.lastError = AppState.PresentedError(error)
        } catch {
            app.lastError = AppState.PresentedError(title: "Couldn't export the note", message: error.localizedDescription)
        }
    }
}

/// A real flashcard deck: one card at a time, reveal, and progress.
@MainActor
struct FlashcardDeck: View {
    let cards: [Flashcard]
    @Binding var index: Int
    @Binding var revealed: Set<RecordID>

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            HStack {
                SectionHeader("Flashcards")
                Text("\(min(index + 1, cards.count)) of \(cards.count)")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }

            if let card = current {
                VStack(alignment: .leading, spacing: Design.spacingSmall) {
                    Text(card.front)
                        .font(.system(size: 14, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)

                    if revealed.contains(card.id) {
                        Divider()
                        Text(card.back)
                            .font(Design.answerBody)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let marker = card.sourceMarker {
                            Text(marker)
                                .font(Design.monoCaption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(Design.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Design.rowCornerRadius).fill(Color(nsColor: .controlBackgroundColor)))
            }

            HStack(spacing: Design.spacingSmall) {
                Button(revealed.contains(current?.id ?? "") ? "Hide answer" : "Show answer") {
                    guard let card = current else { return }
                    if revealed.contains(card.id) { revealed.remove(card.id) } else { revealed.insert(card.id) }
                }
                .controlSize(.small)
                .disabled(current == nil)

                Spacer()

                Button("Previous") { index = max(0, index - 1) }
                    .controlSize(.small)
                    .disabled(index == 0)
                Button("Next") { index = min(cards.count - 1, index + 1) }
                    .controlSize(.small)
                    .disabled(index >= cards.count - 1)
            }
        }
    }

    private var current: Flashcard? {
        cards.indices.contains(index) ? cards[index] : cards.first
    }
}

/// A usable quiz: pick an answer, get told whether it was right and why.
@MainActor
struct QuizRunner: View {
    let items: [QuizItem]
    @Binding var answers: [RecordID: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingMedium) {
            HStack {
                SectionHeader("Quiz")
                Text("\(score) of \(items.count) correct")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(index + 1). \(item.question)")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(item.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                        Button {
                            answers[item.id] = choiceIndex
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: symbol(for: item, choice: choiceIndex))
                                    .font(.system(size: 11))
                                    .foregroundStyle(color(for: item, choice: choiceIndex))
                                Text(choice)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(background(for: item, choice: choiceIndex))
                        )
                    }

                    if let picked = answers[item.id] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(picked == item.answerIndex ? "Correct" : "The answer is: \(item.answer)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(picked == item.answerIndex ? Color.green : Color.orange)
                            if !item.explanation.isEmpty {
                                Text(item.explanation)
                                    .font(Design.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(Design.spacingSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Design.rowCornerRadius).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            }
        }
    }

    private var score: Int {
        items.filter { answers[$0.id] == $0.answerIndex }.count
    }

    private func symbol(for item: QuizItem, choice: Int) -> String {
        guard let picked = answers[item.id] else { return "circle" }
        if choice == item.answerIndex { return "checkmark.circle.fill" }
        if choice == picked { return "xmark.circle.fill" }
        return "circle"
    }

    private func color(for item: QuizItem, choice: Int) -> Color {
        guard let picked = answers[item.id] else { return .secondary }
        if choice == item.answerIndex { return .green }
        if choice == picked { return .red }
        return .secondary
    }

    private func background(for item: QuizItem, choice: Int) -> Color {
        guard let picked = answers[item.id] else { return .clear }
        if choice == item.answerIndex { return Color.green.opacity(0.12) }
        if choice == picked { return Color.red.opacity(0.12) }
        return .clear
    }
}
