import Foundation

// MARK: - Ollama

/// Local inference through a running Ollama server.
///
/// SourceDesk never installs, downloads or launches Ollama: it detects an existing
/// install, lists the models the user already has, and otherwise reports exactly
/// what to run. A research tool should not silently pull a multi-gigabyte model.
public struct OllamaProvider: AIProvider {

    public let identifier = "ollama"
    public let displayName = "Ollama (local)"
    public let isLocal = true
    public let endpoint: URL

    public init(endpoint: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.endpoint = endpoint
    }

    public var isConfigured: Bool { true }

    public var configurationHint: String? {
        "Runs models on this Mac. Requires Ollama with at least one model pulled."
    }

    // MARK: Availability

    public func availability() async -> ProviderAvailability {
        guard Networking.isLocalEndpoint(endpoint) || endpoint.scheme == "https" else {
            return .notConfigured(reason: "the endpoint \(endpoint.absoluteString) is not a local address")
        }
        do {
            let client = OllamaClient(endpoint: endpoint)
            let models = try await client.listModels()
            if models.isEmpty {
                return .unreachable(reason: "Ollama is running but no models are installed — run `ollama pull llama3.2`")
            }
            return .ready
        } catch let error as SourceDeskError {
            return .unreachable(reason: error.errorDescription ?? "\(error)")
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    public func availableModels() async throws -> [ModelDescriptor] {
        let client = OllamaClient(endpoint: endpoint)
        let models = try await client.listModels()
        return models.map { model in
            let capabilities = Self.capabilityNote(for: model)
            return ModelDescriptor(
                providerID: identifier,
                name: model.name,
                sizeDescription: model.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                parameterSize: model.parameterSize,
                quantization: model.quantization,
                contextLength: model.contextLength ?? Self.contextLength(for: model),
                isLocal: true,
                supportsEmbeddings: Self.isEmbeddingModel(model),
                supportsStreaming: true,
                capabilityNote: capabilities
            )
        }
    }

    // MARK: Generation

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        let client = try await OllamaClient(endpoint: endpoint)
            .checkingModel(request.model)
        let started = Date()
        let payload = try Self.chatPayload(request, stream: false)
        let data = try await client.post(path: "api/chat", payload: payload)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceDeskError.providerRejected(provider: displayName, status: 200, message: "the response was not valid JSON")
        }
        if let error = object["error"] as? String, !error.isEmpty {
            throw SourceDeskError.localModelMissing(name: request.model, endpoint: endpoint.absoluteString)
        }
        let message = object["message"] as? [String: Any]
        let text = (message?["content"] as? String) ?? (object["response"] as? String) ?? ""
        let promptTokens = object["prompt_eval_count"] as? Int
        let completionTokens = object["eval_count"] as? Int
        return AIResponse(
            text: text,
            model: (object["model"] as? String) ?? request.model,
            usage: ChatUsage(promptTokens: promptTokens, completionTokens: completionTokens),
            latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            finishReason: object["done_reason"] as? String
        )
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let payload = try Self.chatPayload(request, stream: true)
                    let client = try await OllamaClient(endpoint: endpoint).checkingModel(request.model)
                    let started = Date()
                    continuation.yield(.started(model: request.model))

                    var accumulated = ""
                    var reasoning = ""
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var finishReason: String?

                    let (bytes, response) = try await client.streamRequest(path: "api/chat", payload: payload)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw HTTPClient.errorForStatus(http.statusCode, data: body, provider: displayName,
                                                        url: client.url(path: "api/chat"))
                    }

                    for try await line in LineStream(bytes) {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = object["error"] as? String, !error.isEmpty {
                            continuation.finish(throwing: SourceDeskError.localModelMissing(name: request.model, endpoint: endpoint.absoluteString))
                            return
                        }
                        if let message = object["message"] as? [String: Any] {
                            // Reasoning-capable models put chain-of-thought in a
                            // separate field; it is surfaced, not spliced into the answer.
                            if let thinking = message["thinking"] as? String, !thinking.isEmpty {
                                reasoning += thinking
                                continuation.yield(.reasoning(thinking))
                            }
                            if let piece = message["content"] as? String, !piece.isEmpty {
                                accumulated += piece
                                continuation.yield(.delta(piece))
                            }
                        } else if let piece = object["response"] as? String, !piece.isEmpty {
                            accumulated += piece
                            continuation.yield(.delta(piece))
                        }
                        if let count = object["prompt_eval_count"] as? Int { promptTokens = count }
                        if let count = object["eval_count"] as? Int { completionTokens = count }
                        if let reason = object["done_reason"] as? String { finishReason = reason }
                        if object["done"] as? Bool == true { break }
                    }

                    continuation.yield(.finished(AIResponse(
                        text: accumulated,
                        model: request.model,
                        usage: ChatUsage(promptTokens: promptTokens, completionTokens: completionTokens),
                        latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        finishReason: finishReason
                    )))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch let error as SourceDeskError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(HTTPClient.mapError(error, provider: "Ollama", url: endpoint)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        try await OllamaClient(endpoint: endpoint).embed(model: model, inputs: texts)
    }

    // MARK: Payload

    static func chatPayload(_ request: AIRequest, stream: Bool) throws -> [String: Any] {
        guard !request.messages.isEmpty else {
            throw SourceDeskError.providerRejected(provider: "Ollama", status: 0, message: "the request had no messages")
        }
        var messages: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for message in request.messages {
            messages.append(["role": message.role.rawValue, "content": message.content])
        }
        var options: [String: Any] = ["temperature": request.temperature]
        if let maxTokens = request.maxTokens { options["num_predict"] = maxTokens }
        if !request.stopSequences.isEmpty { options["stop"] = request.stopSequences }

        var payload: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": stream,
            "options": options
        ]
        // Keep the model warm between questions in a research session.
        payload["keep_alive"] = "10m"
        return payload
    }

    static func isEmbeddingModel(_ model: OllamaModel) -> Bool {
        let name = model.name.lowercased()
        return name.contains("embed") || name.contains("bge") || name.contains("minilm") || name.contains("nomic")
    }

    /// Rough context window estimate when the server does not report one, from the
    /// parameter count: small models default low, large ones high.
    static func contextLength(for model: OllamaModel) -> Int {
        guard let parameterSize = model.parameterSize?.lowercased() else { return 8_192 }
        let value = Double(parameterSize.replacingOccurrences(of: "b", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
        if value <= 0 { return 8_192 }
        if value <= 4 { return 8_192 }
        if value <= 9 { return 32_768 }
        return 131_072
    }

    static func capabilityNote(for model: OllamaModel) -> String? {
        if isEmbeddingModel(model) { return "Embedding model — use it in Settings → Advanced" }
        guard let parameterSize = model.parameterSize?.lowercased(), let value = Double(parameterSize.replacingOccurrences(of: "b", with: "")) else {
            return nil
        }
        if value <= 4 { return "Fast, good for summarising and short questions" }
        if value <= 9 { return "Balanced: solid reasoning at usable speed" }
        if value <= 20 { return "Strong reasoning; needs plenty of memory" }
        return "Highest quality; slow on machines without a lot of unified memory"
    }
}

// MARK: - Ollama client

/// Minimal client for the Ollama HTTP API (`/api/tags`, `/api/chat`, `/api/embed`).
public struct OllamaClient: Sendable {

    public let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL) {
        self.endpoint = endpoint
        self.session = HTTPClient.session(timeout: 60)
    }

    public func url(path: String) -> URL {
        endpoint.appendingPathComponent(path)
    }

    // MARK: Models

    public func listModels() async throws -> [OllamaModel] {
        var request = URLRequest(url: url(path: "api/tags"))
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SourceDeskError.localModelNotRunning(endpoint: endpoint.absoluteString)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: "Ollama", url: request.url!)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [[String: Any]] else {
                return []
            }
            return models.compactMap { OllamaModel(json: $0) }.sorted { $0.name < $1.name }
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw SourceDeskError.localModelNotRunning(endpoint: endpoint.absoluteString)
        }
    }

    /// Fails early with a clear message when the chosen model is not installed,
    /// rather than letting the server return an opaque 404 mid-stream.
    public func checkingModel(_ model: String) async throws -> OllamaClient {
        let models = try await listModels()
        guard models.contains(where: { $0.name == model || $0.name.hasPrefix(model + ":") }) else {
            throw SourceDeskError.localModelMissing(name: model, endpoint: endpoint.absoluteString)
        }
        return self
    }

    // MARK: Chat

    public func post(path: String, payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SourceDeskError.localModelNotRunning(endpoint: endpoint.absoluteString)
            }
            if (200..<300).contains(http.statusCode) { return data }
            // Ollama reports a missing model as 404 with an error body.
            if http.statusCode == 404,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["error"] as? String, message.lowercased().contains("not found") {
                throw SourceDeskError.localModelMissing(name: payload["model"] as? String ?? "model", endpoint: endpoint.absoluteString)
            }
            throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: "Ollama", url: request.url!)
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw SourceDeskError.localModelNotRunning(endpoint: endpoint.absoluteString)
        }
    }

    public func streamRequest(path: String, payload: [String: Any]) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var request = URLRequest(url: url(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1_800
        let streaming = URLSession(configuration: configuration)
        do {
            return try await streaming.bytes(for: request)
        } catch {
            throw SourceDeskError.localModelNotRunning(endpoint: endpoint.absoluteString)
        }
    }

    // MARK: Embeddings

    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        let payload: [String: Any] = ["model": model, "input": inputs]
        let data = try await post(path: "api/embed", payload: payload)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceDeskError.embeddingModelUnavailable(model: model, reason: "the response was not valid JSON")
        }
        if let error = object["error"] as? String {
            if error.lowercased().contains("not found") {
                throw SourceDeskError.localModelMissing(name: model, endpoint: endpoint.absoluteString)
            }
            throw SourceDeskError.embeddingModelUnavailable(model: model, reason: error)
        }
        // Current API returns "embeddings": [[Float]]; older builds returned
        // "embedding": [Float] for a single input.
        if let embeddings = object["embeddings"] as? [[Double]] {
            return embeddings.map { $0.map(Float.init) }
        }
        if let embeddings = object["embeddings"] as? [[NSNumber]] {
            return embeddings.map { $0.map { $0.floatValue } }
        }
        if let single = object["embedding"] as? [Double] {
            return [single.map(Float.init)]
        }
        throw SourceDeskError.embeddingModelUnavailable(model: model, reason: "no vectors in the response")
    }
}

public struct OllamaModel: Hashable, Sendable {
    public var name: String
    public var size: Int64?
    public var parameterSize: String?
    public var quantization: String?
    public var contextLength: Int?
    public var family: String?

    public init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        self.name = name
        if let size = json["size"] as? Int64 { self.size = size }
        else if let size = json["size"] as? Int { self.size = Int64(size) }
        let details = json["details"] as? [String: Any]
        self.parameterSize = details?["parameter_size"] as? String
        self.quantization = details?["quantization_level"] as? String
        self.family = details?["family"] as? String
        // Newer servers expose the model's context window in "model_info".
        if let info = json["model_info"] as? [String: Any] {
            for key in info.keys where key.hasSuffix(".context_length") {
                if let value = info[key] as? Int { self.contextLength = value; break }
            }
        }
    }
}

// MARK: - Provider registry

/// The set of providers the app can talk to.
///
/// Providers are looked up by identifier, so a notebook or chat session that
/// recorded "anthropic" keeps working even if the default provider changes, and new
/// providers only need to be added here.
public final class ProviderRegistry: @unchecked Sendable {

    private var providers: [String: AIProvider]
    private let lock = NSLock()

    public init(providers: [AIProvider] = []) {
        var map: [String: AIProvider] = [:]
        for provider in providers { map[provider.identifier] = provider }
        self.providers = map
    }

    /// Default registry: local-first, with the two cloud providers users asked for.
    public static func standard(
        ollamaEndpoint: URL = URL(string: "http://127.0.0.1:11434")!,
        keychain: KeychainReading = KeychainService()
    ) -> ProviderRegistry {
        ProviderRegistry(providers: [
            OllamaProvider(endpoint: ollamaEndpoint),
            OpenAIProvider(keychain: keychain),
            AnthropicProvider(keychain: keychain)
        ])
    }

    public func register(_ provider: AIProvider) {
        lock.lock(); defer { lock.unlock() }
        providers[provider.identifier] = provider
    }

    public func provider(id: String) -> AIProvider? {
        lock.lock(); defer { lock.unlock() }
        return providers[id]
    }

    public var all: [AIProvider] {
        lock.lock(); defer { lock.unlock() }
        // Local providers first: the app is local-first by design.
        return providers.values.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.displayName < $1.displayName
        }
    }

    public var localProviders: [AIProvider] { all.filter(\.isLocal) }
    public var cloudProviders: [AIProvider] { all.filter { !$0.isLocal } }
}
