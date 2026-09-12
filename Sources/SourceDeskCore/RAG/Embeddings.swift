import Foundation

/// Turns text into vectors.
///
/// Everything the RAG pipeline does with vectors flows through this protocol, which
/// is what lets the app switch between a zero-download built-in embedder and a real
/// local model without the rest of the system knowing.
public protocol EmbeddingProvider: Sendable {
    /// Stable identifier stored alongside each vector, so mixed-model libraries can
    /// be detected and re-indexed instead of silently compared.
    var identifier: String { get }
    var displayName: String { get }
    var dimensions: Int { get }
    var isLocal: Bool { get }
    /// Whether this provider can run right now (model present, server reachable).
    func availability() async -> EmbeddingAvailability
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum EmbeddingAvailability: Sendable, Equatable {
    case ready
    case unavailable(reason: String)

    public var isReady: Bool { self == .ready }
}

// MARK: - Built-in embedder

/// A deterministic, dependency-free embedder.
///
/// It hashes lexical features — stemmed unigrams, adjacent bigrams and character
/// 4-grams — into a fixed 384-dimension vector and L2-normalises it. It is
/// explicitly *lexical*, not semantic: it will not connect "car" to "automobile".
/// What it does do is work instantly, on any Mac, with no download, no server, no
/// network and no privacy question — and combined with FTS5 keyword search and the
/// lexical reranker it retrieves well on the kind of prose people put in a research
/// notebook, where the query usually shares vocabulary with the answer.
///
/// Users who want true semantic recall switch the embedding provider to Ollama in
/// Settings; the pipeline picks it up and re-indexes.
public struct BuiltInEmbedder: EmbeddingProvider {

    public let identifier = "builtin-hash-384"
    public let displayName = "Built-in (hashing)"
    public let dimensions = 384
    public let isLocal = true

    /// Character n-gram size used for typo- and morphology-tolerant matching.
    private let characterGramSize = 4

    public init() {}

    public func availability() async -> EmbeddingAvailability { .ready }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { embedOne($0) }
    }

    public func embedOne(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let tokens = TextMath.tokens(text)
        guard !tokens.isEmpty else { return vector }

        var stems: [String] = []
        stems.reserveCapacity(tokens.count)
        for token in tokens {
            if TextMath.stopWords.contains(token) { continue }
            let stem = TextMath.stem(token)
            guard stem.count >= 2 else { continue }
            stems.append(stem)
            // Unigram, sublinear term frequency.
            add(&vector, feature: "w:\(stem)", weight: 1.0)
            // Character grams: "inspections" ≈ "inspection" ≈ "inspected".
            if stem.count >= characterGramSize {
                let characters = Array(stem)
                for start in 0...(characters.count - characterGramSize) {
                    let gram = String(characters[start..<(start + characterGramSize)])
                    add(&vector, feature: "c:\(gram)", weight: 0.28)
                }
            }
        }
        // Adjacent bigrams capture short phrases ("permit backlog", "review board").
        if stems.count >= 2 {
            for index in 0..<(stems.count - 1) {
                add(&vector, feature: "b:\(stems[index])_\(stems[index + 1])", weight: 0.65)
            }
        }
        return VectorMath.normalize(vector)
    }

    private func add(_ vector: inout [Float], feature: String, weight: Float) {
        let hash = StableHash.fnv1a(feature)
        let index = Int(hash % UInt64(dimensions))
        // The sign comes from a second hash bit: this is the standard hashing trick,
        // and it keeps unrelated features from systematically adding up.
        let sign = (hash >> 63) & 1 == 1 ? Float(-1) : Float(1)
        vector[index] += weight * sign
    }
}

// MARK: - Ollama embedder

/// Embeddings from a local Ollama server (`POST /api/embed`).
public struct OllamaEmbedder: EmbeddingProvider {

    public let identifier: String
    public let displayName: String
    public let dimensions: Int
    public let isLocal = true
    public let modelName: String
    public let endpoint: URL

    public init(modelName: String, endpoint: URL, dimensions: Int = 0) {
        self.modelName = modelName
        self.endpoint = endpoint
        self.identifier = "ollama:\(modelName)"
        self.displayName = "Ollama · \(modelName)"
        // Discovered on first use when unknown; 768 is the nomic-embed-text default.
        self.dimensions = dimensions > 0 ? dimensions : 768
    }

    public func availability() async -> EmbeddingAvailability {
        do {
            let tags = try await OllamaClient(endpoint: endpoint).listModels()
            if tags.contains(where: { $0.name == modelName || $0.name.hasPrefix(modelName + ":") }) {
                return .ready
            }
            return .unavailable(reason: "the model is not installed (run `ollama pull \(modelName)`)")
        } catch let error as SourceDeskError {
            return .unavailable(reason: error.errorDescription ?? "\(error)")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await OllamaClient(endpoint: endpoint).embed(model: modelName, inputs: texts)
    }
}

// MARK: - Provider selection

public enum EmbeddingProviderFactory {

    /// Builds the provider described by settings, or nil when embeddings are off.
    public static func make(
        choice: EmbeddingChoice,
        ollamaModel: String,
        ollamaEndpoint: URL
    ) -> EmbeddingProvider? {
        switch choice {
        case .builtIn:
            return BuiltInEmbedder()
        case .ollama:
            return OllamaEmbedder(modelName: ollamaModel, endpoint: ollamaEndpoint)
        case .disabled:
            return nil
        }
    }
}

// MARK: - Indexing service

/// Keeps stored vectors in step with stored chunks.
public struct EmbeddingIndexer: Sendable {

    let provider: EmbeddingProvider?
    /// Chunks are embedded in batches: one request per chunk would be needlessly
    /// slow for a local HTTP embedder, and one request for 5,000 chunks would
    /// exceed practical request sizes.
    let batchSize: Int

    public init(provider: EmbeddingProvider?, batchSize: Int = 16) {
        self.provider = provider
        self.batchSize = batchSize
    }

    public struct Outcome: Sendable {
        public var embeddings: [ChunkEmbedding]
        public var skippedReason: String?
        public var wasCancelled: Bool

        public var didEmbed: Bool { !embeddings.isEmpty }
    }

    /// Embeds chunks, reporting progress and honouring cancellation between batches.
    public func index(
        chunks: [SourceChunk],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Outcome {
        guard let provider else {
            return Outcome(embeddings: [], skippedReason: "Embeddings are turned off in Settings → Advanced.", wasCancelled: false)
        }
        guard !chunks.isEmpty else { return Outcome(embeddings: [], skippedReason: nil, wasCancelled: false) }

        let availability = await provider.availability()
        guard availability.isReady else {
            if case .unavailable(let reason) = availability {
                return Outcome(embeddings: [], skippedReason: reason, wasCancelled: false)
            }
            return Outcome(embeddings: [], skippedReason: nil, wasCancelled: false)
        }

        var produced: [ChunkEmbedding] = []
        produced.reserveCapacity(chunks.count)
        var index = 0
        while index < chunks.count {
            if Task.isCancelled {
                return Outcome(embeddings: produced, skippedReason: nil, wasCancelled: true)
            }
            let end = min(index + batchSize, chunks.count)
            let batch = Array(chunks[index..<end])
            let vectors = try await provider.embed(batch.map(\.text))
            for (offset, chunk) in batch.enumerated() {
                guard offset < vectors.count else { break }
                produced.append(ChunkEmbedding(
                    chunkID: chunk.id,
                    sourceID: chunk.sourceID,
                    notebookID: chunk.notebookID,
                    model: provider.identifier,
                    vector: vectors[offset]
                ))
            }
            index = end
            progress?(Double(index) / Double(chunks.count))
        }
        return Outcome(embeddings: produced, skippedReason: nil, wasCancelled: false)
    }
}
