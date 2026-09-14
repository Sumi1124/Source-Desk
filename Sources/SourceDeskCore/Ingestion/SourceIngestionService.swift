import Foundation

/// The pipeline that turns a request ("add this URL", "import these files") into
/// stored, chunked, embedded, searchable sources.
///
/// Design constraints, in order of importance:
///
/// 1. **Nothing partial is left behind.** A source that fails to fetch keeps its row
///    with a readable error; a source that fails to chunk keeps its extracted text.
/// 2. **Everything is cancellable** and reports progress, because importing a
///    600-page PDF or 200 URLs is a long operation on a real machine.
/// 3. **It never imposes a product limit.** There is no cap on source count, file
///    size (beyond a configurable safety limit) or notebook count.
public struct SourceIngestionService: Sendable {

    public struct Configuration: Sendable {
        public var chunking: TextChunker.Configuration
        public var download: WebDownloader.Options
        public var document: DocumentExtractor.Options
        /// Whether embeddings are generated during import.
        public var embeddingsEnabled: Bool

        public init(
            chunking: TextChunker.Configuration = .default,
            download: WebDownloader.Options = WebDownloader.Options(),
            document: DocumentExtractor.Options = .default,
            embeddingsEnabled: Bool = true
        ) {
            self.chunking = chunking
            self.download = download
            self.document = document
            self.embeddingsEnabled = embeddingsEnabled
        }

        public static let `default` = Configuration()
    }

    /// What the caller asked to add.
    public enum Request: Sendable {
        case website(url: String, title: String?)
        case files([URL])
        case pastedText(title: String, text: String, url: String?)
        case folder(URL)
    }

    public struct Progress: Sendable {
        public enum Stage: Sendable {
            case queued
            case fetching
            case extracting
            case chunking
            case embedding
            public var displayName: String {
                switch self {
                case .queued: return "Queued"
                case .fetching: return "Downloading"
                case .extracting: return "Reading"
                case .chunking: return "Chunking"
                case .embedding: return "Embedding"
                }
            }
        }
        public var itemIndex: Int
        public var itemCount: Int
        public var title: String
        public var stage: Stage
        /// 0…1 within the current item.
        public var fraction: Double

        public var overall: Double {
            guard itemCount > 0 else { return 0 }
            return (Double(itemIndex) + fraction) / Double(itemCount)
        }
    }

    public struct Result: Sendable {
        public var source: Source
        public var chunkCount: Int
        public var embeddingCount: Int
        public var error: SourceDeskError?
        /// Non-fatal notes, e.g. "embeddings were skipped".
        public var notices: [String]

        /// Whether this source is usable: it has stored text and did not error. A
        /// source stored without embeddings is `.partial`, which is still usable.
        public var succeeded: Bool { error == nil && (source.status == .ready || source.status == .partial) }
    }

    public struct BatchResult: Sendable {
        public var results: [Result]
        public var cancelled: Bool

        public var added: [Source] { results.filter(\.succeeded).map(\.source) }
        public var failed: [(source: Source, error: SourceDeskError)] {
            results.compactMap { result in
                guard let error = result.error else { return nil }
                return (result.source, error)
            }
        }
        public var chunkCount: Int { results.reduce(0) { $0 + $1.chunkCount } }
        public var embeddingCount: Int { results.reduce(0) { $0 + $1.embeddingCount } }
    }

    let store: NotebookStore
    let configuration: Configuration
    let downloader: WebDownloader
    let embedder: EmbeddingProvider?

    public init(
        store: NotebookStore,
        configuration: Configuration = .default,
        embedder: EmbeddingProvider? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.downloader = WebDownloader(options: configuration.download)
        self.embedder = embedder
    }

    // MARK: - Entry point

    public func ingest(
        request: Request,
        notebookID: RecordID,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> BatchResult {
        var results: [Result] = []
        var cancelled = false

        switch request {
        case .website(let url, let title):
            let result = await ingestWebsite(url: url, title: title, notebookID: notebookID, index: 0, total: 1, progress: progress)
            results.append(result)

        case .pastedText(let title, let text, let url):
            results.append(await ingestText(title: title, text: text, url: url, notebookID: notebookID, index: 0, total: 1, progress: progress))

        case .files(let urls):
            let expanded = Self.expand(urls)
            if expanded.isEmpty {
                return BatchResult(results: [], cancelled: false)
            }
            for (index, url) in expanded.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                let result = await ingestFile(url: url, notebookID: notebookID, index: index, total: expanded.count, progress: progress)
                results.append(result)
            }

        case .folder(let folderURL):
            let urls = Self.documents(in: folderURL)
            guard !urls.isEmpty else {
                return BatchResult(results: [
                    Result(source: Source(notebookID: notebookID, kind: .folder, title: folderURL.lastPathComponent,
                                          status: .failed,
                                          errorMessage: SourceDeskError.folderEmpty(path: folderURL.path).errorDescription,
                                          errorRecovery: SourceDeskError.folderEmpty(path: folderURL.path).recoverySuggestion),
                           chunkCount: 0, embeddingCount: 0,
                           error: .folderEmpty(path: folderURL.path), notices: [])
                ], cancelled: false)
            }
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                let result = await ingestFile(url: url, notebookID: notebookID, index: index, total: urls.count, progress: progress)
                results.append(result)
            }
        }

        return BatchResult(results: results, cancelled: cancelled || Task.isCancelled)
    }

    // MARK: - Research (search the web, then ingest what it found)

    /// The outcome of a research run.
    public struct ResearchOutcome: Sendable {
        /// How many results the search returned.
        public var searched: Int
        /// Sources that were downloaded, indexed and are citable.
        public var added: [Source]
        /// Results that could not be turned into usable sources.
        public var failed: [(url: String, error: SourceDeskError?)]
        /// A human-readable note when nothing could be added.
        public var notice: String?
        public var cancelled: Bool = false

        public var succeeded: Bool { !added.isEmpty }
    }

    /// Searches the web for a topic and ingests the results as real sources.
    ///
    /// Every result goes through `ingestWebsite`, so a researched source is exactly like
    /// one the user pasted in: downloaded (respecting robots.txt), extracted, cleaned,
    /// chunked, embedded and citable. Nothing is built from a search snippet, because a
    /// snippet is a fragment of a results page rather than the author's text — treating
    /// it as the source would put words in the source's mouth.
    ///
    /// A result whose page cannot be read is reported in `failed`, never saved as an
    /// empty source that would look fine in the sidebar and cite nothing.
    public func searchAndIngest(
        query: String,
        provider: SearchProvider,
        notebookID: RecordID,
        limit: Int = 5,
        enrichWithPageContent: Bool = false,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> ResearchOutcome {
        let service = WebSearchService(provider: provider, downloader: downloader)
        let results: [WebSearchResult]
        do {
            results = try await service.search(
                query: query,
                limit: limit,
                enrichWithPageContent: enrichWithPageContent
            ).results
        } catch let error as SourceDeskError {
            // "Nothing matched" is an ordinary outcome of a search, not a fault in the
            // app: `WebSearchService` raises `noSearchResults` for it. Reporting it as a
            // notice keeps the two apart, so an empty search does not surface as though
            // something broke.
            if case .noSearchResults = error {
                return ResearchOutcome(searched: 0, added: [], failed: [],
                                       notice: "The search returned no results for “\(query)”. Try different wording.")
            }
            throw error
        }

        guard !results.isEmpty else {
            return ResearchOutcome(searched: 0, added: [], failed: [],
                                   notice: "The search returned no results for “\(query)”.")
        }

        var added: [Source] = []
        var failed: [(url: String, error: SourceDeskError?)] = []
        var cancelled = false
        // The same page can appear more than once (mirrors, query strings, trailing
        // slashes); ingesting it twice would double its citations.
        var seen: Set<String> = []

        for (index, result) in results.enumerated() {
            if Task.isCancelled { cancelled = true; break }

            guard URL(string: result.url)?.host() != nil else {
                failed.append((result.url, nil))
                continue
            }
            let key = Self.dedupeKey(result.url)
            if !seen.insert(key).inserted { continue }

            let result_ = await ingestWebsite(
                url: result.url,
                title: result.title.isEmpty ? nil : result.title,
                notebookID: notebookID,
                index: index,
                total: results.count,
                progress: progress
            )

            // The test of usability is whether the page yielded text, not whether
            // embeddings ran. A source with `.partial` status has been downloaded,
            // extracted and chunked but stored without vectors (embeddings are off, or
            // the embedding model is unavailable) — keyword search still finds it, so it
            // is a real source. Treating `.partial` as failure would tell the user that
            // nothing was added while their sources sat in the sidebar.
            if result_.chunkCount > 0, result_.error == nil {
                added.append(result_.source)
            } else {
                failed.append((result.url, result_.error ?? .emptyExtraction(url: result.url)))
            }
        }

        var notice: String?
        if added.isEmpty {
            notice = failed.isEmpty
                ? "Nothing was added for “\(query)”."
                : "The search found \(results.count) page(s), but none could be downloaded and read."
        }
        return ResearchOutcome(searched: results.count, added: added, failed: failed,
                               notice: notice, cancelled: cancelled)
    }

    /// Two URLs that differ only by a trailing slash, a fragment or tracking parameters
    /// point at the same document.
    static func dedupeKey(_ url: String) -> String {
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespaces)) else {
            return url.trimmingCharacters(in: .whitespaces).lowercased()
        }
        components.fragment = nil
        let tracking = Set(["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
                            "gclid", "fbclid", "ref", "ref_src"])
        components.queryItems = components.queryItems?.filter { !tracking.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = path

        var host = components.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        components.host = host
        if components.scheme == "http" { components.scheme = "https" }
        return components.string ?? url
    }

    // MARK: - Websites

    public func ingestWebsite(
        url rawURL: String,
        title requestedTitle: String?,
        notebookID: RecordID,
        index: Int = 0,
        total: Int = 1,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Result {
        let now = Date()
        var source = Source(
            notebookID: notebookID,
            kind: .website,
            title: requestedTitle ?? rawURL,
            url: rawURL,
            status: .fetching,
            statusDetail: "Downloading",
            addedAt: now,
            updatedAt: now
        )
        source = (try? store.upsert(source: source)) ?? source
        progress?(Progress(itemIndex: index, itemCount: total, title: source.title, stage: .fetching, fraction: 0))

        do {
            // 1. Download.
            let response = try await downloader.fetch(url: rawURL)

            // A URL that already exists in this notebook is updated, not duplicated —
            // re-adding a page refreshes it. The placeholder row created above (before
            // the canonical URL was known) is reclaimed here, otherwise every re-add
            // would leave an empty source behind.
            let canonical = response.finalURL
            let existing = (try? store.source(matchingURL: canonical, notebookID: notebookID))
                ?? (try? store.source(matchingURL: rawURL, notebookID: notebookID))
                ?? nil
            if let existing, existing.id != source.id {
                // Only reclaim a placeholder that has nothing stored against it.
                if existing.chunkCount > 0 || existing.contentPath != nil {
                    _ = try? store.deleteSource(id: source.id)
                    source = existing
                    source.status = .fetching
                    source.statusDetail = "Refreshing"
                    source = (try? store.upsert(source: source)) ?? source
                }
            }

            source.url = canonical
            if source.title == rawURL || source.title.isEmpty {
                source.title = response.title ?? Self.titleFromURL(response.finalURL)
            }
            source.fetchedAt = now
            source.fetchMilliseconds = response.elapsedMilliseconds
            source.originalBytes = response.byteCount
            source.contentPath = store.paths.contentDirectory(for: source.id).path

            progress?(Progress(itemIndex: index, itemCount: total, title: source.title, stage: .extracting, fraction: 0.35))

            // 2. Extract.
            let document = try downloader.extractDocument(from: response)
            if source.title.isEmpty || source.title == rawURL {
                source.title = document.title
            }
            source.author = document.author
            source.siteName = document.siteName
            source.publishedAt = document.publishedAt
            source.mimeType = response.contentType
            source.extractionMethod = document.method

            return try await storeDocument(
                document: document,
                source: source,
                notebookID: notebookID,
                originalPayload: Data(response.html.utf8),
                originalFileName: "original.html",
                index: index,
                total: total,
                progress: progress
            )
        } catch let error as SourceDeskError {
            return fail(error, source: source, notebookID: notebookID)
        } catch {
            return fail(.downloadFailed(url: rawURL, reason: error.localizedDescription), source: source, notebookID: notebookID)
        }
    }

    // MARK: - Pasted text

    public func ingestText(
        title: String,
        text: String,
        url: String?,
        notebookID: RecordID,
        index: Int = 0,
        total: Int = 1,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else {
            var source = Source(notebookID: notebookID, kind: .pastedText, title: title, status: .failed)
            source.errorMessage = "That text is too short to be a useful source."
            source.errorRecovery = "Paste at least a sentence or two."
            source = (try? store.upsert(source: source)) ?? source
            return Result(source: source, chunkCount: 0, embeddingCount: 0,
                          error: .unreadableDocument(name: title, detail: "too short"), notices: [])
        }

        var source = Source(
            notebookID: notebookID,
            kind: .pastedText,
            title: title.isEmpty ? "Pasted text" : title,
            url: url,
            plainTextBytes: Int64(trimmed.utf8.count),
            status: .extracting,
            statusDetail: "Reading",
            addedAt: Date(),
            updatedAt: Date()
        )
        source = (try? store.upsert(source: source)) ?? source
        progress?(Progress(itemIndex: index, itemCount: total, title: source.title, stage: .extracting, fraction: 0.3))

        let blocks = Markdownish.parse(trimmed)
        let document = ExtractedDocument(title: source.title, method: "pasted text",
                                         pages: [ExtractedPage(number: 0, blocks: blocks)])
        do {
            return try await storeDocument(document: document, source: source, notebookID: notebookID,
                                           originalPayload: Data(trimmed.utf8), originalFileName: "original.txt",
                                           index: index, total: total, progress: progress)
        } catch let error as SourceDeskError {
            return fail(error, source: source, notebookID: notebookID)
        } catch {
            return fail(.unreadableDocument(name: source.title, detail: error.localizedDescription), source: source, notebookID: notebookID)
        }
    }

    // MARK: - Files

    public func ingestFile(
        url: URL,
        notebookID: RecordID,
        index: Int = 0,
        total: Int = 1,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Result {
        let kind = DocumentExtractor.kind(for: url) ?? .plainText
        var source = Source(
            notebookID: notebookID,
            kind: kind,
            title: url.deletingPathExtension().lastPathComponent,
            filePath: url.path,
            originalBytes: FileStore.size(of: url),
            status: .extracting,
            statusDetail: "Reading",
            addedAt: Date(),
            updatedAt: Date()
        )
        // Local documents are identified by their path. Re-importing the same file
        // refreshes the existing source instead of adding a second row that would
        // point at a content folder nothing owns.
        if let existing = try? store.sources(notebookID: notebookID).first(where: { $0.filePath == url.path && $0.kind == kind }) {
            source = existing
            source.status = .extracting
            source.statusDetail = "Refreshing"
        }
        source = (try? store.upsert(source: source)) ?? source
        progress?(Progress(itemIndex: index, itemCount: total, title: source.title, stage: .extracting, fraction: 0.2))

        do {
            let document = try DocumentExtractor.extract(url: url, kind: kind, options: configuration.document)
            source.title = document.title.isEmpty ? url.deletingPathExtension().lastPathComponent : document.title
            source.author = document.author
            source.publishedAt = document.publishedAt
            source.mimeType = Self.mimeType(for: kind)

            // Keep a copy of the original file so the source survives the user
            // moving or deleting it, and so an export is self-contained.
            var originalPayload: Data?
            var originalName = url.lastPathComponent
            if kind == .pdf || kind == .docx || kind == .rtf || kind == .epub {
                originalPayload = try? Data(contentsOf: url, options: .mappedIfSafe)
            } else {
                originalPayload = (try? FileStore.readText(at: url)).map { Data($0.utf8) }
            }
            if originalPayload == nil { originalName = "" }

            return try await storeDocument(
                document: document,
                source: source,
                notebookID: notebookID,
                originalPayload: originalPayload,
                originalFileName: originalName,
                index: index,
                total: total,
                progress: progress
            )
        } catch let error as SourceDeskError {
            return fail(error, source: source, notebookID: notebookID)
        } catch {
            return fail(.unreadableDocument(name: url.lastPathComponent, detail: error.localizedDescription),
                        source: source, notebookID: notebookID)
        }
    }

    // MARK: - Shared storage step

    /// Chunks, embeds and writes a parsed document. Every path through ingestion
    /// funnels here, so extraction text, chunk rows, vectors and status are always
    /// written together.
    private func storeDocument(
        document: ExtractedDocument,
        source inputSource: Source,
        notebookID: RecordID,
        originalPayload: Data?,
        originalFileName: String,
        index: Int,
        total: Int,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> Result {
        var source = inputSource
        var notices: [String] = []
        let plainText = document.plainText

        if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SourceDeskError.emptyExtraction(url: source.url ?? source.title)
        }

        // Write extracted text next to the library.
        let contentURL = store.paths.extractedTextURL(for: source.id)
        try FileStore.write(plainText, to: contentURL)
        source.contentPath = contentURL.path
        source.plainTextBytes = Int64(plainText.utf8.count)
        source.wordCount = document.wordCount
        source.pageCount = document.pageCount
        source.checksum = FileStore.checksum(of: Data(plainText.utf8))
        if let payload = originalPayload, !originalFileName.isEmpty {
            _ = try? FileStore.write(payload, to: store.paths.originalFileURL(for: source.id, fileName: originalFileName))
        }

        if Task.isCancelled {
            source.status = .cancelled
            source.statusDetail = "Cancelled"
            source = (try? store.upsert(source: source)) ?? source
            _ = try? store.replaceChunks(sourceID: source.id, notebookID: notebookID, chunks: [], embeddings: [])
            return Result(source: source, chunkCount: 0, embeddingCount: 0, error: .cancelled, notices: [])
        }

        // Chunk.
        progress?(Progress(itemIndex: index, itemCount: total, title: source.title, stage: .chunking, fraction: 0.6))
        source.status = .chunking
        source.statusDetail = "Chunking"
        source = (try? store.upsert(source: source)) ?? source

        let chunks = TextChunker.chunk(
            document: document,
            sourceID: source.id,
            notebookID: notebookID,
            configuration: configuration.chunking
        )
        guard !chunks.isEmpty else {
            throw SourceDeskError.emptyExtraction(url: source.url ?? source.title)
        }

        // Embed (optional, and never fatal).
        var embeddings: [ChunkEmbedding] = []
        if configuration.embeddingsEnabled {
            progress?(Progress(itemIndex: index, itemCount: total, title: source.title, stage: .embedding, fraction: 0.75))
            source.status = .embedding
            source.statusDetail = "Embedding"
            source = (try? store.upsert(source: source)) ?? source

            let indexer = EmbeddingIndexer(provider: embedder)
            let sourceTitle = source.title
            do {
                let outcome = try await indexer.index(chunks: chunks, progress: { fraction in
                    progress?(Progress(itemIndex: index, itemCount: total, title: sourceTitle, stage: .embedding, fraction: 0.75 + fraction * 0.2))
                })
                embeddings = outcome.embeddings
                if let reason = outcome.skippedReason {
                    notices.append("Stored without embeddings: \(reason)")
                }
                if outcome.wasCancelled { notices.append("Embedding was interrupted; keyword search still works for this source.") }
            } catch let error as SourceDeskError {
                notices.append("Stored without embeddings: \(error.errorDescription ?? "\(error)")")
            } catch {
                notices.append("Stored without embeddings: \(error.localizedDescription)")
            }
        }

        try store.replaceChunks(sourceID: source.id, notebookID: notebookID, chunks: chunks, embeddings: embeddings)

        source.chunkCount = chunks.count
        source.status = notices.isEmpty ? .ready : .partial
        source.statusDetail = notices.isEmpty ? nil : notices.first
        source.errorMessage = nil
        source.errorRecovery = nil
        source.updatedAt = Date()
        source = try store.upsert(source: source)
        _ = try? store.touchNotebook(id: notebookID)

        progress?(Progress(itemIndex: index, itemCount: total, title: source.title, stage: .embedding, fraction: 1.0))
        return Result(source: source, chunkCount: chunks.count, embeddingCount: embeddings.count, error: nil, notices: notices)
    }

    /// Records the failure on the source row: the user sees a source with a red
    /// status and an explanation, not a silently dropped import.
    private func fail(_ error: SourceDeskError, source: Source, notebookID: RecordID) -> Result {
        var failed = source
        failed.status = error == .cancelled ? .cancelled : .failed
        failed.statusDetail = nil
        failed.errorMessage = error.errorDescription
        failed.errorRecovery = error.recoverySuggestion
        failed.updatedAt = Date()
        if case .cancelled = error {
            // A cancelled import is not a failure worth keeping in the notebook.
            _ = try? store.deleteSource(id: failed.id)
            return Result(source: failed, chunkCount: 0, embeddingCount: 0, error: error, notices: [])
        }
        failed = (try? store.upsert(source: failed)) ?? failed
        return Result(source: failed, chunkCount: 0, embeddingCount: 0, error: error, notices: [])
    }

    // MARK: - Re-indexing

    /// Re-chunks and re-embeds a source from its stored text. Used when retrieval
    /// settings change, or when the embedding model changes and stored vectors no
    /// longer match the current one.
    public func reindex(
        sourceID: RecordID,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Result {
        guard let source = try? store.source(id: sourceID) else {
            return Result(source: Source(notebookID: "", kind: .plainText, title: "Missing", status: .failed),
                          chunkCount: 0, embeddingCount: 0,
                          error: .notFound(entity: "source", id: sourceID), notices: [])
        }
        guard let contentPath = source.contentPath, FileStore.exists(URL(fileURLWithPath: contentPath)) else {
            return fail(.notFound(entity: "stored text", id: sourceID), source: source, notebookID: source.notebookID)
        }

        do {
            let text = try FileStore.readText(at: URL(fileURLWithPath: contentPath))
            let blocks = Markdownish.parse(text)
            let document = ExtractedDocument(
                title: source.title,
                method: source.extractionMethod ?? "reindex",
                pages: source.pageCount != nil
                    ? Self.paginate(text)
                    : [ExtractedPage(number: 0, blocks: blocks)]
            )
            var working = source
            working.status = .chunking
            working = (try? store.upsert(source: working)) ?? working
            return try await storeDocument(
                document: document, source: working, notebookID: source.notebookID,
                originalPayload: nil, originalFileName: "", index: 0, total: 1, progress: progress
            )
        } catch let error as SourceDeskError {
            return fail(error, source: source, notebookID: source.notebookID)
        } catch {
            return fail(.unreadableDocument(name: source.title, detail: error.localizedDescription),
                        source: source, notebookID: source.notebookID)
        }
    }

    /// Rebuilds page boundaries from stored text written with `## Page N` markers,
    /// so re-indexing a PDF keeps its page citations.
    static func paginate(_ text: String) -> [ExtractedPage] {
        var pages: [ExtractedPage] = []
        var currentPage = 0
        var currentBlocks: [ExtractedBlock] = []
        for block in Markdownish.parse(text) {
            if block.kind == .heading, let number = Self.pageNumber(from: block.text) {
                if !currentBlocks.isEmpty || currentPage > 0 {
                    pages.append(ExtractedPage(number: currentPage, blocks: currentBlocks))
                }
                currentPage = number
                currentBlocks = []
                continue
            }
            currentBlocks.append(block)
        }
        if !currentBlocks.isEmpty || currentPage > 0 {
            pages.append(ExtractedPage(number: currentPage, blocks: currentBlocks))
        }
        return pages.isEmpty ? [ExtractedPage(number: 0, blocks: Markdownish.parse(text))] : pages
    }

    static func pageNumber(from heading: String) -> Int? {
        guard heading.lowercased().hasPrefix("page ") else { return nil }
        return Int(heading.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Helpers

    /// Expands dropped items into individual files, descending one level into
    /// folders so a dropped directory works the same as "Import folder".
    static func expand(_ urls: [URL]) -> [URL] {
        var output: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                output.append(contentsOf: documents(in: url))
            } else {
                output.append(url)
            }
        }
        return Array(Set(output)).sorted { $0.path < $1.path }
    }

    /// Every supported document in a folder tree, skipping hidden files and
    /// packages. Recursive, because research folders nest.
    public static func documents(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var output: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            if DocumentExtractor.kind(for: url) != nil { output.append(url) }
        }
        return output.sorted { $0.path < $1.path }
    }

    static func titleFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host() else { return urlString }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return host }
        let last = path.components(separatedBy: "/").last ?? host
        let readable = last
            .replacingOccurrences(of: ".html", with: "")
            .replacingOccurrences(of: ".htm", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return readable.isEmpty ? host : readable
    }

    static func mimeType(for kind: SourceKind) -> String? {
        switch kind {
        case .pdf: return "application/pdf"
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .rtf: return "application/rtf"
        case .epub: return "application/epub+zip"
        case .markdown: return "text/markdown"
        case .plainText, .pastedText: return "text/plain"
        case .html: return "text/html"
        case .website, .folder: return nil
        }
    }
}
