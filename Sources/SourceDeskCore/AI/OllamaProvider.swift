import Foundation

// MARK: - Ollama

/// Local inference through a running Ollama server, or Ollama's hosted API.
///
/// Ollama exposes one API from two places: a server on the user's own machine
/// (`http://localhost:11434`) and `https://ollama.com`, where the same
/// `/api/tags`, `/api/chat` and `/api/embed` routes run the large models that will
/// not fit on a laptop. The only differences are the bearer token, and that the
/// remote host is a third party — which is a privacy difference, not a technical
/// one, so it is surfaced rather than hidden.
///
/// SourceDesk never installs or downloads Ollama, and never pulls a model on the
/// user's behalf: it detects what is there and says what is missing.
public struct OllamaProvider: AIProvider {

    /// Whether this instance talks to a machine the user controls, or to a remote
    /// service.
    ///
    /// This is stated rather than inferred at the call site, because it is a privacy
    /// decision, not a networking detail: a provider the user selected as "cloud" must
    /// keep requiring consent and keep being labelled as leaving the Mac, even if they
    /// point it at a private host. It also keeps `identifier` stable, which matters
    /// because sessions and messages record it.
    public enum Host: Sendable {
        case local
        case cloud
    }

    public let identifier: String
    public let displayName: String
    public let isLocal: Bool
    public let host: Host
    public let endpoint: URL
    public let keychain: KeychainReading
    /// Injectable for tests: bypasses the keychain.
    public let explicitKey: String?

    /// The hosted endpoint. Used when a setting asks for the cloud without naming a
    /// host, and to recognise the cloud when it is named.
    public static let cloudEndpoint = URL(string: "https://ollama.com")!

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:11434")!,
        host: Host? = nil,
        keychain: KeychainReading = KeychainService(),
        explicitKey: String? = nil
    ) {
        // Without an explicit choice, a host on the user's own network is local.
        let resolved = host ?? (Self.isCloudEndpoint(endpoint) ? .cloud : .local)
        self.host = resolved
        self.endpoint = endpoint
        self.keychain = keychain
        self.explicitKey = explicitKey
        self.isLocal = resolved == .local
        self.identifier = resolved == .cloud ? "ollama-cloud" : "ollama"
        self.displayName = resolved == .cloud ? "Ollama Cloud" : "Ollama (local)"
    }

    /// True when this instance talks to a remote service rather than a machine the
    /// user controls.
    public var isCloud: Bool { host == .cloud }

    /// A host is "the cloud" when it is not on the user's own network.
    public static func isCloudEndpoint(_ url: URL) -> Bool {
        !Networking.isPrivateNetworkEndpoint(url)
    }

    var apiKey: String? {
        if let explicitKey, !explicitKey.isEmpty { return explicitKey }
        return keychain.secret(for: KeychainService.Key.ollamaAPIKey)
    }

    public var isConfigured: Bool { isCloud ? apiKey != nil : true }

    public var configurationHint: String? {
        if isCloud {
            return "Runs Ollama's hosted models. Requires an API key from ollama.com/settings/keys, stored in the macOS Keychain."
        }
        return "Runs models on this Mac. Requires Ollama with at least one model pulled."
    }

    // MARK: Availability

    public func availability() async -> ProviderAvailability {
        if isCloud, apiKey == nil {
            return .notConfigured(reason: "no Ollama API key is stored (Settings → AI Providers)")
        }
        do {
            let models = try await OllamaClient(endpoint: endpoint, apiKey: apiKey).listModels()
            if models.isEmpty {
                return .unreachable(reason: isCloud
                    ? "the Ollama API returned no models for this account"
                    : "Ollama is running but no models are installed — run `ollama pull llama3.2`")
            }
            return .ready
        } catch let error as SourceDeskError {
            return .unreachable(reason: error.errorDescription ?? "\(error)")
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    public func availableModels() async throws -> [ModelDescriptor] {
        let models = try await OllamaClient(endpoint: endpoint, apiKey: apiKey).listModels()
        return models.map { model in
            // A reported window is a fact; an inferred one is an estimate and is
            // labelled as such in the UI.
            let reportedContext = model.contextLength
            let inferredContext = reportedContext == nil ? Self.contextLength(for: model) : nil
            return ModelDescriptor(
                providerID: identifier,
                name: model.name,
                // Hosted models report their uncompressed size, which has nothing to
                // do with a download. Showing it as one would be a lie, so the size
                // is only reported for models that actually live on this Mac.
                sizeDescription: isCloud ? nil : model.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                parameterSize: model.parameterSize ?? Self.parameterSizeGuess(for: model.name),
                quantization: model.quantization,
                contextLength: reportedContext ?? inferredContext,
                contextLengthIsEstimated: reportedContext == nil,
                isLocal: isLocal,
                supportsEmbeddings: Self.isEmbeddingModel(model),
                supportsStreaming: true,
                capabilityNote: Self.capabilityNote(for: model, isCloud: isCloud)
            )
        }
    }

    // MARK: Generation

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        // A missing credential and a rejected one need different fixes, so they are
        // kept distinct rather than both surfacing as a 401 from the server.
        if isCloud, apiKey == nil {
            throw SourceDeskError.missingAPIKey(provider: displayName)
        }
        let client = try await OllamaClient(endpoint: endpoint, apiKey: apiKey)
            .checkingModel(request.model, listingErrorIsNotFatal: isCloud)
        let started = Date()
        let payload = try Self.chatPayload(request, stream: false)
        let data = try await client.post(path: "api/chat", payload: payload)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceDeskError.providerRejected(provider: displayName, status: 200, message: "the response was not valid JSON")
        }
        if let error = object["error"] as? String, !error.isEmpty {
            throw Self.generationError(error, model: request.model, providerName: displayName)
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
                    // Fail on a missing credential before dialling out: the streaming
                    // path opens a connection eagerly, so it cannot ask afterwards.
                    if isCloud, apiKey == nil {
                        throw SourceDeskError.missingAPIKey(provider: displayName)
                    }
                    // Checking the model first turns "not available" into one clear
                    // message before any tokens are streamed.
                    let client = try await OllamaClient(endpoint: endpoint, apiKey: apiKey)
                        .checkingModel(request.model, listingErrorIsNotFatal: isCloud)
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
                        throw client.errorForStatus(http, data: body, model: request.model, providerName: displayName)
                    }

                    for try await line in LineStream(bytes) {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = object["error"] as? String, !error.isEmpty {
                            continuation.yield(.failed(Self.generationError(error, model: request.model, providerName: self.displayName)))
                            continuation.finish()
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
                    continuation.yield(.failed(HTTPClient.mapError(error, provider: self.displayName, url: self.endpoint)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Turns an `{"error": "…"}` body into the most specific error available.
    ///
    /// Ollama reports an unauthorised request, an unknown model, and a model the
    /// account cannot run with the same *shape* of message and often the same status,
    /// so the wording is matched rather than the status code guessed at. Saying "check
    /// your key" for a typo in a model name would send the user to the wrong place.
    public static func generationError(_ message: String, model: String, providerName: String) -> SourceDeskError {
        let lowered = message.lowercased()
        if lowered.contains("unauthorized") || lowered.contains("invalid api key") || lowered.contains("authentication") {
            return .invalidAPIKey(provider: providerName)
        }
        if lowered.contains("not found") || lowered.contains("no such model") || lowered.contains("does not exist") {
            return .localModelMissing(name: model, endpoint: providerName)
        }
        if lowered.contains("context length") || lowered.contains("too long") || lowered.contains("too many tokens") {
            return .contextTooLarge(model: model, neededTokens: 0, limitTokens: 0)
        }
        if lowered.contains("subscription") || lowered.contains("not available") || lowered.contains("no access") || lowered.contains("forbidden") {
            return .providerRejected(provider: providerName, status: 403,
                                     message: "\(message) — this account does not have access to “\(model)”")
        }
        if lowered.contains("rate limit") || lowered.contains("too many requests") {
            return .providerRateLimited(provider: providerName, retryAfter: nil)
        }
        return .providerRejected(provider: providerName, status: 0, message: message)
    }

    /// Convenience for callers that only have an endpoint; prefers the provider name
    /// the endpoint implies.
    public static func generationError(_ message: String, model: String, endpoint: URL) -> SourceDeskError {
        generationError(message, model: model,
                        providerName: isCloudEndpoint(endpoint) ? "Ollama Cloud" : "Ollama")
    }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        try await OllamaClient(endpoint: endpoint, apiKey: apiKey).embed(model: model, inputs: texts)
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

    /// Rough context window estimate when the server does not report one.
    ///
    /// The hosted catalogue returns empty `details`, so the parameter count is read
    /// from the model's own name: `gpt-oss:120b`, `mistral-large-3:675b`,
    /// `qwen3.5:397b`. Without this every cloud model would be assumed to hold 8k
    /// tokens, which would make the app under-fill the context of a model that holds
    /// far more.
    static func contextLength(for model: OllamaModel) -> Int {
        if let parameterSize = model.parameterSize,
           let window = window(forParameterSize: parameterSize) {
            return window
        }
        if let fromName = parameterSizeGuess(for: model.name),
           let window = window(forParameterSize: fromName) {
            return window
        }
        return 8_192
    }

    private static func window(forParameterSize parameterSize: String) -> Int? {
        guard let billions = Double(parameterSize.lowercased()
            .replacingOccurrences(of: "b", with: "")
            .replacingOccurrences(of: "m", with: "")
            .trimmingCharacters(in: .whitespaces)) else { return nil }
        if billions <= 4 { return 8_192 }
        if billions <= 9 { return 32_768 }
        if billions <= 200 { return 131_072 }
        return 262_144
    }

    /// Reads a parameter count out of a model name, as the hosted catalogue requires.
    /// Returns a normalised string such as "120B" or "675B".
    static func parameterSizeGuess(for name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)(\\d+(?:\\.\\d+)?)\\s*([bm])\\b") else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let numberRange = Range(match.range(at: 1), in: name),
              let unitRange = Range(match.range(at: 2), in: name) else { return nil }
        let unit = name[unitRange].uppercased()
        // A parameter count is the largest number in the name; a version number such
        // as "qwen3" or "glm-5.3" has no unit and is therefore never matched.
        return "\(name[numberRange])\(unit)"
    }

    static func capabilityNote(for model: OllamaModel, isCloud: Bool) -> String? {
        if isEmbeddingModel(model) { return "Embedding model — use it in Settings → Advanced" }
        guard let parameterSize = model.parameterSize ?? parameterSizeGuess(for: model.name),
              let value = Double(parameterSize.lowercased().replacingOccurrences(of: "b", with: "")) else {
            return nil
        }
        if value <= 4 { return "Fast, good for summarising and short questions" }
        if value <= 9 { return "Balanced: solid reasoning at usable speed" }
        if value <= 20 { return "Strong reasoning; needs plenty of memory" }
        if isCloud { return "Large hosted model: highest quality, runs on Ollama's servers" }
        return "Highest quality; slow on machines without a lot of unified memory"
    }
}

// MARK: - Ollama client

/// Minimal client for the Ollama HTTP API (`/api/tags`, `/api/chat`, `/api/embed`).
///
/// The same routes are served by a local install and by `https://ollama.com`, so one
/// client covers both; the only difference is the bearer token, which is attached
/// whenever one is configured.
public struct OllamaClient: Sendable {

    public let endpoint: URL
    public let apiKey: String?
    private let session: URLSession

    public init(endpoint: URL, apiKey: String? = nil) {
        self.endpoint = endpoint
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? apiKey : nil
        self.session = HTTPClient.session(timeout: 60)
    }

    public func url(path: String) -> URL {
        endpoint.appendingPathComponent(path)
    }

    private func authorize(_ request: inout URLRequest) {
        guard let apiKey else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    /// Maps an HTTP status onto the right error, preferring Ollama's own message.
    ///
    /// The body is read *before* the status is considered, because Ollama uses 403 for
    /// both "your key is wrong" and "your plan does not include this model", and those
    /// need different advice. Status is the fallback, not the first answer.
    public func errorForStatus(_ response: HTTPURLResponse, data: Data, model: String?,
                               providerName: String? = nil) -> SourceDeskError {
        let name = providerName ?? (OllamaProvider.isCloudEndpoint(endpoint) ? "Ollama Cloud" : "Ollama")
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["error"] as? String }
        if let message, !message.isEmpty {
            if let model {
                return OllamaProvider.generationError(message, model: model, providerName: name)
            }
            if message.lowercased().contains("unauthorized") {
                return .invalidAPIKey(provider: name)
            }
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return .invalidAPIKey(provider: name)
        }
        return HTTPClient.errorForStatus(response.statusCode, data: data, provider: name,
                                         url: url(path: "/"), retryAfter: HTTPClient.retryAfter(response))
    }

    // MARK: Models

    public func listModels() async throws -> [OllamaModel] {
        var request = URLRequest(url: url(path: "api/tags"))
        request.httpMethod = "GET"
        authorize(&request)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SourceDeskError.localModelNotRunning(endpoint: endpoint.absoluteString)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw errorForStatus(http, data: data, model: nil)
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

    /// Fails early with a clear message when the chosen model is not available,
    /// rather than letting the server return an opaque error mid-stream.
    ///
    /// `listingErrorIsNotFatal` exists because the hosted catalogue can succeed while
    /// the model an account may actually run is a subset of it — a listing is a hint,
    /// not an entitlement list, so a cloud mismatch is left for the server to judge.
    public func checkingModel(_ model: String, listingErrorIsNotFatal: Bool = false) async throws -> OllamaClient {
        let models: [OllamaModel]
        do {
            models = try await listModels()
        } catch {
            if listingErrorIsNotFatal { return self }
            throw error
        }
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
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SourceDeskError.localModelNotRunning(endpoint: endpoint.absoluteString)
            }
            if (200..<300).contains(http.statusCode) { return data }
            throw errorForStatus(http, data: data, model: payload["model"] as? String)
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
        authorize(&request)
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
        // The hosted catalogue returns these keys with empty strings rather than
        // omitting them, so an empty value has to become nil. Otherwise a present-but-
        // blank field would shadow every fallback that should have filled it in.
        self.parameterSize = Self.nonEmpty(details?["parameter_size"] as? String)
        self.quantization = Self.nonEmpty(details?["quantization_level"] as? String)
        self.family = Self.nonEmpty(details?["family"] as? String)
        // Newer servers expose the model's context window in "model_info".
        if let info = json["model_info"] as? [String: Any] {
            for key in info.keys where key.hasSuffix(".context_length") {
                if let value = info[key] as? Int { self.contextLength = value; break }
            }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
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

    /// Default registry: local-first, with Ollama's hosted API and the two cloud
    /// providers users asked for.
    public static func standard(
        ollamaEndpoint: URL = URL(string: "http://127.0.0.1:11434")!,
        ollamaCloudEndpoint: URL = OllamaProvider.cloudEndpoint,
        keychain: KeychainReading = KeychainService()
    ) -> ProviderRegistry {
        var providers: [AIProvider] = [
            OllamaProvider(endpoint: ollamaEndpoint, keychain: keychain),
            OpenAIProvider(keychain: keychain),
            AnthropicProvider(keychain: keychain)
        ]
        // The hosted provider is stated as cloud, so its identity and its privacy
        // rules do not depend on where the endpoint happens to point.
        let hosted = OllamaProvider(endpoint: ollamaCloudEndpoint, host: .cloud, keychain: keychain)
        if hosted.identifier != providers[0].identifier {
            providers.append(hosted)
        }
        return ProviderRegistry(providers: providers)
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
