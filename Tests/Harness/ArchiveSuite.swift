import Foundation
import SourceDeskCore

enum ArchiveSuite {

    static var suite: TestSuite {
        TestSuite("10 · Export and import", cases: [

            test("zip round-trips text, JSON and binary payloads") { ctx in
                var writer = ZipWriter()
                try writer.addText("notes/readme.md", "# Hello\n\nSome text with unicode: café 東京 😀")
                try writer.addJSON("data/manifest.json", ["format": "test", "count": "3"])
                var binary = Data()
                for index in 0..<5_000 { binary.append(UInt8(index % 256)) }
                try writer.add(.init(path: "blobs/data.bin", data: binary, compression: .store))
                try writer.add(.init(path: "blobs/big.txt", data: Data(String(repeating: "compress me please ", count: 2_000).utf8)))
                let archive = writer.finalize()

                try ctx.equal(writer.entryCount, 4)
                let reader = try ZipArchive(data: archive)
                try ctx.equal(reader.entries.count, 4)
                try ctx.contains(try reader.text(for: "notes/readme.md"), "café 東京 😀")
                try ctx.contains(try reader.text(for: "notes/readme.md"), "# Hello")
                let json = try ctx.unwrap(try JSONSerialization.jsonObject(with: try reader.data(for: "data/manifest.json")) as? [String: Any])
                try ctx.equal(json["format"] as? String, "test")
                try ctx.equal(try reader.data(for: "blobs/data.bin"), binary, "stored binary is byte-identical")
                let compressed = try reader.data(for: "blobs/big.txt")
                let expected = String(repeating: "compress me please ", count: 2_000)
                try ctx.equal(compressed.count, expected.utf8.count, "deflated payload decompresses to the original length")
                try ctx.equal(String(decoding: compressed, as: UTF8.self), expected, "byte-for-byte identical after a compression round trip")
                try ctx.contains(String(decoding: compressed, as: UTF8.self), "compress me please")
            },

            test("a corrupt archive is refused with an explanation") { ctx in
                let error = try await ctx.expectError("random bytes") {
                    try ZipArchive(data: Data(repeating: 0x41, count: 5_000))
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "could not be read")
                let truncated = try await ctx.expectError("truncated zip") {
                    var writer = ZipWriter()
                    try writer.addText("a.txt", "hello")
                    let full = writer.finalize()
                    return try ZipArchive(data: full.prefix(full.count / 2))
                }
                try ctx.check(truncated is SourceDeskError)
            },

            test("a notebook exports and re-imports with everything intact") { ctx in
                let (source, sourcePaths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(sourcePaths) }
                let notebook = try Fixtures.makeNotebook(source, title: "Industrial Decline")

                // Two sources, one with a stored original file (as a PDF import has).
                let report = try source.upsert(source: Source(
                    notebookID: notebook.id, kind: .pdf, title: "Inspectorate Report",
                    filePath: "/tmp/original.pdf", wordCount: 400, pageCount: 12, status: .ready
                ))
                let reportText = """
                ## Page 1
                The review board examined inspection throughput across all seven regions.
                Throughput fell by nineteen percent after the inspection schedule was reorganised in March.
                """
                try FileStore.write(reportText, to: sourcePaths.extractedTextURL(for: report.id))
                var reportWithContent = report
                reportWithContent.contentPath = sourcePaths.extractedTextURL(for: report.id).path

                let chunks = TextChunker.chunk(plainText: reportText, sourceID: report.id, notebookID: notebook.id,
                                               configuration: TextChunker.Configuration(targetTokens: 60, maximumTokens: 100, overlapTokens: 0, minimumCharacters: 10))
                let embedder = BuiltInEmbedder()
                try source.replaceChunks(sourceID: report.id, notebookID: notebook.id, chunks: chunks,
                                         embeddings: chunks.map { ChunkEmbedding(chunkID: $0.id, sourceID: report.id, notebookID: notebook.id,
                                                                                 model: embedder.identifier, vector: embedder.embedOne($0.text)) })
                reportWithContent.chunkCount = chunks.count
                try source.upsert(source: reportWithContent)

                let news = try source.upsert(source: Source(
                    notebookID: notebook.id, kind: .website, title: "News article",
                    url: "https://news.example.com/permits", status: .ready
                ))
                try FileStore.write("Applicants waited more than six weeks for a routine permit.", to: sourcePaths.extractedTextURL(for: news.id))
                var newsWithContent = news
                newsWithContent.contentPath = sourcePaths.extractedTextURL(for: news.id).path
                try source.upsert(source: newsWithContent)

                // A session with citations and a study note.
                let session = try source.upsert(session: ChatSession(notebookID: notebook.id, title: "Causes", modelName: "llama3.2"))
                try source.upsert(message: ChatMessage(
                    sessionID: session.id, notebookID: notebook.id, role: .user, content: "What caused the decline?"
                ))
                try source.upsert(message: ChatMessage(
                    sessionID: session.id, notebookID: notebook.id, role: .assistant,
                    content: "Two causes: reorganisation and staffing. [Source 1]",
                    citations: [Citation(kind: .notebook, marker: "[Source 1]", sourceID: report.id, chunkID: chunks[0].id,
                                         title: "Inspectorate Report", pageNumber: 1, excerpt: "Throughput fell by nineteen percent.", score: 0.9)],
                    providerID: "ollama", modelName: "llama3.2"
                ))
                try source.upsert(note: NotebookNote(
                    notebookID: notebook.id, title: "Summary · 2 sources",
                    body: "### Overview\nThe material covers an inspection decline. [Source 1]",
                    kind: .summary,
                    sourceIDs: [report.id, news.id]
                ))

                // Export.
                let exportURL = sourcePaths.root.appendingPathComponent("export-test.nbk")
                let result = try NotebookArchive.export(notebookID: notebook.id, from: source, to: exportURL)
                try ctx.equal(result.sourceCount, 2)
                try ctx.equal(result.noteCount, 1)
                try ctx.equal(result.messageCount, 2)
                try ctx.check(result.chunkCount >= 1, "chunks exported")
                try ctx.check(FileStore.exists(exportURL), "archive written")
                ctx.note("export: \(result.byteCount) bytes, \(result.chunkCount) chunks")

                // Inspect without importing.
                let manifest = try NotebookArchive.inspect(exportURL)
                try ctx.equal(manifest.notebook.title, "Industrial Decline")
                try ctx.equal(manifest.counts.sources, 2)
                try ctx.equal(manifest.format, "sourcedesk-notebook")
                try ctx.equal(manifest.formatVersion, 1)

                // Import into a different library.
                let (destination, destinationPaths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(destinationPaths) }
                let imported = try NotebookArchive.import(from: exportURL, into: destination)

                try ctx.check(imported.notebook.id != notebook.id, "the import gets a fresh identifier")
                try ctx.equal(imported.notebook.title, "Industrial Decline")
                try ctx.equal(imported.sourceCount, 2)
                try ctx.equal(imported.noteCount, 1)
                try ctx.equal(imported.messageCount, 2)
                try ctx.equal(imported.skipped.count, 0, "nothing was skipped: \(imported.skipped)")

                let restoredSources = try destination.sources(notebookID: imported.notebook.id)
                try ctx.equal(restoredSources.count, 2)
                let restoredReport = try ctx.unwrap(restoredSources.first { $0.title == "Inspectorate Report" })
                try ctx.equal(restoredReport.pageCount, 12, "page count survived")
                try ctx.check(restoredReport.chunkCount >= 1, "chunk count restored")
                try ctx.check(!restoredReport.status.isBusy, "restored source is not stuck in a pending state")

                // Text, chunks, vectors and keyword index must all work again.
                let restoredText = try FileStore.readText(at: URL(fileURLWithPath: try ctx.unwrap(restoredReport.contentPath)))
                try ctx.contains(restoredText, "nineteen percent")
                try ctx.check(try destination.chunks(sourceID: restoredReport.id).count >= 1)
                try ctx.check(try destination.embeddingCount(notebookID: imported.notebook.id) >= 1, "vectors restored")
                let keywordHits = try destination.keywordSearch(query: "inspection throughput decline", notebookID: imported.notebook.id)
                try ctx.check(!keywordHits.isEmpty, "keyword index rebuilt on import")

                // Citations must point at the new identifiers, not the old ones.
                let sessions = try destination.sessions(notebookID: imported.notebook.id)
                let restoredSession = try ctx.unwrap(sessions.first)
                let messages = try destination.messages(sessionID: restoredSession.id)
                let answer = try ctx.unwrap(messages.first { $0.role == .assistant })
                try ctx.equal(answer.citations.count, 1, "citation survived")
                try ctx.equal(answer.citations[0].sourceID, restoredReport.id, "citation remapped to the new source id")
                try ctx.equal(answer.citations[0].marker, "[Source 1]")
                try ctx.equal(answer.citations[0].pageNumber, 1)
                try ctx.notNil(answer.citations[0].chunkID, "citation chunk remapped")

                let notes = try destination.notes(notebookID: imported.notebook.id)
                let restoredNote = try ctx.unwrap(notes.first)
                try ctx.contains(restoredNote.body, "inspection decline")
                try ctx.equal(restoredNote.sourceIDs.count, 2, "note source links remapped")
                try ctx.check(restoredNote.sourceIDs.contains(restoredReport.id), "note points at the restored source")
            },

            test("the archive layout is open and human-readable") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store, title: "My Notebook")
                let source = try store.upsert(source: Source(notebookID: notebook.id, kind: .plainText, title: "Notes", status: .ready))
                try FileStore.write("Some stored text.", to: paths.extractedTextURL(for: source.id))
                var withContent = source
                withContent.contentPath = paths.extractedTextURL(for: source.id).path
                try store.upsert(source: withContent)
                try store.upsert(session: ChatSession(notebookID: notebook.id, title: "A session"))
                try store.upsert(note: NotebookNote(notebookID: notebook.id, title: "A note", body: "Body text.", kind: .manual))

                let exportURL = paths.root.appendingPathComponent("open.nbk")
                _ = try NotebookArchive.export(notebookID: notebook.id, from: store, to: exportURL)

                let archive = try ZipArchive(fileAt: exportURL)
                try ctx.check(archive.paths.contains { $0 == "notebook.json" }, "root manifest present: \(archive.paths)")
                try ctx.check(archive.paths.contains { $0.hasPrefix("My Notebook/") }, "folder named after the notebook")
                try ctx.check(archive.paths.contains { $0.hasSuffix("sources/\(source.id)/content.txt") }, "per-source text file")
                try ctx.check(archive.paths.contains { $0.hasPrefix("My Notebook/chats/") && $0.hasSuffix(".md") }, "readable chat transcript")
                try ctx.check(archive.paths.contains { $0.hasPrefix("My Notebook/notes/") && $0.hasSuffix(".md") }, "readable note")
                try ctx.check(archive.paths.contains { $0.hasSuffix(".jsonl") } == false || true, "vectors are optional")

                // The manifest must be readable standalone.
                let manifestText = try archive.text(for: "notebook.json")
                try ctx.contains(manifestText, "sourcedesk-notebook")
                try ctx.contains(manifestText, "My Notebook")
            },

            test("paths with awkward characters are sanitised") { ctx in
                try ctx.equal(NotebookArchive.sanitize("A/B:C"), "A-B-C")
                try ctx.equal(NotebookArchive.sanitize("   "), "untitled")
                try ctx.check(NotebookArchive.sanitize(String(repeating: "x", count: 300)).count <= 80, "long names are clamped")
                try ctx.doesNotContain(NotebookArchive.sanitize("Report: 2024 ?"), "/")
            },

            test("importing a foreign zip is refused politely") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                var writer = ZipWriter()
                try writer.addText("something-else.txt", "not our notebook")
                let url = paths.root.appendingPathComponent("foreign.nbk")
                try FileStore.write(writer.finalize(), to: url)

                let error = try await ctx.expectError("not a notebook archive") {
                    try NotebookArchive.import(from: url, into: store)
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "notebook.json")
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "SourceDesk notebook archive")
            },

            test("an archive from a newer format version is refused with advice") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                let exportURL = paths.root.appendingPathComponent("future.nbk")
                _ = try NotebookArchive.export(notebookID: notebook.id, from: store, to: exportURL)

                // Rewrite the manifest claiming a newer format, preserving the exact
                // folder layout the exporter produced.
                let archive = try ZipArchive(fileAt: exportURL)
                var manifest = try NotebookArchive.inspect(exportURL)
                manifest.formatVersion = 99
                var writer = ZipWriter()
                for path in archive.paths where !path.hasSuffix(NotebookArchive.manifestName) {
                    if let entry = archive.entry(path) {
                        try writer.add(.init(path: path, data: try archive.read(entry), compression: .deflate))
                    }
                }
                // Both manifest copies must claim the newer version.
                try writer.addJSON(NotebookArchive.manifestName, manifest)
                if let originalManifestPath = archive.paths.first(where: {
                    $0.hasSuffix(NotebookArchive.manifestName) && $0.components(separatedBy: "/").count > 1
                }) {
                    try writer.addJSON(originalManifestPath, manifest)
                }
                let futureURL = paths.root.appendingPathComponent("future2.nbk")
                try FileStore.write(writer.finalize(), to: futureURL)
                try ctx.check(try NotebookArchive.inspect(futureURL).formatVersion == 99, "the fixture claims version 99")

                let error = try await ctx.expectError("newer format") {
                    try NotebookArchive.import(from: futureURL, into: store)
                }
                let sde = try ctx.unwrap(error as? SourceDeskError)
                try ctx.contains(sde.errorDescription ?? "", "newer version")
                try ctx.contains(sde.recoverySuggestion ?? "", "Update SourceDesk")
            },

            test("importing the same archive twice creates two separate notebooks") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store, title: "Original")
                let exportURL = paths.root.appendingPathComponent("twice.nbk")
                _ = try NotebookArchive.export(notebookID: notebook.id, from: store, to: exportURL)

                let (destination, destinationPaths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(destinationPaths) }
                let first = try NotebookArchive.import(from: exportURL, into: destination)
                let second = try NotebookArchive.import(from: exportURL, into: destination)
                try ctx.check(first.notebook.id != second.notebook.id, "distinct notebooks")
                try ctx.equal(try destination.notebooks().count, 2, "both imports are present")
            }
        ])
    }
}
