import Foundation

// MARK: - Model descriptor

/// A model the user can pick, regardless of where it runs.
public struct ModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var providerID: String
    public var name: String
    /// Human-readable size, e.g. "4.7 GB" for a local model.
    public var sizeDescription: String?
    public var parameterSize: String?
    public var quantization: String?
    public var contextLength: Int?
    /// True when `contextLength` was measured or reported. False when it is an estimate
    /// inferred from the parameter count, which must not be presented as a fact.
    public var contextLengthIsEstimated: Bool = false
    public var isLocal: Bool
    public var supportsEmbeddings: Bool
    public var supportsStreaming: Bool
    /// Free-text capability hint shown in the picker.
    public var capabilityNote: String?

    public var id: String { "\(providerID):\(name)" }

    public init(
        providerID: String,
        name: String,
        sizeDescription: String? = nil,
        parameterSize: String? = nil,
        quantization: String? = nil,
        contextLength: Int? = nil,
        contextLengthIsEstimated: Bool = false,
        isLocal: Bool = true,
        supportsEmbeddings: Bool = false,
        supportsStreaming: Bool = true,
        capabilityNote: String? = nil
    ) {
        self.providerID = providerID
        self.name = name
        self.sizeDescription = sizeDescription
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.contextLength = contextLength
        self.contextLengthIsEstimated = contextLengthIsEstimated
        self.isLocal = isLocal
        self.supportsEmbeddings = supportsEmbeddings
        self.supportsStreaming = supportsStreaming
        self.capabilityNote = capabilityNote
    }

    /// Secondary line in the model picker.
    public var detailLine: String {
        var parts: [String] = []
        if let parameterSize { parts.append(parameterSize) }
        if let quantization { parts.append(quantization) }
        if let sizeDescription { parts.append(sizeDescription) }
        if let contextLength {
            // An inferred window is labelled as an estimate; reporting a guess as the
            // model's real context window is the kind of small lie that makes a whole
            // interface untrustworthy.
            parts.append(contextLengthIsEstimated
                         ? "~\(contextLength.formatted()) token context (est.)"
                         : "\(contextLength.formatted()) token context")
        }
        if parts.isEmpty { parts.append(isLocal ? "Local model" : "Cloud model") }
        return parts.joined(separator: " · ")
    }

    /// Rough guidance for the retrieval configuration: how much source material
    /// this model can hold.
    public var effectiveContextLength: Int { contextLength ?? 8_192 }
}

// MARK: - Generation requests

public struct AIMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> AIMessage { AIMessage(role: .system, content: content) }
    public static func user(_ content: String) -> AIMessage { AIMessage(role: .user, content: content) }
    public static func assistant(_ content: String) -> AIMessage { AIMessage(role: .assistant, content: content) }
}

public struct AIRequest: Sendable {
    public var messages: [AIMessage]
    public var model: String
    public var temperature: Double
    public var maxTokens: Int?
    public var systemPrompt: String?
    /// Ask the provider to end generation cleanly at a token boundary rather than
    /// mid-word (Ollama only, ignored elsewhere).
    public var stopSequences: [String]

    public init(
        messages: [AIMessage],
        model: String,
        temperature: Double = 0.2,
        maxTokens: Int? = nil,
        systemPrompt: String? = nil,
        stopSequences: [String] = []
    ) {
        self.messages = messages
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
        self.stopSequences = stopSequences
    }
}

public struct ChatUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public struct AIResponse: Sendable {
    public var text: String
    public var model: String
    public var usage: ChatUsage
    public var latencyMilliseconds: Int
    /// Reported when the provider stopped for a reason the user should know about
    /// (length limit, content filter, tool call).
    public var finishReason: String?

    public init(text: String, model: String, usage: ChatUsage = ChatUsage(), latencyMilliseconds: Int = 0, finishReason: String? = nil) {
        self.text = text
        self.model = model
        self.usage = usage
        self.latencyMilliseconds = latencyMilliseconds
        self.finishReason = finishReason
    }

    public var wasTruncated: Bool {
        guard let finishReason else { return false }
        return finishReason.lowercased() == "length" || finishReason.lowercased() == "max_tokens"
    }
}

/// Token-by-token output during streaming.
public enum StreamEvent: Sendable {
    case started(model: String)
    case delta(String)
    /// Provider-reported thinking/reasoning text (Anthropic extended thinking), kept
    /// separate so it is not mixed into the answer body.
    case reasoning(String)
    case finished(AIResponse)
    case failed(SourceDeskError)
}

// MARK: - Provider protocol

/// The contract every model backend implements.
///
/// Adding a provider (a different local runtime, a self-hosted gateway, another
/// vendor) means conforming to this protocol and registering it — no changes to the
/// chat, retrieval or UI layers.
public protocol AIProvider: Sendable {
    /// Stable identifier persisted in settings and per-session records.
    var identifier: String { get }
    var displayName: String { get }
    var isLocal: Bool { get }
    /// Whether a key/endpoint is configured. Does not perform network I/O.
    var isConfigured: Bool { get }
    /// Explanation of what is missing, for the settings screen.
    var configurationHint: String? { get }

    /// Whether the provider is reachable right now, and why not if it is not.
    func availability() async -> ProviderAvailability
    /// Models the user can choose. Empty when the provider is unreachable.
    func availableModels() async throws -> [ModelDescriptor]
    func generate(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error>
    /// Embeddings, when the provider supports them.
    func embed(_ texts: [String], model: String) async throws -> [[Float]]
}

public enum ProviderAvailability: Sendable, Equatable {
    case ready
    case notConfigured(reason: String)
    case unreachable(reason: String)
    /// Explicitly blocked — offline, or local-only mode.
    case unavailable(reason: String)

    public var isReady: Bool { self == .ready }

    public var reason: String? {
        switch self {
        case .ready: return nil
        case .notConfigured(let reason), .unreachable(let reason), .unavailable(let reason): return reason
        }
    }
}

extension AIProvider {
    /// Default: no embedding support. Providers that can, override this.
    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        throw SourceDeskError.modelDoesNotSupportEmbeddings(provider: displayName, model: model)
    }
}

// MARK: - Streaming line reader

/// Reads a byte stream and yields complete lines.
///
/// Every provider streams either SSE (`data: {...}`) or newline-delimited JSON, and
/// a naive `String(data:)` per chunk corrupts multi-byte characters that straddle a
/// chunk boundary — which is exactly what happens with accented text and CJK. This
/// buffers raw bytes and only decodes whole lines.
public struct LineStream: AsyncSequence, Sendable {
    public typealias Element = String

    private let upstream: URLSession.AsyncBytes

    public init(_ upstream: URLSession.AsyncBytes) {
        self.upstream = upstream
    }

    public struct Iterator: AsyncIteratorProtocol {
        var upstream: URLSession.AsyncBytes.Iterator
        var buffer = [UInt8]()

        public mutating func next() async throws -> String? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let lineBytes = Array(buffer[0..<newline])
                    buffer.removeFirst(newline + 1)
                    var line = String(decoding: lineBytes, as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    return line
                }
                guard let byte = try await upstream.next() else {
                    guard !buffer.isEmpty else { return nil }
                    let remainder = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll()
                    return remainder
                }
                buffer.append(byte)
            }
        }
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(upstream: upstream.makeAsyncIterator())
    }
}

// MARK: - Shared HTTP helpers

public enum HTTPClient {

    public static func session(timeout: TimeInterval = 120) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 6
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": Networking.userAgent]
        return URLSession(configuration: configuration)
    }

    /// Maps a failed request onto a specific, actionable error.
    public static func mapError(_ error: Error, provider: String, url: URL) -> SourceDeskError {
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut:
            return .requestTimedOut(url: url.absoluteString, seconds: nsError.userInfo["timeout"] as? Double ?? 120)
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
            return .providerUnavailable(provider: provider, reason: "could not reach \(url.host() ?? url.absoluteString)")
        case NSURLErrorNotConnectedToInternet:
            return .offline(feature: provider)
        case NSURLErrorCancelled:
            return .cancelled
        default:
            return .providerUnavailable(provider: provider, reason: error.localizedDescription)
        }
    }

    /// Turns a non-2xx response into the most specific error available, including
    /// the provider's own message when it sends one.
    public static func errorForStatus(
        _ status: Int,
        data: Data,
        provider: String,
        url: URL,
        retryAfter: TimeInterval? = nil
    ) -> SourceDeskError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { object -> String? in
                if let error = object["error"] as? [String: Any] {
                    return (error["message"] as? String) ?? (error["type"] as? String)
                }
                if let error = object["error"] as? String { return error }
                if let message = object["message"] as? String { return message }
                return nil
            }
            ?? String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        switch status {
        case 401, 403:
            return .invalidAPIKey(provider: provider)
        case 404:
            return .providerRejected(provider: provider, status: status,
                                     message: message.isEmpty ? "not found — check the model name" : message)
        case 413:
            return .contextTooLarge(model: provider, neededTokens: 0, limitTokens: 0)
        case 422:
            return .providerRejected(provider: provider, status: status, message: message)
        case 429:
            return .providerRateLimited(provider: provider, retryAfter: retryAfter)
        case 500...599:
            return .providerUnavailable(provider: provider, reason: message.isEmpty ? "the server returned HTTP \(status)" : message)
        default:
            return .providerRejected(provider: provider, status: status, message: message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    public static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return date.timeIntervalSinceNow }
        return nil
    }
}

public enum Networking {
    /// Providers increasingly reject unknown or generic user agents; identifying
    /// honestly keeps the app on the right side of provider terms.
    public static let userAgent = "SourceDesk/1.0 (macOS; +https://github.com/Sumi1124/Source-Desk)"
}
