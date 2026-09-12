import Foundation

/// Notebook export and import.
///
/// The archive is an open, documented structure — a plain zip that `unzip` and any
/// text editor can read:
///
///     Notebook/
///     ├── notebook.json      notebook, sources, sessions, notes, and their metadata
///     ├── sources/<id>/content.txt, original.pdf
///     ├── chats/<session>.md and .json
///     ├── notes/<note>.md
///     └── embeddings/vectors.jsonl
///
/// API keys, Keychain contents and application settings are never included.
public enum NotebookArchive {

    public static let manifestName = "notebook.json"
    public static let formatVersion = 1
    public static let fileExtension = "nbk"

    // MARK: - Manifest

    public struct Manifest: Codable, Sendable {
        public var format: String
        public var formatVersion: Int
        public var generator: String
        public var exportedAt: Date
        public var notebook: Notebook
        public var sources: [SourceRecord]
        public var sessions: [SessionRecord]
        public var notes: [NoteRecord]
        public var embeddingModels: [String]
        public var counts: Counts

        public struct Counts: Codable, Sendable {
            public var sources: Int
            public var chunks: Int
            public var embeddings: Int
            public var sessions: Int
            public var messages: Int
            public var notes: Int
            public var contentBytes: Int64
        }

        public struct SourceRecord: Codable, Sendable {
            public var source: Source
            public var chunks: [SourceChunk]
            public var contentFile: String?
            public var originalFile: String?
        }

        public struct SessionRecord: Codable, Sendable {
            public var session: ChatSession
            public var messages: [ChatMessage]
        }

        public struct NoteRecord: Codable, Sendable {
            public var note: NotebookNote
        }
    }

    // MARK: - Export

    public struct ExportOptions: Sendable {
        /// Include the original downloaded bytes (PDFs etc.) as well as extracted text.
        public var includeOriginalFiles: Bool
        /// Include stored vectors, so an import on another Mac does not have to
        /// re-embed everything.
        public var includeEmbeddings: Bool
        /// Write human-readable Markdown copies of notes and chats alongside JSON.
        public var includeMarkdownCopies: Bool

        public init(includeOriginalFiles: Bool = true, includeEmbeddings: Bool = true, includeMarkdownCopies: Bool = true) {
            self.includeOriginalFiles = includeOriginalFiles
            self.includeEmbeddings = includeEmbeddings
            self.includeMarkdownCopies = includeMarkdownCopies
        }

        public static let `default` = ExportOptions()
    }

    public struct ExportResult: Sendable {
        public var url: URL
        public var byteCount: Int64
        public var sourceCount: Int
        public var chunkCount: Int
        public var noteCount: Int
        public var messageCount: Int
    }

    /// Writes a `.nbk` archive for a notebook.
    public static func export(
        notebookID: RecordID,
        from store: NotebookStore,
        to destination: URL,
        options: ExportOptions = .default,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ExportResult {
        guard let notebook = try store.notebook(id: notebookID) else {
            throw SourceDeskError.notFound(entity: "notebook", id: notebookID)
        }
        let sources = try store.sources(notebookID: notebookID)
        let sessions = try store.sessions(notebookID: notebookID)
        let notes = try store.notes(notebookID: notebookID)

        var writer = ZipWriter()
        let folder = Self.sanitize(notebook.title)
        var manifest = Manifest(
            format: "sourcedesk-notebook",
            formatVersion: formatVersion,
            generator: "SourceDesk \(AppInfo.version)",
            exportedAt: Date(),
            notebook: notebook,
            sources: [],
            sessions: [],
            notes: [],
            embeddingModels: [],
            counts: Manifest.Counts(sources: 0, chunks: 0, embeddings: 0, sessions: 0, messages: 0, notes: 0, contentBytes: 0)
        )

        var totalChunks = 0
        var totalEmbeddings = 0
        var allModels = Set<String>()
        let steps = Double(max(1, sources.count + sessions.count + notes.count))
        var completed = 0.0

        // Sources: metadata, chunks, extracted text, optional original file.
        for source in sources {
            var record = Manifest.SourceRecord(source: source, chunks: [], contentFile: nil, originalFile: nil)
            let chunks = try store.chunks(sourceID: source.id)
            record.chunks = chunks
            totalChunks += chunks.count

            let sourceFolder = "\(folder)/sources/\(source.id)"
            if let contentPath = source.contentPath, FileStore.exists(URL(fileURLWithPath: contentPath)),
               let content = try? Data(contentsOf: URL(fileURLWithPath: contentPath)) {
                let name = "\(sourceFolder)/content.txt"
                try writer.add(.init(path: name, data: content))
                record.contentFile = "sources/\(source.id)/content.txt"
            }
            if options.includeOriginalFiles, let filePath = source.filePath {
                let originalURL = URL(fileURLWithPath: filePath)
                if FileStore.exists(originalURL), let data = try? Data(contentsOf: originalURL, options: .mappedIfSafe) {
                    let name = "\(sourceFolder)/original-\(sanitize(originalURL.lastPathComponent))"
                    // Originals are usually already compressed; storing them is faster
                    // and avoids pointless CPU on a big PDF.
                    try writer.add(.init(path: name, data: data, compression: .store))
                    record.originalFile = "sources/\(source.id)/original-\(sanitize(originalURL.lastPathComponent))"
                }
            } else if let original = storedOriginal(for: source, store: store) {
                let name = "\(sourceFolder)/original-\(sanitize(original.lastPathComponent))"
                if let data = try? Data(contentsOf: original, options: .mappedIfSafe) {
                    try writer.add(.init(path: name, data: data, compression: .store))
                    record.originalFile = "sources/\(source.id)/original-\(sanitize(original.lastPathComponent))"
                }
            }

            if options.includeEmbeddings {
                let embeddings = try store.embeddings(sourceID: source.id)
                if !embeddings.isEmpty {
                    for embedding in embeddings { allModels.insert(embedding.model) }
                    totalEmbeddings += embeddings.count
                    try writer.add(.init(
                        path: "\(folder)/embeddings/\(source.id).jsonl",
                        data: Data(Self.embeddingLines(embeddings).utf8)
                    ))
                }
            }

            manifest.sources.append(record)
            completed += 1
            progress?(completed / steps)
        }

        // Chats: JSON plus a readable transcript.
        for session in sessions {
            let messages = try store.messages(sessionID: session.id)
            manifest.sessions.append(.init(session: session, messages: messages))
            if options.includeMarkdownCopies {
                let name = "\(folder)/chats/\(sanitize(session.title))-\(session.id.prefix(8)).md"
                try writer.addText(name, Self.transcript(session: session, messages: messages))
            }
            completed += 1
            progress?(completed / steps)
        }

        // Notes.
        for note in notes {
            manifest.notes.append(.init(note: note))
            if options.includeMarkdownCopies {
                let frontMatter = """
                ---
                title: \(note.title)
                kind: \(note.kind.rawValue)
                created: \(ISO8601DateFormatter().string(from: note.createdAt))
                model: \(note.modelName ?? "unknown")
                ---

                """
                try writer.addText("\(folder)/notes/\(sanitize(note.title))-\(note.id.prefix(8)).md", frontMatter + note.body)
            }
            completed += 1
            progress?(completed / steps)
        }

        manifest.embeddingModels = allModels.sorted()
        manifest.counts = Manifest.Counts(
            sources: sources.count,
            chunks: totalChunks,
            embeddings: totalEmbeddings,
            sessions: sessions.count,
            messages: manifest.sessions.reduce(0) { $0 + $1.messages.count },
            notes: notes.count,
            contentBytes: sources.reduce(0) { $0 + $1.plainTextBytes }
        )

        try writer.addJSON("\(folder)/\(manifestName)", manifest)
        // A second copy at the archive root means the file is self-describing even
        // if someone renames the folder inside it.
        try writer.addJSON(manifestName, manifest)

        let data = writer.finalize()
        try FileStore.write(data, to: destination)

        return ExportResult(
            url: destination,
            byteCount: Int64(data.count),
            sourceCount: sources.count,
            chunkCount: totalChunks,
            noteCount: notes.count,
            messageCount: manifest.counts.messages
        )
    }

    static func storedOriginal(for source: Source, store: NotebookStore) -> URL? {
        let directory = store.paths.contentDirectory(for: source.id)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return contents.first { $0.lastPathComponent.hasPrefix("original-") }
    }

    static func embeddingLines(_ embeddings: [ChunkEmbedding]) -> String {
        embeddings.map { embedding in
            let object: [String: Any] = [
                "chunkID": embedding.chunkID,
                "sourceID": embedding.sourceID,
                "model": embedding.model,
                "dimensions": embedding.dimensions,
                "vector": embedding.vector.map { Double($0) }
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    static func transcript(session: ChatSession, messages: [ChatMessage]) -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("_Scope: \(session.scope.displayName) · Model: \(session.modelName ?? "unknown")_")
        lines.append("")
        for message in messages {
            switch message.role {
            case .user:
                lines.append("## You")
            case .assistant:
                lines.append("## SourceDesk")
            case .system:
                lines.append("## System")
            }
            lines.append("")
            lines.append(message.content)
            if !message.citations.isEmpty {
                lines.append("")
                lines.append("**Sources**")
                for citation in message.citations {
                    var description = "- \(citation.marker) \(citation.title)"
                    if let page = citation.pageNumber { description += " (page \(page))" }
                    if let url = citation.url { description += " — \(url)" }
                    lines.append(description)
                }
            }
            if message.isError, let error = message.errorMessage {
                lines.append("")
                lines.append("> **Error:** \(error)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Import

    public struct ImportResult: Sendable {
        public var notebook: Notebook
        public var sourceCount: Int
        public var chunkCount: Int
        public var noteCount: Int
        public var messageCount: Int
        /// Source titles that could not be restored, with the reason.
        public var skipped: [(title: String, reason: String)]
    }

    /// Reads a `.nbk` archive into the library. The notebook is always imported
    /// under a fresh identifier, so importing the same file twice creates two
    /// notebooks rather than overwriting existing work.
    public static func `import`(
        from url: URL,
        into store: NotebookStore,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ImportResult {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(fileAt: url)
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw SourceDeskError.archiveCorrupt(detail: error.localizedDescription)
        }

        guard let manifestPath = archive.paths.first(where: { $0.hasSuffix(manifestName) && $0.components(separatedBy: "/").count <= 2 })
                ?? archive.paths.first(where: { $0.hasSuffix(manifestName) }) else {
            // The whole notebook is written by the manifest; a missing one is the only
            // reason this archive is unusable, so say that specifically.
            throw SourceDeskError.archiveCorrupt(detail: "No \(manifestName) found — this is not a SourceDesk notebook archive.")
        }
        let manifestData: Data
        do {
            manifestData = try archive.data(for: manifestPath)
        } catch {
            throw SourceDeskError.archiveCorrupt(detail: "The \(manifestName) entry could not be read from the archive.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: Manifest
        do {
            manifest = try decoder.decode(Manifest.self, from: manifestData)
        } catch {
            throw SourceDeskError.archiveCorrupt(detail: "The manifest could not be read: \(error.localizedDescription)")
        }

        guard manifest.format == "sourcedesk-notebook" else {
            throw SourceDeskError.archiveCorrupt(detail: "Unexpected format “\(manifest.format)”.")
        }
        guard manifest.formatVersion <= formatVersion else {
            throw SourceDeskError.archiveCorrupt(detail: "This notebook was exported by a newer version of SourceDesk (format \(manifest.formatVersion)). Update the app to open it.")
        }

        let prefix = (manifestPath as NSString).deletingLastPathComponent
        let notebookID = Identifiers.new()

        var notebook = manifest.notebook
        notebook.id = notebookID
        notebook.updatedAt = Date()
        notebook.createdAt = manifest.notebook.createdAt
        try store.upsert(notebook: notebook)

        var sourceIDMap: [RecordID: RecordID] = [:]
        var chunkIDMap: [RecordID: RecordID] = [:]
        var skipped: [(String, String)] = []
        var chunkTotal = 0

        let steps = Double(max(1, manifest.sources.count + manifest.notes.count + manifest.sessions.count))
        var completed = 0.0

        for record in manifest.sources {
            let newID = Identifiers.new()
            sourceIDMap[record.source.id] = newID

            var source = record.source
            source.id = newID
            source.notebookID = notebookID
            // Paths from the exporting Mac are meaningless here; they are replaced
            // below with this library's locations. Leaving them in place would make
            // the restored source point at another machine's disk.
            source.contentPath = nil
            source.filePath = nil

            // Restore extracted text.
            if let contentFile = record.contentFile {
                let path = prefix.isEmpty ? contentFile : "\(prefix)/\(contentFile)"
                if let data = try? archive.data(for: path) {
                    let destination = store.paths.extractedTextURL(for: newID)
                    try? FileStore.write(data, to: destination)
                    source.contentPath = destination.path
                } else {
                    skipped.append((source.title, "extracted text missing from the archive"))
                }
            }

            // Restore the original file where one was included.
            if let originalFile = record.originalFile {
                let path = prefix.isEmpty ? originalFile : "\(prefix)/\(originalFile)"
                if let data = try? archive.data(for: path) {
                    let name = (originalFile as NSString).lastPathComponent
                    let destination = store.paths.originalFileURL(for: newID, fileName: name)
                    try? FileStore.write(data, to: destination)
                    source.filePath = destination.path
                }
            }

            // Rebuild chunks with fresh identifiers, preserving everything that makes
            // a citation useful.
            let chunks = record.chunks.map { chunk -> SourceChunk in
                var copy = chunk
                copy.id = Identifiers.new()
                chunkIDMap[chunk.id] = copy.id
                copy.sourceID = newID
                copy.notebookID = notebookID
                return copy
            }
            chunkTotal += chunks.count

            // Restore vectors only when they were stored in this archive.
            var embeddings: [ChunkEmbedding] = []
            let embeddingPath = "\(prefix.isEmpty ? "" : prefix + "/")embeddings/\(record.source.id).jsonl"
            if let data = try? archive.data(for: embeddingPath),
               let text = String(data: data, encoding: .utf8) {
                embeddings = parseEmbeddingLines(text, chunkIDMap: chunkIDMap, sourceID: newID, notebookID: notebookID)
            }
            // The source row must be written before its chunks: `chunks.source_id`
            // and `embeddings.chunk_id` are foreign keys, so inserting chunks first
            // would fail and lose the whole restored source.
            do {
                try store.upsert(source: source)
                try store.replaceChunks(sourceID: newID, notebookID: notebookID, chunks: chunks, embeddings: embeddings)
                source.chunkCount = chunks.count
                source.status = .ready
                source.statusDetail = nil
                source.errorMessage = nil
                source.errorRecovery = nil
                try store.upsert(source: source)
            } catch let error as SourceDeskError {
                source.status = .failed
                source.errorMessage = error.errorDescription
                source.errorRecovery = error.recoverySuggestion
                try? store.upsert(source: source)
                skipped.append((source.title, error.errorDescription ?? "could not be written"))
            }

            completed += 1
            progress?(completed / steps)
        }

        for record in manifest.notes {
            var note = record.note
            note.id = Identifiers.new()
            note.notebookID = notebookID
            note.sourceIDs = note.sourceIDs.compactMap { sourceIDMap[$0] }
            try store.upsert(note: note)
            completed += 1
            progress?(completed / steps)
        }

        var messageCount = 0
        for record in manifest.sessions {
            var session = record.session
            session.id = Identifiers.new()
            session.notebookID = notebookID
            try store.upsert(session: session)

            for message in record.messages {
                var copy = message
                copy.id = Identifiers.new()
                copy.sessionID = session.id
                copy.notebookID = notebookID
                copy.citations = copy.citations.map { citation in
                    var updated = citation
                    updated.id = Identifiers.new()
                    updated.sourceID = citation.sourceID.flatMap { sourceIDMap[$0] }
                    updated.chunkID = citation.chunkID.flatMap { chunkIDMap[$0] }
                    return updated
                }
                try store.upsert(message: copy)
                messageCount += 1
            }
            completed += 1
            progress?(completed / steps)
        }

        return ImportResult(
            notebook: notebook,
            sourceCount: manifest.sources.count,
            chunkCount: chunkTotal,
            noteCount: manifest.notes.count,
            messageCount: messageCount,
            skipped: skipped
        )
    }

    static func parseEmbeddingLines(
        _ text: String,
        chunkIDMap: [RecordID: RecordID],
        sourceID: RecordID,
        notebookID: RecordID
    ) -> [ChunkEmbedding] {
        var output: [ChunkEmbedding] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oldChunkID = object["chunkID"] as? String,
                  let newChunkID = chunkIDMap[oldChunkID],
                  let model = object["model"] as? String,
                  let vector = object["vector"] as? [Double] else { continue }
            output.append(ChunkEmbedding(
                chunkID: newChunkID,
                sourceID: sourceID,
                notebookID: notebookID,
                model: model,
                vector: vector.map(Float.init)
            ))
        }
        return output
    }

    /// Inspects an archive without importing it, for the import preview sheet.
    public static func inspect(_ url: URL) throws -> Manifest {
        let archive = try ZipArchive(fileAt: url)
        guard let manifestPath = archive.paths.first(where: { $0.hasSuffix(manifestName) && $0.components(separatedBy: "/").count <= 2 })
                ?? archive.paths.first(where: { $0.hasSuffix(manifestName) }) else {
            throw SourceDeskError.archiveCorrupt(detail: "No \(manifestName) found in this archive.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Manifest.self, from: try archive.data(for: manifestPath))
        } catch {
            throw SourceDeskError.archiveCorrupt(detail: "The manifest could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    public static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep file names comfortably inside every filesystem's limit.
        return cleaned.isEmpty ? "untitled" : String(cleaned.prefix(80))
    }
}

public enum AppInfo {
    public static let name = "SourceDesk"
    public static let version = "1.0.0"
    public static let tagline = "A local-first AI research notebook for macOS"
    public static let repository = "https://github.com/sourcedesk/sourcedesk"
}
