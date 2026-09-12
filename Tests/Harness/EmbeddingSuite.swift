import Foundation
import SourceDeskCore

enum EmbeddingSuite {

    static var suite: TestSuite {
        TestSuite("5 · Embeddings", cases: [

            test("the built-in embedder is deterministic and correctly sized") { ctx in
                let embedder = BuiltInEmbedder()
                let first = embedder.embedOne("the inspection backlog caused the decline")
                let second = embedder.embedOne("the inspection backlog caused the decline")
                try ctx.equal(first.count, 384, "384 dimensions")
                try ctx.equal(first, second, "identical input gives an identical vector")
                try ctx.check(first.contains { $0 != 0 }, "vector is not all zeros")
                try ctx.close(Double(VectorMath.magnitude(first)), 1.0, tolerance: 1e-4, "vector is normalised")
            },

            test("related wording scores higher than unrelated wording") { ctx in
                let embedder = BuiltInEmbedder()
                let query = embedder.embedOne("what caused the decline in inspections")
                let related = embedder.embedOne("the decline in inspections was caused by budget pressure and staffing shortages")
                let unrelated = embedder.embedOne("the museum opened a new wing in the spring with a ribbon cutting ceremony")
                let relatedScore = VectorMath.cosineSimilarity(query, related)
                let unrelatedScore = VectorMath.cosineSimilarity(query, unrelated)
                try ctx.check(relatedScore > unrelatedScore + 0.1,
                              "related \(String(format: "%.3f", relatedScore)) should beat unrelated \(String(format: "%.3f", unrelatedScore))")
                try ctx.check(relatedScore > 0.3, "related text scores meaningfully high")
            },

            test("morphological variants still match") { ctx in
                let embedder = BuiltInEmbedder()
                let query = embedder.embedOne("inspection")
                let plural = embedder.embedOne("inspections")
                let gerund = embedder.embedOne("inspecting")
                try ctx.check(VectorMath.cosineSimilarity(query, plural) > 0.5, "inspection ≈ inspections")
                try ctx.check(VectorMath.cosineSimilarity(query, gerund) > 0.4, "inspection ≈ inspecting")
            },

            test("empty and non-text input is handled") { ctx in
                let embedder = BuiltInEmbedder()
                let empty = embedder.embedOne("")
                try ctx.equal(empty.count, 384)
                try ctx.close(Double(VectorMath.magnitude(empty)), 0.0, tolerance: 1e-9, "empty input yields a zero vector")
                let punctuation = embedder.embedOne("!!! ??? ---")
                try ctx.close(Double(VectorMath.magnitude(punctuation)), 0.0, tolerance: 1e-9)
                let cjk = embedder.embedOne("報告 は 検査 の 減少 を 述べている")
                try ctx.check(cjk.contains { $0 != 0 }, "CJK text produces a usable vector")
            },

            test("batch embedding keeps order and count") { ctx in
                let embedder = BuiltInEmbedder()
                let texts = (0..<25).map { "passage number \($0) about inspections and permits" }
                let vectors = try await embedder.embed(texts)
                try ctx.equal(vectors.count, 25)
                for (index, vector) in vectors.enumerated() {
                    try ctx.check(vector.count == 384, "vector \(index) has 384 dimensions")
                }
                let single = embedder.embedOne(texts[7])
                try ctx.close(VectorMath.cosineSimilarity(single, vectors[7]), 1.0, tolerance: 1e-5, "batch matches single")
            },

            test("availability reports ready without any network") { ctx in
                let availability = await BuiltInEmbedder().availability()
                try ctx.equal(availability, .ready)
            },

            test("the indexer skips cleanly when embeddings are off") { ctx in
                let indexer = EmbeddingIndexer(provider: nil)
                let chunks = [SourceChunk(sourceID: "s", notebookID: "n", ordinal: 0, text: "text")]
                let outcome = try await indexer.index(chunks: chunks)
                try ctx.equal(outcome.embeddings.count, 0)
                try ctx.equal(outcome.didEmbed, false)
                try ctx.contains(outcome.skippedReason ?? "", "turned off")
            },

            test("the indexer reports why a provider is unavailable") { ctx in
                let unavailable = UnavailableEmbedder()
                let outcome = try await EmbeddingIndexer(provider: unavailable).index(chunks: [
                    SourceChunk(sourceID: "s", notebookID: "n", ordinal: 0, text: "text")
                ])
                try ctx.equal(outcome.embeddings.count, 0)
                try ctx.contains(outcome.skippedReason ?? "", "not installed")
            },

            test("the indexer produces one vector per chunk in order") { ctx in
                let chunks = (0..<10).map { SourceChunk(sourceID: "s", notebookID: "n", ordinal: $0, text: "chunk \($0)") }
                let progressCalls = Counter()
                let outcome = try await EmbeddingIndexer(provider: BuiltInEmbedder(), batchSize: 3)
                    .index(chunks: chunks) { _ in progressCalls.increment() }
                try ctx.equal(outcome.embeddings.count, 10)
                try ctx.equal(outcome.embeddings.map(\.chunkID), chunks.map(\.id), "order preserved")
                try ctx.check(progressCalls.current >= 3, "progress reported per batch (got \(progressCalls.current))")
                for embedding in outcome.embeddings {
                    try ctx.equal(embedding.dimensions, 384)
                    try ctx.equal(embedding.model, "builtin-hash-384")
                }
            },

            test("an embedding error surfaces as an actionable error") { ctx in
                let error = try await ctx.expectError("provider failure propagates to the caller") {
                    try await EmbeddingIndexer(provider: ExplodingEmbedder()).index(chunks: [
                        SourceChunk(sourceID: "s", notebookID: "n", ordinal: 0, text: "text")
                    ])
                }
                let message = (error as? SourceDeskError)?.errorDescription ?? "\(error)"
                try ctx.contains(message, "embedding model")
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "Settings")
            }
        ])
    }
}

// MARK: - Test doubles

struct UnavailableEmbedder: EmbeddingProvider {
    let identifier = "test-unavailable"
    let displayName = "Unavailable"
    let dimensions = 8
    let isLocal = true
    func availability() async -> EmbeddingAvailability { .unavailable(reason: "the model is not installed") }
    func embed(_ texts: [String]) async throws -> [[Float]] { [] }
}

struct ExplodingEmbedder: EmbeddingProvider {
    let identifier = "test-exploding"
    let displayName = "Exploding"
    let dimensions = 8
    let isLocal = true
    func availability() async -> EmbeddingAvailability { .ready }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        throw SourceDeskError.embeddingModelUnavailable(model: "exploding", reason: "the server returned an error")
    }
}
