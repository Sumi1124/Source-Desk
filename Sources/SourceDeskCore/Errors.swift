import Foundation

/// Every user-visible failure in SourceDesk is expressed as one of these cases.
/// Each case carries a stable description, a reason, and a recovery suggestion so
/// the UI can always tell the user *what happened* and *what to do next* instead of
/// showing a generic "something went wrong".
public enum SourceDeskError: Error, LocalizedError, Equatable, Sendable {

    // Networking / ingestion
    case invalidURL(String)
    case notHTTPURL(String)
    case downloadFailed(url: String, reason: String)
    case httpStatus(url: String, status: Int)
    case requestTimedOut(url: String, seconds: Double)
    case robotsDisallowed(url: String)
    case authenticationRequired(url: String)
    case pageTooLarge(url: String, bytes: Int64, limitBytes: Int64)
    case malformedHTML(url: String, detail: String)
    case emptyExtraction(url: String)
    case javascriptOnlyPage(url: String)
    case offline(feature: String)
    case cancelled

    // Documents
    case unsupportedDocument(name: String, detail: String)
    case unreadableDocument(name: String, detail: String)
    case documentTooLarge(name: String, bytes: Int64, limitBytes: Int64)
    case folderEmpty(path: String)
    case archiveCorrupt(detail: String)

    // Retrieval
    case noSources(notebook: String)
    case insufficientContext(question: String)
    case contextTooLarge(model: String, neededTokens: Int, limitTokens: Int)
    case embeddingModelUnavailable(model: String, reason: String)
    case vectorSearchUnavailable(reason: String)

    // Providers
    case noLocalModelConfigured
    case localModelNotRunning(endpoint: String)
    case localModelMissing(name: String, endpoint: String)
    case missingAPIKey(provider: String)
    case invalidAPIKey(provider: String)
    case providerUnavailable(provider: String, reason: String)
    case providerRateLimited(provider: String, retryAfter: Double?)
    case providerRejected(provider: String, status: Int, message: String)
    case emptyModelResponse(provider: String, model: String)
    case cloudDisabled(reason: String)
    case modelDoesNotSupportEmbeddings(provider: String, model: String)

    // Search
    case searchProviderNotConfigured(provider: String)
    case webSearchUnavailable(provider: String, reason: String)
    case noSearchResults(query: String)

    // Storage
    case storageUnavailable(path: String, reason: String)
    case database(message: String)
    case notFound(entity: String, id: String)
    case diskWriteFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let v): return "“\(v)” is not a valid URL."
        case .notHTTPURL(let v): return "“\(v)” is not an http or https address."
        case .downloadFailed(let url, _): return "The page could not be downloaded: \(url)."
        case .httpStatus(let url, let status): return "The server returned HTTP \(status) for \(url)."
        case .requestTimedOut(let url, let seconds): return "The request to \(url) timed out after \(Int(seconds))s."
        case .robotsDisallowed(let url): return "\(url) is disallowed by the site's robots.txt."
        case .authenticationRequired(let url): return "\(url) requires a sign-in."
        case .pageTooLarge(let url, let bytes, let limit): return "\(url) is \(Self.mb(bytes)) and exceeds the \(Self.mb(limit)) page limit."
        case .malformedHTML(let url, _): return "The HTML at \(url) could not be parsed."
        case .emptyExtraction(let url): return "No readable text was found at \(url)."
        case .javascriptOnlyPage(let url): return "\(url) appears to render its content with JavaScript only."
        case .offline(let feature): return "\(feature) needs an internet connection."
        case .cancelled: return "The operation was cancelled."
        case .unsupportedDocument(let name, _): return "“\(name)” is not a supported document type."
        case .unreadableDocument(let name, _): return "“\(name)” could not be read."
        case .documentTooLarge(let name, let bytes, let limit): return "“\(name)” is \(Self.mb(bytes)) and exceeds the \(Self.mb(limit)) import limit."
        case .folderEmpty(let path): return "No supported documents were found in \(path)."
        case .archiveCorrupt(let detail): return "The archive could not be read: \(detail)."
        case .noSources(let notebook): return "“\(notebook)” has no sources yet."
        case .insufficientContext(let q): return "Not enough relevant source material was found to answer “\(Self.clip(q))”."
        case .contextTooLarge(let model, _, _): return "\(model) cannot hold this request."
        case .embeddingModelUnavailable(let model, let reason): return "The embedding model “\(model)” is unavailable: \(reason)."
        case .vectorSearchUnavailable(let reason): return "Semantic search is unavailable: \(reason)."
        case .noLocalModelConfigured: return "No local model is available."
        case .localModelNotRunning(let endpoint): return "The local model server at \(endpoint) is not responding."
        case .localModelMissing(let name, _): return "The model “\(name)” is not installed."
        case .missingAPIKey(let provider): return "\(provider) is selected but no API key is stored."
        case .invalidAPIKey(let provider): return "\(provider) rejected the stored API key."
        case .providerUnavailable(let provider, let reason): return "\(provider) is unavailable: \(reason)."
        case .providerRateLimited(let provider, _): return "\(provider) is rate limiting this Mac."
        case .providerRejected(let provider, let status, let message): return "\(provider) returned HTTP \(status): \(message)"

        case .cloudDisabled(let reason): return "Cloud models are turned off: \(reason)"
        case .modelDoesNotSupportEmbeddings(let provider, let model): return "\(provider) model “\(model)” cannot produce embeddings."
        case .emptyModelResponse(let provider, let model):
            return "\(provider) returned an empty response from “\(model)”. Check that the model is loaded and that its context window is large enough for the retrieved passages; lowering the context budget in Settings → Retrieval can help."
        case .searchProviderNotConfigured(let provider): return "\(provider) is selected but not configured."
        case .webSearchUnavailable(let provider, let reason): return "Web search via \(provider) is unavailable: \(reason)."
        case .noSearchResults(let query): return "The web search for “\(Self.clip(query))” returned no usable results."
        case .storageUnavailable(let path, let reason): return "The storage location \(path) is unavailable: \(reason)."
        case .database(let message): return "The local database reported an error: \(message)"
        case .notFound(let entity, let id): return "That \(entity) no longer exists (\(id))."
        case .diskWriteFailed(let path, let reason): return "Could not write \(path): \(reason)"
        }
    }

    public var failureReason: String? {
        switch self {
        case .downloadFailed(_, let reason): return reason
        case .malformedHTML(_, let detail): return detail
        case .unsupportedDocument(_, let detail): return detail
        case .unreadableDocument(_, let detail): return detail
        case .embeddingModelUnavailable(_, let reason): return reason
        case .vectorSearchUnavailable(let reason): return reason
        case .localModelMissing(_, let endpoint): return "Checked \(endpoint)."
        case .providerUnavailable(_, let reason): return reason
        case .providerRejected(_, _, let message): return message
        case .cloudDisabled(let reason): return reason
        case .webSearchUnavailable(_, let reason): return reason
        case .storageUnavailable(_, let reason): return reason
        case .diskWriteFailed(_, let reason): return reason
        case .folderEmpty(let path): return "Scanned \(path)."
        case .archiveCorrupt(let detail): return detail
        case .javascriptOnlyPage: return "Static HTML contained almost no text, which usually means the page is client-rendered."
        case .authenticationRequired: return "The server answered with a sign-in or paywall gate."
        default: return nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidURL, .notHTTPURL:
            return "Paste a full address starting with http:// or https://."
        case .downloadFailed, .requestTimedOut, .malformedHTML:
            return "Check the connection, then retry the source. You can also paste the text in manually."
        case .httpStatus(_, let status) where status == 404:
            return "The page has probably moved. Check the address in your browser first."
        case .httpStatus(_, let status) where status == 429:
            return "Too many requests. Wait a moment and retry."
        case .httpStatus: return "Open the URL in your browser to confirm it is reachable, then retry."
        case .robotsDisallowed:
            return "The site asks automated clients to stay out. Add the content as pasted text instead."
        case .authenticationRequired:
            return "Sign in through your browser and save the article as a PDF, then import that file."
        case .pageTooLarge:
            return "Raise the page-size limit in Settings → Advanced, or import a trimmed HTML/PDF copy."
        case .javascriptOnlyPage:
            return "Open the page in a browser, use Reader Mode, and import it as pasted text or a PDF."
        case .emptyExtraction:
            return "The page may be an image gallery or empty. Try a different URL or paste the text manually."
        case .offline(_):
            return "Reconnect to the internet, or switch this notebook to local sources only."
        case .cancelled: return nil
        case .unsupportedDocument:
            return "Supported types are PDF, DOCX, TXT, Markdown, HTML, and pasted text."
        case .unreadableDocument:
            return "Make sure the file still exists and you have permission to read it."
        case .documentTooLarge:
            return "Raise the import limit in Settings → Advanced, or split the document."
        case .folderEmpty:
            return "Folder import picks up PDF, DOCX, TXT, MD, HTML, and RTF files."
        case .archiveCorrupt(let detail):
            if detail.localizedCaseInsensitiveContains("newer version")
                || detail.localizedCaseInsensitiveContains("newer format") {
                return "Update SourceDesk to open notebooks exported by a newer version."
            }
            return "The file may be truncated or not a SourceDesk notebook archive."
        case .noSources:
            return "Add a website, PDF, document, or pasted text to this notebook first."
        case .insufficientContext:
            return "Add more sources, switch on web search for this question, or switch to a model with more general knowledge."
        case .contextTooLarge:
            return "Lower the retrieval count or context budget in Settings → Advanced, or pick a model with a larger context window."
        case .embeddingModelUnavailable:
            return "Install the embedding model, or switch embeddings to “Built-in (hashing)” in Settings → Advanced."
        case .vectorSearchUnavailable:
            return "Answers will fall back to keyword search until semantic search is available again."
        case .noLocalModelConfigured:
            return "Install Ollama and pull a model (for example `ollama pull llama3.2`), or choose a cloud provider in Settings → AI Providers."
        case .localModelNotRunning:
            return "Start Ollama (`ollama serve`), then retry."
        case .localModelMissing:
            return "Pull the model with `ollama pull <name>`, or select one that is already installed."
        case .missingAPIKey:
            return "Open Settings → AI Providers and save the key. It is stored in the macOS Keychain, never in the notebook."
        case .invalidAPIKey:
            return "Re-enter the key in Settings → AI Providers."
        case .providerUnavailable, .providerRejected:
            return "Check the model name and your account limits, then retry. A local model will keep working in the meantime, and your sources are unaffected."
        case .providerRateLimited:
            return "Wait a moment and retry, or switch to a local model."
        case .cloudDisabled(let reason):
            // The advice must match the reason: local-only mode and withheld consent
            // are fixed in different places.
            if reason.localizedCaseInsensitiveContains("confirmation") || reason.localizedCaseInsensitiveContains("consent") {
                return "Approve sending to the cloud provider in the banner above the composer, or pick a local model."
            }
            if reason.localizedCaseInsensitiveContains("local-only") || reason.localizedCaseInsensitiveContains("local only") {
                return "Turn off Local-Only Mode in Settings → Privacy, or pick a local model."
            }
            return "Choose a local model, or enable cloud providers in Settings → Privacy."
        case .emptyModelResponse(_, _):
            return "Check that the model is running and the context budget fits its window; lower “Context budget” in Settings → Retrieval, or choose a different model."
        case .modelDoesNotSupportEmbeddings:
            return "Pick an embedding-capable model (for example `nomic-embed-text`), or use the built-in embedder."
        case .searchProviderNotConfigured:
            return "Choose a search provider in Settings → Search."
        case .webSearchUnavailable, .noSearchResults:
            return "Try a different query, or set the answer scope back to notebook sources only."
        case .storageUnavailable:
            return "Choose a writable storage folder in Settings → Storage."
        case .database:
            return "Reopen the notebook. If it keeps happening, export the notebook and re-import it."
        case .notFound:
            return "Refresh the sidebar — it may have been deleted in another window."
        case .diskWriteFailed:
            return "Check free disk space and folder permissions."
        }
    }

    private static func mb(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private static func clip(_ s: String, _ n: Int = 48) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
