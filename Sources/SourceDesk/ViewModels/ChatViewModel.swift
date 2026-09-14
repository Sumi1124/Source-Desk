import Foundation
import SourceDeskCore
import SwiftUI

/// The research chat for a notebook: asks questions, streams answers, and keeps
/// everything — including the retrieval trace — persisted.
///
/// This is a view model in the strict sense: it owns no database handle and does no
/// retrieval itself, it drives `AnswerEngine` and turns its events into observable
/// state.
@Observable
@MainActor
final class ChatViewModel {

    private let app: AppState

    var messages: [ChatMessage] = []
    /// The answer currently being streamed.
    var streamingText = ""
    var streamingReasoning = ""
    var stage: AnswerEngine.Stage?
    var isStreaming = false
    var notices: [String] = []
    var suggestedFollowUps: [String] = []

    private var generationTask: Task<Void, Never>?

    init(app: AppState) {
        self.app = app
    }

    // MARK: Sessions

    var currentSession: ChatSession? {
        guard let id = app.selectedSessionID else { return nil }
        return app.sessions.first { $0.id == id }
    }

    func loadMessages() {
        guard let id = app.selectedSessionID else {
            messages = []
            return
        }
        messages = app.messages(for: id)
        if let last = messages.last(where: { $0.role == .assistant && !$0.citations.isEmpty }) {
            app.activeCitations = last.citations
            app.activeTrace = last.retrieval
        }
    }

    func ensureSession() -> ChatSession? {
        if let session = currentSession { return session }
        return app.createSession()
    }

    // MARK: Asking

    func ask(_ question: String, scope overrideScope: AnswerScope? = nil) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        guard let notebookID = app.selectedNotebookID else { return }

        // A cloud provider needs the user's explicit go-ahead for this notebook.
        let provider = app.currentProvider
        if let provider, !provider.isLocal, !app.settings.isCloudApproved(notebookID: notebookID) {
            app.cloudConsentPromptNotebookID = notebookID
            return
        }

        guard let session = ensureSession(), let store = app.store else { return }
        var workingSession = session
        if let overrideScope { workingSession.scope = overrideScope }
        workingSession.providerID = app.settings.preferredProviderID
        workingSession.modelName = app.currentModelName
        _ = try? store.upsert(session: workingSession)

        // Persist the question immediately: if the app quits mid-answer, the
        // question is still there with its history.
        let userMessage = ChatMessage(sessionID: session.id, notebookID: notebookID, role: .user, content: trimmed)
        _ = try? store.upsert(message: userMessage)
        messages.append(userMessage)

        // First question names the session.
        if messages.filter({ $0.role == .user }).count == 1 {
            var renamed = workingSession
            renamed.title = Self.sessionTitle(from: trimmed)
            _ = try? store.upsert(session: renamed)
            app.reloadNotebookContent()
        }

        guard let engine = app.answerEngine(notebookID: notebookID) else { return }

        isStreaming = true
        stage = .preparing
        streamingText = ""
        streamingReasoning = ""
        notices = []
        suggestedFollowUps = []
        app.isGenerating = true
        app.activeCitations = []
        app.activeTrace = nil

        let history = messages.dropLast()

        generationTask = Task { [weak self] in
            guard let self else { return }
            var finalOutcome: AnswerEngine.AnswerOutcome?
            var failure: SourceDeskError?

            for await event in engine.answer(
                question: trimmed,
                notebookID: notebookID,
                sessionID: session.id,
                history: Array(history),
                // The scope chosen in the composer, not the Settings default. Without
                // this the engine kept running the configured default, so picking
                // "Sources + Web" saved the choice and then ignored it.
                scope: workingSession.scope
            ) {
                switch event {
                case .stage(let value):
                    self.stage = value
                    self.app.generationStage = value
                case .delta(let piece):
                    self.streamingText += piece
                case .reasoning(let piece):
                    self.streamingReasoning += piece
                case .webSearchCompleted(let count):
                    self.notices.append("Searched the web · \(count) result\(count == 1 ? "" : "s")")
                case .finished(let outcome):
                    finalOutcome = outcome
                case .failed(let error):
                    failure = error
                }
            }

            if let outcome = finalOutcome {
                self.persist(outcome: outcome, question: trimmed, session: workingSession)
            } else {
                let error = failure ?? .providerUnavailable(provider: self.app.settings.preferredProviderID,
                                                            reason: "the answer ended without a result")
                self.persistFailure(error, session: workingSession, question: trimmed)
            }

            self.isStreaming = false
            self.stage = nil
            self.streamingText = ""
            self.streamingReasoning = ""
            self.app.isGenerating = false
            self.app.generationStage = nil
        }
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isStreaming = false
        stage = nil
        app.isGenerating = false
        if !streamingText.isEmpty {
            // Keep what was produced rather than discarding it silently.
            notices.append("Stopped early. The partial answer above was kept.")
        }
        streamingText = ""
    }

    // MARK: Persistence

    private func persist(outcome: AnswerEngine.AnswerOutcome, question: String, session: ChatSession) {
        guard let store = app.store, let notebookID = app.selectedNotebookID else { return }
        let message = ChatMessage(
            sessionID: session.id,
            notebookID: notebookID,
            role: .assistant,
            content: outcome.answer,
            citations: outcome.citations,
            retrieval: outcome.trace,
            providerID: outcome.provider,
            modelName: outcome.model,
            latencyMilliseconds: outcome.latencyMilliseconds,
            promptTokens: outcome.usage.promptTokens,
            completionTokens: outcome.usage.completionTokens
        )
        _ = try? store.upsert(message: message)
        _ = try? store.touchNotebook(id: notebookID)
        messages.append(message)
        app.activeCitations = outcome.citations
        app.activeTrace = outcome.trace
        notices = outcome.notices
        suggestedFollowUps = Self.suggestions(for: question, outcome: outcome)
        app.reloadNotebookContent()
    }

    private func persistFailure(_ error: SourceDeskError, session: ChatSession, question: String) {
        guard let store = app.store, let notebookID = app.selectedNotebookID else { return }
        if case .cancelled = error { return }
        let message = ChatMessage(
            sessionID: session.id,
            notebookID: notebookID,
            role: .assistant,
            content: "",
            isError: true,
            errorMessage: error.errorDescription,
            errorRecovery: error.recoverySuggestion
        )
        _ = try? store.upsert(message: message)
        messages.append(message)
        app.lastError = AppState.PresentedError(error)
        suggestedFollowUps = Self.suggestions(for: question, outcome: nil)
    }

    // MARK: Helpers

    static func sessionTitle(from question: String) -> String {
        let cleaned = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ")
        let title = words.prefix(7).joined(separator: " ")
        return title.count > 60 ? String(title.prefix(60)) + "…" : (title.isEmpty ? "New session" : title)
    }

    /// Offers a next step that matches what actually happened: adding sources when
    /// retrieval found nothing, web search when the user is notebook-only, and a
    /// study tool when an answer was good.
    static func suggestions(for question: String, outcome: AnswerEngine.AnswerOutcome?) -> [String] {
        var suggestions: [String] = []
        guard let outcome else {
            return ["Try again", "Switch to a local model", "Add a source"]
        }
        if outcome.suggestsMoreSources {
            suggestions.append("What do my sources cover?")
            if outcome.privacyLevel == .local { suggestions.append("Add a website source") }
        } else if !outcome.citations.isEmpty {
            suggestions.append("Summarise the sources behind that answer")
            suggestions.append("What do the sources disagree about?")
        }
        if outcome.wasTruncated {
            suggestions.append("Continue that answer in more detail")
        }
        if suggestions.isEmpty {
            suggestions.append("What are the key points across my sources?")
        }
        return Array(suggestions.prefix(3))
    }

    /// Turns an answer into a saved note.
    func saveAnswerAsNote(_ message: ChatMessage, title: String? = nil) {
        guard let notebookID = app.selectedNotebookID else { return }
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
        let note = NotebookNote(
            notebookID: notebookID,
            title: title ?? Self.sessionTitle(from: message.content),
            body: body,
            kind: .manual,
            sourceIDs: message.citations.compactMap(\.sourceID),
            providerID: message.providerID,
            modelName: message.modelName
        )
        app.saveNote(note)
        app.statusMessage = "Saved to Notes"
    }
}
