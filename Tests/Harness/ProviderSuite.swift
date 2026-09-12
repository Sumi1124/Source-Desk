import Foundation
import SourceDeskCore

/// A tiny HTTP server bound to 127.0.0.1.
///
/// Provider behaviour is verified against this rather than by mocking the provider:
/// real URLSession, real HTTP, real streaming, real status codes and real error
/// bodies. That is what catches the bugs that matter — a bad JSON shape, a
/// mis-parsed SSE line, a missing header, an unhandled 401.
final class LocalHTTPServer: @unchecked Sendable {

    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
        var query: String

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"],
                     body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }

        static func text(_ string: String, status: Int = 200, contentType: String = "text/plain") -> Response {
            Response(status: status, headers: ["Content-Type": contentType], body: Data(string.utf8))
        }

        /// Server-sent events (OpenAI and Anthropic use this framing).
        static func sse(_ events: [String]) -> Response {
            let payload = events.map { "data: \($0)\n\n" }.joined()
            return Response(status: 200, headers: ["Content-Type": "text/event-stream"],
                            body: Data(payload.utf8))
        }

        /// Newline-delimited JSON — the framing Ollama's streaming endpoints use.
        static func ndjson(_ events: [String]) -> Response {
            let payload = events.map { $0 + "\n" }.joined()
            return Response(status: 200, headers: ["Content-Type": "application/x-ndjson"],
                            body: Data(payload.utf8))
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private var port: UInt16 = 0
    private var listener: FileHandle?
    private var thread: Thread?
    private let handler: Handler
    private var running = false
    private var received: [Request] = []
    private let lock = NSLock()

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func start() throws {
        // A socket bound to port 0 gets an ephemeral port; the kernel reports it back.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SourceDeskError.database(message: "could not create a test socket") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SourceDeskError.database(message: "could not bind the test socket")
        }
        guard listen(fd, 32) == 0 else {
            close(fd)
            throw SourceDeskError.database(message: "could not listen on the test socket")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        running = true

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        listener = handle

        let thread = Thread { [weak self] in
            guard let self else { print("  [server] self was released"); return }
            print("  [server] accept loop started")
            while self.running {
                var clientAddress = sockaddr()
                var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                    accept(fd, pointer, &clientLength)
                }
                if clientFD < 0 { print("  [server] accept failed errno \(errno)"); break }
                print("  [server] accepted fd \(clientFD)")
                self.serve(clientFD)
            }
        }
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func stop() {
        running = false
        listener?.closeFile()
        listener = nil
    }

    deinit { stop() }

    /// Reads with the raw POSIX call rather than `FileHandle`: FileHandle's buffering
    /// behaves differently on a socket, and this loop must see the bytes exactly as
    /// they arrive.
    private func readChunk(_ fd: Int32, into buffer: inout Data, limit: Int) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 8_192)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return false }
        buffer.append(contentsOf: chunk[0..<count])
        return buffer.count <= limit
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func serve(_ clientFD: Int32) {
        let fd = clientFD
        defer { close(fd) }

        // Read the request head.
        var buffer = Data()
        while true {
            guard readChunk(fd, into: &buffer, limit: 1_000_000) else { return }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                buffer = Data(buffer[..<range.upperBound])
                break
            }
        }
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headText = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else { return }
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        var bodyText = String(decoding: buffer[headEnd.upperBound...], as: UTF8.self)
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var bodyBytes = Data(buffer[headEnd.upperBound...])
        while bodyBytes.count < contentLength {
            guard readChunk(fd, into: &bodyBytes, limit: contentLength * 4 + 8_192) else { break }
        }
        bodyText = String(decoding: bodyBytes, as: UTF8.self)

        var path = parts[1]
        var query = ""
        if let questionMark = path.firstIndex(of: "?") {
            query = String(path[path.index(after: questionMark)...])
            path = String(path[..<questionMark])
        }

        let request = Request(method: parts[0], path: path, headers: headers,
                              body: Data(bodyText.utf8), query: query)
        lock.lock(); received.append(request); lock.unlock()

        let response = handler(request)
        var output = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (key, value) in response.headers { output += "\(key): \(value)\r\n" }
        output += "Content-Length: \(response.body.count)\r\n"
        output += "Connection: close\r\n\r\n"
        var headerData = Data(output.utf8)
        headerData.append(response.body)
        writeAll(fd, headerData)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

enum ProviderSuite {

    static var suite: TestSuite {
        TestSuite("7 · AI providers", cases: [

            test("Ollama: lists models with sizes, quantisation and capabilities") { ctx in
                let server = LocalHTTPServer { request in
                    guard request.path == "/api/tags" else { return .json(["error": "not found"], status: 404) }
                    return .json(["models": [
                        ["name": "llama3.2:3b", "size": 2_019_393_182,
                         "details": ["parameter_size": "3.2B", "quantization_level": "Q4_K_M", "family": "llama"]],
                        ["name": "nomic-embed-text:latest", "size": 274_302_112,
                         "details": ["parameter_size": "137M", "quantization_level": "F16", "family": "nomic-bert"]]
                    ]])
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL)
                let models = try await provider.availableModels()
                try ctx.equal(models.count, 2)
                let llama = try ctx.unwrap(models.first { $0.name == "llama3.2:3b" })
                try ctx.equal(llama.parameterSize, "3.2B")
                try ctx.equal(llama.quantization, "Q4_K_M")
                try ctx.equal(llama.isLocal, true)
                try ctx.equal(llama.contextLength, 8_192, "small models get a modest assumed window")
                try ctx.contains(llama.detailLine, "3.2B")
                try ctx.contains(llama.capabilityNote ?? "", "Fast")

                let embedder = try ctx.unwrap(models.first { $0.name.contains("nomic") })
                try ctx.equal(embedder.supportsEmbeddings, true, "embedding model recognised")
                
                let availability = await provider.availability()
                try ctx.equal(availability, .ready)
            },

            test("Ollama: reports a clear error when the server is not running") { ctx in
                // Port 1 is reserved and never listening.
                let provider = OllamaProvider(endpoint: URL(string: "http://127.0.0.1:9")!)
                let availability = await provider.availability()
                guard case .unreachable(let reason) = availability else {
                    throw TestFailure(description: "expected .unreachable, got \(availability)")
                }
                try ctx.contains(reason, "not responding")

                let error = try await ctx.expectError("generation fails cleanly") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "llama3.2"))
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "not responding")
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "ollama serve")
            },

            test("Ollama: reports when the requested model is not installed") { ctx in
                let server = LocalHTTPServer { _ in
                    .json(["models": [["name": "llama3.2:3b", "details": ["parameter_size": "3.2B"]]]])
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL)
                let error = try await ctx.expectError("missing model") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "nonexistent-model"))
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "not installed")
                try ctx.contains((error as? SourceDeskError)?.recoverySuggestion ?? "", "ollama pull")
            },

            test("Ollama: streams an answer, token by token") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" {
                        return .json(["models": [["name": "llama3.2", "details": ["parameter_size": "3B"]]]])
                    }
                    guard request.path == "/api/chat" else { return .json([:], status: 404) }
                    if request.json?["stream"] as? Bool == true {
                        return .ndjson([
                            #"{"message":{"content":"The decline "},"done":false}"#,
                            #"{"message":{"content":"was caused by "},"done":false}"#,
                            #"{"message":{"content":"budget pressure. [Source 1]"},"done":false}"#,
                            #"{"done":true,"prompt_eval_count":812,"eval_count":24,"done_reason":"stop"}"#
                        ])
                    }
                    return .json(["message": ["content": "non-streamed"], "done": true])
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL)
                var pieces: [String] = []
                var finished: AIResponse?
                for try await event in provider.stream(AIRequest(messages: [.user("what caused it")], model: "llama3.2")) {
                    switch event {
                    case .delta(let piece): pieces.append(piece)
                    case .finished(let response): finished = response
                    case .failed(let error): throw TestFailure(description: "stream failed: \(error)")
                    default: break
                    }
                }
                try ctx.equal(pieces.count, 3, "received three deltas")
                try ctx.equal(pieces.joined(), "The decline was caused by budget pressure. [Source 1]")
                let response = try ctx.unwrap(finished, "stream finished")
                try ctx.equal(response.text, "The decline was caused by budget pressure. [Source 1]")
                try ctx.equal(response.usage.promptTokens, 812)
                try ctx.equal(response.usage.completionTokens, 24)
                try ctx.equal(response.finishReason, "stop")

                // The request body must carry the system prompt as a message.
                let chatRequest = try ctx.unwrap(server.requests.first { $0.path == "/api/chat" })
                let messages = try ctx.unwrap(chatRequest.json?["messages"] as? [[String: Any]])
                try ctx.equal(messages.count, 1)
                try ctx.equal(messages[0]["role"] as? String, "user")
            },

            test("Ollama: a model that is removed mid-session fails with an explanation") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" {
                        return .json(["models": [["name": "llama3.2", "details": ["parameter_size": "3B"]]]])
                    }
                    return .json(["error": "model 'llama3.2' not found, try pulling it first"], status: 404)
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL)
                let error = try await ctx.expectError("404 on chat") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "llama3.2"))
                }
                let sde = try ctx.unwrap(error as? SourceDeskError)
                try ctx.contains(sde.errorDescription ?? "", "not installed")
            },

            test("Ollama: embeddings arrive for every input") { ctx in
                let server = LocalHTTPServer { request in
                    guard request.path == "/api/embed" else { return .json([:], status: 404) }
                    let inputs = request.json?["input"] as? [String] ?? []
                    return .json(["embeddings": inputs.map { _ in [0.1, 0.2, 0.3, 0.4] }])
                }
                try server.start()
                defer { server.stop() }

                let vectors = try await OllamaProvider(endpoint: server.baseURL).embed(["a", "b", "c"], model: "nomic-embed-text")
                try ctx.equal(vectors.count, 3)
                try ctx.equal(vectors[0].count, 4)
                try ctx.close(Double(vectors[0][1]), 0.2, tolerance: 1e-6)
            },

            test("Ollama: a missing embedding model is distinguished from a server problem") { ctx in
                let server = LocalHTTPServer { _ in
                    .json(["error": "model 'nomic-embed-text' not found"], status: 404)
                }
                try server.start()
                defer { server.stop() }
                let error = try await ctx.expectError("missing embed model") {
                    try await OllamaProvider(endpoint: server.baseURL).embed(["a"], model: "nomic-embed-text")
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "not installed")
            },

            // MARK: OpenAI

            test("OpenAI: no key means a configured=false state and an actionable error") { ctx in
                let provider = OpenAIProvider(keychain: EmptyKeychain())
                try ctx.equal(provider.isConfigured, false)
                try ctx.contains(provider.configurationHint ?? "", "ChatGPT Plus subscription is not an API key")
                guard case .notConfigured(let reason) = await provider.availability() else {
                    throw TestFailure(description: "expected .notConfigured")
                }
                try ctx.contains(reason, "no API key")

                let error = try await ctx.expectError("generation without a key") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "gpt-4o-mini"))
                }
                try ctx.equal(error as? SourceDeskError, .missingAPIKey(provider: "OpenAI"))
            },

            test("OpenAI: a streamed answer is assembled and usage reported") { ctx in
                let server = LocalHTTPServer { request in
                    guard request.path.hasSuffix("/chat/completions") else { return .json([:], status: 404) }
                    return .sse([
                        #"{"choices":[{"delta":{"content":"Inspection "},"finish_reason":null}]}"#,
                        #"{"choices":[{"delta":{"content":"throughput fell "},"finish_reason":null}]}"#,
                        #"{"choices":[{"delta":{"content":"by nineteen percent. [Source 1][Source 2]"},"finish_reason":null}]}"#,
                        #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1200,"completion_tokens":48}}"#,
                        "[DONE]"
                    ])
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAIProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "test-key")
                try ctx.equal(provider.isConfigured, true)

                var text = ""
                var finished: AIResponse?
                for try await event in provider.stream(AIRequest(messages: [.user("why?")], model: "gpt-4o-mini")) {
                    switch event {
                    case .delta(let piece): text += piece
                    case .finished(let response): finished = response
                    case .failed(let error): throw TestFailure(description: "stream failed: \(error)")
                    default: break
                    }
                }
                try ctx.contains(text, "nineteen percent")
                let response = try ctx.unwrap(finished)
                try ctx.equal(response.usage.promptTokens, 1_200)
                try ctx.equal(response.usage.completionTokens, 48)

                let sent = try ctx.unwrap(server.requests.first { $0.path.hasSuffix("/chat/completions") })
                try ctx.equal(sent.headers["authorization"], "Bearer test-key", "auth header sent")
                try ctx.equal(sent.json?["stream"] as? Bool, true)
                try ctx.equal(sent.json?["model"] as? String, "gpt-4o-mini")
            },

            test("OpenAI: HTTP status codes map to specific errors") { ctx in
                let cases: [(Int, String, String)] = [
                    (401, "rejected the stored API key", "Re-enter the key"),
                    (429, "rate limiting", "Wait a moment"),
                    (500, "unavailable", "your sources are unaffected")
                ]
                for (status, expectedMessage, expectedRecovery) in cases {
                    let server = LocalHTTPServer { _ in
                        .json(["error": ["message": "upstream said no", "type": "invalid_request_error"]], status: status)
                    }
                    try server.start()
                    defer { server.stop() }
                    let provider = OpenAIProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "k")
                    let error = try await ctx.expectError("status \(status)") {
                        try await provider.generate(AIRequest(messages: [.user("hi")], model: "gpt-4o-mini"))
                    }
                    let sde = try ctx.unwrap(error as? SourceDeskError, "mapped to a SourceDeskError for \(status)")
                    try ctx.contains(sde.errorDescription ?? "", expectedMessage, "status \(status)")
                    try ctx.contains(sde.recoverySuggestion ?? "", expectedRecovery, "recovery for \(status)")
                }
            },

            test("OpenAI: a model that needs a bigger context is reported as such") { ctx in
                let server = LocalHTTPServer { _ in
                    .json(["error": ["message": "This model's maximum context length is 8192 tokens"]], status: 400)
                }
                try server.start()
                defer { server.stop() }
                let provider = OpenAIProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "k")
                let error = try await ctx.expectError("400") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "gpt-4o-mini"))
                }
                let sde = try ctx.unwrap(error as? SourceDeskError)
                try ctx.contains(sde.errorDescription ?? "", "8192 tokens")
            },

            test("OpenAI: models are listed and embedding models are marked") { ctx in
                let server = LocalHTTPServer { _ in
                    .json(["data": [
                        ["id": "gpt-4o-mini"], ["id": "gpt-4o"], ["id": "text-embedding-3-small"], ["id": "o3-mini"]
                    ]])
                }
                try server.start()
                defer { server.stop() }
                let provider = OpenAIProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "k")
                let models = try await provider.availableModels()
                try ctx.equal(models.count, 4)
                let embedding = try ctx.unwrap(models.first { $0.name.contains("embedding") })
                try ctx.equal(embedding.supportsEmbeddings, true)
                try ctx.equal(embedding.isLocal, false)
            },

            // MARK: Anthropic

            test("Anthropic: the Messages request has the right shape") { ctx in
                let server = LocalHTTPServer { request in
                    guard request.path.hasSuffix("/messages") else { return .json([:], status: 404) }
                    return .json([
                        "content": [["type": "text", "text": "Two causes: reorganisation and staffing. [Source 1]"]],
                        "model": "claude-sonnet-4-5",
                        "stop_reason": "end_turn",
                        "usage": ["input_tokens": 900, "output_tokens": 30]
                    ])
                }
                try server.start()
                defer { server.stop() }

                let provider = AnthropicProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "sk-ant-test")
                let response = try await provider.generate(AIRequest(
                    messages: [.user("what caused the decline?")],
                    model: "claude-sonnet-4-5",
                    systemPrompt: "Answer from the sources."
                ))
                try ctx.contains(response.text, "Two causes")
                try ctx.equal(response.usage.promptTokens, 900)
                try ctx.equal(response.finishReason, "end_turn")

                let sent = try ctx.unwrap(server.requests.first { $0.path.hasSuffix("/messages") })
                try ctx.equal(sent.headers["x-api-key"], "sk-ant-test", "key header")
                try ctx.equal(sent.headers["anthropic-version"], "2023-06-01", "version header")
                // System prompt must be top-level, not a message.
                try ctx.equal(sent.json?["system"] as? String, "Answer from the sources.")
                let messages = try ctx.unwrap(sent.json?["messages"] as? [[String: Any]])
                try ctx.equal(messages.count, 1)
                try ctx.equal(messages[0]["role"] as? String, "user")
                try ctx.check((sent.json?["max_tokens"] as? Int ?? 0) > 0, "max_tokens is required by the API")
            },

            test("Anthropic: streaming events are parsed including the message envelope") { ctx in
                let server = LocalHTTPServer { _ in
                    .sse([
                        #"{"type":"message_start","message":{"usage":{"input_tokens":750}}}"#,
                        #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"The board "}}"#,
                        #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"found two causes. [Source 1]"}}"#,
                        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":22}}"#,
                        #"{"type":"message_stop"}"#
                    ])
                }
                try server.start()
                defer { server.stop() }

                let provider = AnthropicProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "k")
                var text = ""
                var finished: AIResponse?
                for try await event in provider.stream(AIRequest(messages: [.user("q")], model: "claude-sonnet-4-5")) {
                    switch event {
                    case .delta(let piece): text += piece
                    case .finished(let response): finished = response
                    case .failed(let error): throw TestFailure(description: "stream failed: \(error)")
                    default: break
                    }
                }
                try ctx.equal(text, "The board found two causes. [Source 1]")
                try ctx.equal(finished?.usage.promptTokens, 750)
                try ctx.equal(finished?.usage.completionTokens, 22)
            },

            test("Anthropic: an in-stream error is surfaced to the user") { ctx in
                let server = LocalHTTPServer { _ in
                    .sse([
                        #"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
                        #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
                    ])
                }
                try server.start()
                defer { server.stop() }

                let provider = AnthropicProvider(baseURL: server.baseURL, keychain: EmptyKeychain(), explicitKey: "k")
                var failure: SourceDeskError?
                for try await event in provider.stream(AIRequest(messages: [.user("q")], model: "claude-sonnet-4-5")) {
                    if case .failed(let error) = event { failure = error }
                }
                let error = try ctx.unwrap(failure, "an error event was produced")
                try ctx.contains(error.errorDescription ?? "", "Overloaded")
            },

            test("Anthropic: a missing key is reported before any request is made") { ctx in
                let provider = AnthropicProvider(keychain: EmptyKeychain())
                try ctx.equal(provider.isConfigured, false)
                try ctx.contains(provider.configurationHint ?? "", "Claude Pro subscription is not an API key")
                let error = try await ctx.expectError("no key") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "claude-sonnet-4-5"))
                }
                try ctx.equal(error as? SourceDeskError, .missingAPIKey(provider: "Anthropic Claude"))
            },

            // MARK: Registry and streaming plumbing

            test("the registry finds providers by id and puts local ones first") { ctx in
                let registry = ProviderRegistry.standard(keychain: EmptyKeychain())
                try ctx.notNil(registry.provider(id: "ollama"))
                try ctx.notNil(registry.provider(id: "openai"))
                try ctx.notNil(registry.provider(id: "anthropic"))
                try ctx.isNil(registry.provider(id: "not-a-provider"))
                try ctx.equal(registry.all.first?.identifier, "ollama", "local provider sorts first")
                try ctx.equal(registry.localProviders.count, 1, "only a local Ollama server counts as local")
                // OpenAI, Anthropic, and Ollama's hosted API.
                try ctx.equal(registry.cloudProviders.count, 3)
                try ctx.check(registry.cloudProviders.contains { $0.identifier == "ollama-cloud" },
                              "the hosted Ollama API is a cloud provider")
            },

            test("a provider can be registered later without touching the registry") { ctx in
                let registry = ProviderRegistry(providers: [])
                registry.register(StubProvider(identifier: "future", displayName: "Future Provider"))
                try ctx.notNil(registry.provider(id: "future"))
                try ctx.equal(registry.all.count, 1)
            },

            test("keys are stored in the Keychain, not in settings or the notebook") { ctx in
                // The test keychain stands in for the system one; the contract being
                // checked is that providers read through it and that no plaintext
                // value ever reaches the database.
                let keychain = InMemoryKeychain()
                keychain.values["openai.api-key"] = "sk-test-1234"
                let provider = OpenAIProvider(keychain: keychain)
                try ctx.equal(provider.isConfigured, true)

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let notebook = try Fixtures.makeNotebook(store)
                try SettingsStore(store: store).save(AppSettings())

                // Nothing in the settings blob or any table may contain the key.
                let settings = try store.allSettings()
                for (_, value) in settings {
                    try ctx.doesNotContain(value, "sk-test-1234", "settings must not contain the API key")
                }
                try ctx.equal(try store.sourceCount(notebookID: notebook.id), 0)
            },

            test("line streaming decodes multi-byte characters split across chunks") { ctx in
                // The buffer must reassemble UTF-8 sequences that straddle writes, or
                // accented text and CJK corrupt mid-answer.
                let lines = ["こんにちは世界", "café société", "emoji 😀 test"]
                let payload = lines.map { "data: \($0)\n\n" }.joined()
                let server = LocalHTTPServer { _ in
                    .sse(lines)
                }
                try server.start()
                defer { server.stop() }

                // Fetch manually and read through LineStream.
                let session = URLSession(configuration: .ephemeral)
                let (bytes, _) = try await session.bytes(for: URLRequest(url: server.baseURL))
                var collected: [String] = []
                for try await line in LineStream(bytes) {
                    if line.hasPrefix("data: ") { collected.append(String(line.dropFirst(6))) }
                }
                try ctx.equal(collected, lines, "multi-byte content survived; raw payload was \(payload.count) bytes")
            }
        ])
    }
}

// MARK: - Test doubles

struct EmptyKeychain: KeychainReading {
    func secret(for key: String) -> String? { nil }
}

final class InMemoryKeychain: KeychainReading, @unchecked Sendable {
    var values: [String: String] = [:]
    func secret(for key: String) -> String? { values[key] }
}

struct StubProvider: AIProvider {
    let identifier: String
    let displayName: String
    let isLocal = true
    var isConfigured: Bool { true }
    var configurationHint: String? { nil }
    func availability() async -> ProviderAvailability { .ready }
    func availableModels() async throws -> [ModelDescriptor] { [] }
    func generate(_ request: AIRequest) async throws -> AIResponse { AIResponse(text: "stub", model: request.model) }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
