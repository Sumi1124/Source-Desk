import Foundation
import SourceDeskCore
import SwiftUI

/// Drives the study-tools panel and the search panel.
@Observable
@MainActor
final class StudyToolsViewModel {

    private let app: AppState

    var selectedTool: NoteKind = .summary
    var isGenerating = false
    var stage: String?
    var streamingText = ""
    var currentNote: NotebookNote?
    var notices: [String] = []
    var error: AppState.PresentedError?
    /// Sources the user has chosen to include (comparison needs a deliberate choice).
    var chosenSourceIDs: Set<RecordID> = []
    var focusText = ""

    private var task: Task<Void, Never>?

    init(app: AppState) {
        self.app = app
    }

    /// Tools that make sense with the notebook's current sources.
    var availableTools: [NoteKind] { StudyToolsService.availableTools }

    func toggleSource(_ id: RecordID) {
        if chosenSourceIDs.contains(id) { chosenSourceIDs.remove(id) } else { chosenSourceIDs.insert(id) }
    }

    func selectAllSources() {
        chosenSourceIDs = Set(app.sources.map(\.id))
    }

    func clearSourceSelection() {
        chosenSourceIDs.removeAll()
    }

    var effectiveSourceIDs: [RecordID]? {
        let available = Set(app.sources.filter { $0.status != .failed && $0.includeInRetrieval }.map(\.id))
        let chosen = chosenSourceIDs.intersection(available)
        return chosen.isEmpty ? nil : Array(chosen)
    }

    var canGenerate: Bool {
        guard !isGenerating else { return false }
        if selectedTool == .comparison {
            return app.sources.filter { $0.status != .failed }.count >= 2
        }
        return !app.sources.filter { $0.status != .failed }.isEmpty
    }

    /// A specific warning when the tool cannot run, instead of a silent disabled button.
    var blockingReason: String? {
        if selectedTool == .comparison, app.sources.filter({ $0.status != .failed }).count < 2 {
            return "Comparing sources needs at least two sources in this notebook."
        }
        if app.sources.filter({ $0.status != .failed }).isEmpty {
            return "Add a source to this notebook first — study tools work from your material only."
        }
        if let provider = app.currentProvider, !provider.isLocal {
            if app.settings.localOnlyMode {
                return "\(provider.displayName) is a cloud provider and Local-Only Mode is on. Switch to a local model in Settings → AI Providers."
            }
            if !provider.isConfigured {
                return "\(provider.displayName) needs an API key in Settings → AI Providers."
            }
            if let notebookID = app.selectedNotebookID, !app.settings.isCloudApproved(notebookID: notebookID) {
                return "Study tools would send source text to \(provider.displayName). Approve it in the banner, or switch to a local model."
            }
            if !app.isOnline {
                return "This Mac is offline, so \(provider.displayName) is unavailable. A local model still works."
            }
        }
        return nil
    }

    func generate() {
        guard canGenerate, !isGenerating, let notebookID = app.selectedNotebookID else { return }
        guard let service = app.studyService(notebookID: notebookID) else { return }

        // A cloud provider needs consent for this notebook before any source text moves.
        if let provider = app.currentProvider, !provider.isLocal, !app.settings.isCloudApproved(notebookID: notebookID) {
            app.cloudConsentPromptNotebookID = notebookID
            return
        }

        isGenerating = true
        streamingText = ""
        notices = []
        error = nil
        stage = "Preparing"
        app.isGenerating = true

        let tool = selectedTool
        let focus = focusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = effectiveSourceIDs

        task = Task { [weak self] in
            guard let self else { return }
            var outcome: StudyToolsService.Outcome?
            var failure: SourceDeskError?

            for await event in service.generate(
                tool: tool,
                notebookID: notebookID,
                sourceIDs: sourceIDs,
                focus: focus.isEmpty ? nil : focus
            ) {
                switch event {
                case .stage(let value):
                    self.stage = value
                case .delta(let piece):
                    self.streamingText += piece
                case .finished(let result):
                    outcome = result
                case .failed(let err):
                    failure = err
                }
            }

            if let outcome {
                self.currentNote = outcome.note
                self.notices = outcome.notices
                self.app.reloadNotebookContent()
                self.app.selectedNoteID = outcome.note.id
                self.app.statusMessage = "Saved “\(outcome.note.title)” to Notes"
            } else if let failure {
                self.error = AppState.PresentedError(failure)
                self.app.lastError = self.error
            }

            self.isGenerating = false
            self.stage = nil
            self.streamingText = ""
            self.app.isGenerating = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isGenerating = false
        stage = nil
        streamingText = ""
        app.isGenerating = false
    }
}

// MARK: - Search panel

/// Drives the standalone web-search panel, which is deliberately separate from chat
/// so a user can look something up without committing it to a conversation.
@Observable
@MainActor
final class SearchPanelViewModel {

    private let app: AppState

    var query = ""
    var results: [WebSearchResult] = []
    var isSearching = false
    var error: AppState.PresentedError?
    var lastQuery: String?
    var notice: String?

    init(app: AppState) {
        self.app = app
    }

    var providerName: String { app.settings.searchEngine.displayName }
    var isConfigured: Bool { app.searchProvider?.isConfigured ?? false }

    var blockingReason: String? {
        if app.settings.searchEngine == .none {
            return "Web search is switched off. Choose a search provider in Settings → Search."
        }
        if !app.isOnline {
            return "This Mac is offline, so web search is unavailable. Notebook sources still work."
        }
        if !isConfigured {
            return app.searchProvider?.configurationHint ?? "The selected search provider is not configured."
        }
        return nil
    }

    func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching, let service = app.webSearch else { return }
        isSearching = true
        error = nil
        notice = nil
        results = []
        lastQuery = trimmed

        Task {
            do {
                let outcome = try await service.search(query: trimmed, limit: app.settings.searchResultCount)
                results = outcome.results
                notice = outcome.notice
            } catch let err as SourceDeskError {
                error = AppState.PresentedError(err)
            } catch {
                self.error = AppState.PresentedError(title: "Search failed", message: error.localizedDescription)
            }
            isSearching = false
        }
    }

    /// Adds a result to the notebook as a proper source, with the site's own text.
    func addAsSource(_ result: WebSearchResult) {
        app.addSources(.website(url: result.url, title: result.title))
    }

    /// Copies the result's details into a note, for the "quote this" workflow.
    func saveAsNote(_ result: WebSearchResult) {
        guard let notebookID = app.selectedNotebookID else { return }
        let body = """
        # \(result.title)

        \(result.url)

        \(result.content.isEmpty ? result.snippet : result.content)
        """
        app.saveNote(NotebookNote(notebookID: notebookID, title: result.title, body: body, kind: .manual))
        app.statusMessage = "Saved web result to Notes"
    }
}
