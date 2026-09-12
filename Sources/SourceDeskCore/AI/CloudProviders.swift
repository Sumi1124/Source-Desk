import Foundation
import Security

/// Keychain access for API credentials.
///
/// API keys are never written to the notebook, the settings database, a plist or an
/// export. They live in the login keychain, scoped to a service name so other apps
/// cannot read them. Nothing in the export pipeline touches this type.
public protocol KeychainReading: Sendable {
    func secret(for key: String) -> String?
}

extension KeychainReading {
    /// Convenience so providers can pass a typed key.
    public func secret(for key: KeychainService.Key) -> String? { secret(for: key.rawValue) }
}

public struct KeychainService: KeychainReading, Sendable {

    public enum Key: String, CaseIterable, Sendable {
        case openAIAPIKey = "openai.api-key"
        case anthropicAPIKey = "anthropic.api-key"
        case braveSearchAPIKey = "brave.api-key"
        case tavilySearchAPIKey = "tavily.api-key"

        /// What the user sees in Settings when a value is missing.
        public var displayName: String {
            switch self {
            case .openAIAPIKey: return "OpenAI API key"
            case .anthropicAPIKey: return "Anthropic API key"
            case .braveSearchAPIKey: return "Brave Search API key"
            case .tavilySearchAPIKey: return "Tavily API key"
            }
        }

        public var providerName: String {
            switch self {
            case .openAIAPIKey: return "OpenAI"
            case .anthropicAPIKey: return "Anthropic Claude"
            case .braveSearchAPIKey, .tavilySearchAPIKey: return "Web search"
            }
        }
    }

    public static let service = "com.sourcedesk.app.credentials"

    public init() {}

    // MARK: Reading

    public func secret(for key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func secret(for key: Key) -> String? { secret(for: key.rawValue) }

    public func hasSecret(for key: Key) -> Bool { secret(for: key) != nil }

    /// What the UI shows instead of the secret: enough to recognise the key,
    /// never enough to use it.
    public func maskedHint(for key: Key) -> String? {
        guard let secret = secret(for: key) else { return nil }
        if secret.count <= 8 { return "••••" }
        return "••••" + secret.suffix(4)
    }

    // MARK: Writing

    @discardableResult
    public func store(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(key) }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Keys stored on this Mac, for the Settings summary.
    public var storedKeys: [Key] {
        Key.allCases.filter { hasSecret(for: $0) }
    }
}

// MARK: - Cloud providers

/// OpenAI-compatible chat completions.
///
/// Works with the official OpenAI API and with any gateway that implements the same
/// `POST /v1/chat/completions` shape (a self-hosted proxy, Azure-style deployments,
/// or another vendor's compatible endpoint), which is why the base URL is a setting.
///
/// SourceDesk does not and cannot use a ChatGPT subscription: that requires an
/// official API key or a compliant gateway. The app says so plainly in Settings.
public struct OpenAIProvider: AIProvider {

    public let identifier = "openai"
    public let displayName = "OpenAI"
    public let isLocal = false
    public let baseURL: URL
    public let keychain: KeychainReading
    /// Injectable for tests: bypasses the keychain.
    public let explicitKey: String?

    public init(
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        keychain: KeychainReading = KeychainService(),
        explicitKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.keychain = keychain
        self.explicitKey = explicitKey
    }

    var apiKey: String? {
        if let explicitKey, !explicitKey.isEmpty { return explicitKey }
        return keychain.secret(for: KeychainService.Key.openAIAPIKey)
    }

    public var isConfigured: Bool { apiKey != nil }

    public var configurationHint: String? {
        "Add an OpenAI API key in Settings → AI Providers. A ChatGPT Plus subscription is not an API key and cannot be used here."
    }

    public func availability() async -> ProviderAvailability {
        guard isConfigured else {
            return .notConfigured(reason: "no API key is stored (Settings → AI Providers)")
        }
        return .ready
    }

    public func availableModels() async throws -> [ModelDescriptor] {
        guard let apiKey else { throw SourceDeskError.missingAPIKey(provider: displayName) }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await HTTPClient.session(timeout: 30).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw HTTPClient.errorForStatus(status, data: data, provider: displayName, url: request.url!)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["data"] as? [[String: Any]] else { return [] }
            return entries.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return ModelDescriptor(
                    providerID: identifier,
                    name: id,
                    isLocal: false,
                    supportsEmbeddings: id.contains("embedding"),
                    capabilityNote: Self.note(for: id)
                )
            }
            .sorted { $0.name < $1.name }
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: request.url!)
        }
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        guard let apiKey else { throw SourceDeskError.missingAPIKey(provider: displayName) }
        let started = Date()
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.payload(request, stream: false))

        do {
            let (data, response) = try await HTTPClient.session(timeout: 180).data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw SourceDeskError.providerUnavailable(provider: displayName, reason: "no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: displayName,
                                                url: urlRequest.url!, retryAfter: HTTPClient.retryAfter(http))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SourceDeskError.providerRejected(provider: displayName, status: http.statusCode, message: "the response was not valid JSON")
            }
            let choice = (object["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            let text = (message?["content"] as? String) ?? ""
            let usage = object["usage"] as? [String: Any]
            return AIResponse(
                text: text,
                model: (object["model"] as? String) ?? request.model,
                usage: ChatUsage(
                    promptTokens: usage?["prompt_tokens"] as? Int,
                    completionTokens: usage?["completion_tokens"] as? Int
                ),
                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                finishReason: choice?["finish_reason"] as? String
            )
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: urlRequest.url!)
        }
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey else { throw SourceDeskError.missingAPIKey(provider: displayName) }
                    var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.payload(request, stream: true))

                    let started = Date()
                    continuation.yield(.started(model: request.model))

                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 300
                    configuration.timeoutIntervalForResource = 1_800
                    let session = URLSession(configuration: configuration)
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw SourceDeskError.providerUnavailable(provider: displayName, reason: "no HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw HTTPClient.errorForStatus(http.statusCode, data: body, provider: displayName,
                                                        url: urlRequest.url!, retryAfter: HTTPClient.retryAfter(http))
                    }

                    var accumulated = ""
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var finishReason: String?

                    for try await line in LineStream(bytes) {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
                            let delta = choice["delta"] as? [String: Any]
                            if let piece = delta?["content"] as? String, !piece.isEmpty {
                                accumulated += piece
                                continuation.yield(.delta(piece))
                            }
                            if let reason = choice["finish_reason"] as? String { finishReason = reason }
                        }
                        if let usage = object["usage"] as? [String: Any] {
                            promptTokens = usage["prompt_tokens"] as? Int
                            completionTokens = usage["completion_tokens"] as? Int
                        }
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
                    continuation.yield(.failed(HTTPClient.mapError(error, provider: "OpenAI", url: baseURL)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        guard let apiKey else { throw SourceDeskError.missingAPIKey(provider: displayName) }
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        do {
            let (data, response) = try await HTTPClient.session(timeout: 120).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HTTPClient.errorForStatus((response as? HTTPURLResponse)?.statusCode ?? 0, data: data,
                                                provider: displayName, url: request.url!)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["data"] as? [[String: Any]] else {
                throw SourceDeskError.providerRejected(provider: displayName, status: 200, message: "no embeddings in the response")
            }
            return entries.compactMap { entry in
                (entry["embedding"] as? [Double])?.map(Float.init)
            }
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: request.url!)
        }
    }

    static func payload(_ request: AIRequest, stream: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for message in request.messages {
            messages.append(["role": message.role.rawValue, "content": message.content])
        }
        var payload: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "temperature": request.temperature,
            "stream": stream
        ]
        if let maxTokens = request.maxTokens { payload["max_tokens"] = maxTokens }
        if stream { payload["stream_options"] = ["include_usage": true] }
        return payload
    }

    static func note(for model: String) -> String? {
        let lowered = model.lowercased()
        if lowered.contains("embedding") { return "Embeddings only" }
        if lowered.hasPrefix("gpt-5") { return "Highest quality; most expensive" }
        if lowered.hasPrefix("gpt-4o-mini") || lowered.contains("nano") { return "Fast and inexpensive" }
        if lowered.hasPrefix("gpt-4o") || lowered.hasPrefix("gpt-4.1") { return "Strong reasoning" }
        if lowered.hasPrefix("o") && lowered.count <= 5 { return "Reasoning model; slower, very strong" }
        return nil
    }
}

// MARK: - Anthropic

/// Anthropic's Messages API.
///
/// Like OpenAI, this requires an API key with billing enabled. A Claude Pro or Max
/// subscription does not include API access and cannot be reached from an app, so
/// the UI states that rather than implying otherwise.
public struct AnthropicProvider: AIProvider {

    public let identifier = "anthropic"
    public let displayName = "Anthropic Claude"
    public let isLocal = false
    public let baseURL: URL
    public let keychain: KeychainReading
    public let explicitKey: String?
    /// Versions are sent as a header, as the API requires.
    public let apiVersion: String

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        keychain: KeychainReading = KeychainService(),
        explicitKey: String? = nil,
        apiVersion: String = "2023-06-01"
    ) {
        self.baseURL = baseURL
        self.keychain = keychain
        self.explicitKey = explicitKey
        self.apiVersion = apiVersion
    }

    var apiKey: String? {
        if let explicitKey, !explicitKey.isEmpty { return explicitKey }
        return keychain.secret(for: KeychainService.Key.anthropicAPIKey)
    }

    public var isConfigured: Bool { apiKey != nil }

    public var configurationHint: String? {
        "Add an Anthropic API key in Settings → AI Providers. A Claude Pro subscription is not an API key and cannot be used here."
    }

    public func availability() async -> ProviderAvailability {
        guard isConfigured else { return .notConfigured(reason: "no API key is stored (Settings → AI Providers)") }
        return .ready
    }

    /// Anthropic has no public list-models endpoint, so the well-known current
    /// models are offered and any other name can be typed in.
    public func availableModels() async throws -> [ModelDescriptor] {
        [
            ModelDescriptor(providerID: identifier, name: "claude-sonnet-4-5", isLocal: false,
                            capabilityNote: "Balanced: strong reasoning at good speed"),
            ModelDescriptor(providerID: identifier, name: "claude-opus-4-1", isLocal: false,
                            capabilityNote: "Highest quality; slowest and most expensive"),
            ModelDescriptor(providerID: identifier, name: "claude-haiku-4-5", isLocal: false,
                            capabilityNote: "Fast and inexpensive; good for summaries"),
        ]
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        guard let apiKey else { throw SourceDeskError.missingAPIKey(provider: displayName) }
        let started = Date()
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.payload(request, stream: false))

        do {
            let (data, response) = try await HTTPClient.session(timeout: 180).data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw SourceDeskError.providerUnavailable(provider: displayName, reason: "no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPClient.errorForStatus(http.statusCode, data: data, provider: displayName,
                                                url: urlRequest.url!, retryAfter: HTTPClient.retryAfter(http))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SourceDeskError.providerRejected(provider: displayName, status: http.statusCode, message: "the response was not valid JSON")
            }
            let text = Self.text(from: object)
            let usage = object["usage"] as? [String: Any]
            return AIResponse(
                text: text,
                model: (object["model"] as? String) ?? request.model,
                usage: ChatUsage(
                    promptTokens: usage?["input_tokens"] as? Int,
                    completionTokens: usage?["output_tokens"] as? Int
                ),
                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                finishReason: object["stop_reason"] as? String
            )
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw HTTPClient.mapError(error, provider: displayName, url: urlRequest.url!)
        }
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey else { throw SourceDeskError.missingAPIKey(provider: displayName) }
                    var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.payload(request, stream: true))

                    let started = Date()
                    continuation.yield(.started(model: request.model))

                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 300
                    configuration.timeoutIntervalForResource = 1_800
                    let session = URLSession(configuration: configuration)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw SourceDeskError.providerUnavailable(provider: displayName, reason: "no HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw HTTPClient.errorForStatus(http.statusCode, data: body, provider: displayName,
                                                        url: urlRequest.url!, retryAfter: HTTPClient.retryAfter(http))
                    }

                    var accumulated = ""
                    var inputTokens: Int?
                    var outputTokens: Int?
                    var stopReason: String?

                    for try await line in LineStream(bytes) {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let json = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = json.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        switch object["type"] as? String {
                        case "content_block_delta":
                            let delta = object["delta"] as? [String: Any]
                            if let piece = delta?["text"] as? String, !piece.isEmpty {
                                accumulated += piece
                                continuation.yield(.delta(piece))
                            } else if let thinking = delta?["thinking"] as? String, !thinking.isEmpty {
                                continuation.yield(.reasoning(thinking))
                            }
                        case "message_start":
                            let message = object["message"] as? [String: Any]
                            inputTokens = (message?["usage"] as? [String: Any])?["input_tokens"] as? Int
                        case "message_delta":
                            if let delta = object["delta"] as? [String: Any] {
                                stopReason = delta["stop_reason"] as? String
                            }
                            if let usage = object["usage"] as? [String: Any] {
                                outputTokens = usage["output_tokens"] as? Int
                            }
                        case "error":
                            let error = object["error"] as? [String: Any]
                            let message = error?["message"] as? String ?? "the stream reported an error"
                            continuation.yield(.failed(.providerRejected(provider: displayName, status: 0, message: message)))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }

                    continuation.yield(.finished(AIResponse(
                        text: accumulated,
                        model: request.model,
                        usage: ChatUsage(promptTokens: inputTokens, completionTokens: outputTokens),
                        latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        finishReason: stopReason
                    )))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch let error as SourceDeskError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(HTTPClient.mapError(error, provider: "Anthropic Claude", url: baseURL)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func payload(_ request: AIRequest, stream: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        var system = request.systemPrompt ?? ""
        for message in request.messages {
            // Anthropic takes the system prompt as a top-level field, not a message.
            if message.role == .system {
                system += (system.isEmpty ? "" : "\n\n") + message.content
                continue
            }
            messages.append(["role": message.role.rawValue, "content": message.content])
        }
        if messages.isEmpty {
            messages = [["role": "user", "content": "Describe what SourceDesk is in one sentence."]]
        }
        var payload: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_tokens": request.maxTokens ?? 4_096,
            "temperature": request.temperature,
            "stream": stream
        ]
        if !system.isEmpty { payload["system"] = system }
        if !request.stopSequences.isEmpty { payload["stop_sequences"] = request.stopSequences }
        return payload
    }

    /// Concatenates the text blocks of a Messages response.
    static func text(from object: [String: Any]) -> String {
        guard let content = object["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined()
    }
}
