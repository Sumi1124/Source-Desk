import Foundation
import SourceDeskCore

enum DebugScratch {
    static func run() throws {
        print("--- duplicate URL ingest ---")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-dup-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        let store = try NotebookStore(paths: paths)
        let notebook = try store.upsert(notebook: Notebook(title: "Dup"))

        let server = LocalHTTPServer { request in
            if request.path == "/robots.txt" { return .text("User-agent: *\nAllow: /\n") }
            return .text("<html><body><article><h1>Article</h1><p>A body paragraph with sufficient words to be extracted as real prose from the page.</p></article></body></html>", contentType: "text/html")
        }
        try server.start()
        defer { server.stop() }

        let service = SourceIngestionService(store: store, configuration: .default, embedder: BuiltInEmbedder())
        let url = "\(server.baseURL.absoluteString)/page"
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            for round in 1...3 {
                let result = await service.ingest(request: .website(url: url, title: nil), notebookID: notebook.id)
                let outcome = result.results.first
                print("round \(round): sources now =\(try! store.sourceCount(notebookID: notebook.id)) finalURL=\(outcome?.source.url ?? "nil") status=\(outcome?.source.status.rawValue ?? "nil")")
            }
            let all = try! store.sources(notebookID: notebook.id)
            for s in all { print("  row: id=\(s.id.prefix(8)) url=\(s.url ?? "nil") title=\(s.title) nb=\(s.notebookID.prefix(8))") }
            print("  direct lookup by url:", try! store.source(matchingURL: "\(server.baseURL.absoluteString)/page", notebookID: notebook.id)?.id.prefix(8) ?? "nil")
            let raw = try! store.db.query("SELECT id, notebook_id, url FROM sources;") { r in "\(r.string(0)!.prefix(8))|\(r.string(1)!.prefix(8))|\(r.string(2) ?? "NULL")" }
            for line in raw { print("  raw:", line) }
            print("  notebook id:", notebook.id.prefix(8))
            print("  count via query:", try! store.db.scalarInt("SELECT COUNT(*) FROM sources WHERE url = ?;", [.text("\(server.baseURL.absoluteString)/page")]))
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        try? FileManager.default.removeItem(at: root)
        print("--- done ---")
    }
}
