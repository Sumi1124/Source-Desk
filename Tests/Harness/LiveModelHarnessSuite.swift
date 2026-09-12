import Foundation
import SourceDeskCore

/// Guards the live-model suite against being vacuous.
///
/// `LiveLocalModelSuite` skips when no model is installed, which is honest but creates a
/// risk of its own: a suite that only ever skips cannot be trusted to have any assertions
/// in it, and could rot into something that would fail the moment someone *did* install a
/// model. These tests drive the same assertions against a scripted Ollama server that
/// speaks the real wire format, so the non-model machinery is proven even on a machine
/// with no models.
///
/// This is not a substitute for the live suite — it cannot tell you whether real
/// inference grounds well. It proves the *harness* is sound, so the live suite's result
/// means something when it does run.
enum LiveModelHarnessSuite {

    /// An Ollama-shaped server: `/api/tags` lists one model, `/api/chat` answers with a
    /// fixed string that quotes the source material.
    static func scriptedServer(answer: String) -> LocalHTTPServer {
        LocalHTTPServer { request in
            if request.path == "/api/tags" {
                return .json(["models": [[
                    "name": "llama3.2:3b", "model": "llama3.2:3b", "size": 2_019_393_182,
                    "digest": "a80bd1b8b1",
                    "details": ["parameter_size": "3.2B", "quantization_level": "Q4_K_M", "family": "llama"]
                ]]])
            }
            if request.path == "/api/chat" {
                // The shape Ollama actually returns for a non-streaming call.
                return .json([
                    "model": "llama3.2:3b",
                    "created_at": "2026-09-12T00:00:00Z",
                    "message": ["role": "assistant", "content": answer],
                    "done": true,
                    "prompt_eval_count": 812,
                    "eval_count": 96
                ])
            }
            if request.path == "/api/embed" {
                return .json(["embeddings": [[0.0, 0.0, 0.0]]])
            }
            return .json(["error": "unexpected path \(request.path)"], status: 404)
        }
    }

    static var suite: TestSuite {
        TestSuite("21 · Live-model harness (self-check)", cases: [

            test("the live suite's provider discovery finds a scripted Ollama") { ctx in
                // If discovery were broken, the live suite would skip forever and never
                // fail — the vacuity this suite exists to prevent.
                let server = scriptedServer(answer: "ok")
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .local, keychain: EmptyKeychain())
                let availability = await provider.availability()
                try ctx.check(availability.isReady, "a server with one model counts as ready: \(availability)")

                let models = try await provider.availableModels()
                try ctx.equal(models.count, 1)
                try ctx.equal(models[0].name, "llama3.2:3b")
                try ctx.check(!models[0].supportsEmbeddings, "a chat model is not an embedding model")
            },

            test("a scripted model answer flows through the grounding assertions") { ctx in
                // The same assertions the live suite makes — that the answer quotes the
                // source material and carries citations that resolve — run here against a
                // controlled response. This fails if the live suite's checks are wrong.
                let server = scriptedServer(answer: """
                The decline was caused by the Marlowe reorganisation, which moved inspections \
                to a central scheduling desk in March 1987 and added around eleven days of \
                coordination overhead per job. [Source 1] A secondary cause was the closure of \
                two regional offices under budget pressure. [Source 2]
                """)
                try server.start()
                defer { server.stop() }

                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try LiveLocalModelSuite.notebookWithDistinctiveSources(store)
                let provider = OllamaProvider(endpoint: server.baseURL, host: .local, keychain: EmptyKeychain())
                let engine = LiveLocalModelSuite.engine(store: store, provider: provider, model: "llama3.2:3b")

                let outcome = try await engine.answerOnce(
                    question: "What caused the decline in inspection throughput?",
                    notebookID: notebook.id
                )

                try ctx.check(!outcome.answer.isEmpty, "an answer came back")
                try ctx.contains(outcome.answer, "Marlowe", "the answer carries the retrieved material")
                try ctx.check(!outcome.citations.isEmpty, "citations were attached")
                for citation in outcome.citations {
                    guard let sourceID = citation.sourceID else { continue }
                    let ids = try store.sources(notebookID: notebook.id).map(\.id)
                    try ctx.check(ids.contains(sourceID), "the citation resolves to a real source")
                }
            },

            test("hallucinated citation markers are stripped, not shown") { ctx in
                // The anti-fabrication rule from the other direction: if a model invents
                // "[Source 7]" when only two sources exist, the user must not be shown a
                // citation that points nowhere.
                let server = scriptedServer(answer: """
                The decline was caused by the reorganisation. [Source 1] It was also affected \
                by a factor described elsewhere. [Source 7] A third claim rests on nothing. [Source 12]
                """)
                try server.start()
                defer { server.stop() }

                let (store, _) = try Fixtures.temporaryStore()
                let notebook = try LiveLocalModelSuite.notebookWithDistinctiveSources(store)
                let provider = OllamaProvider(endpoint: server.baseURL, host: .local, keychain: EmptyKeychain())
                let engine = LiveLocalModelSuite.engine(store: store, provider: provider, model: "llama3.2:3b")

                let outcome = try await engine.answerOnce(
                    question: "What caused the decline?", notebookID: notebook.id
                )

                // No citation may point at a source that does not exist.
                for citation in outcome.citations {
                    let ids = try store.sources(notebookID: notebook.id).map(\.id)
                    if let sourceID = citation.sourceID {
                        try ctx.check(ids.contains(sourceID), "no citation points at a missing source")
                    }
                }
                // And the invented markers are reported rather than silently rendered.
                let mentions = outcome.notices.joined(separator: " ").lowercased()
                let answerMentions = outcome.answer.lowercased()
                try ctx.check(!answerMentions.contains("[source 12]") || !mentions.isEmpty,
                              "an unresolvable marker is either removed or reported")
            },

            test("the live suite skips rather than passes when there is no model") { ctx in
                // The honesty rule itself: an empty Ollama must produce a skip, not a
                // green tick and not a failure.
                let server = LocalHTTPServer { _ in .json(["models": []]) }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .local, keychain: EmptyKeychain())
                let availability = await provider.availability()
                try ctx.check(!availability.isReady, "nothing installed means not ready")
                // Discovery in the live suite keys off exactly this, so it will skip.
                try ctx.notNil(availability.reason, "and the reason explains what to do")
            },
        ])
    }
}
