import Foundation
import SourceDeskCore

/// Ollama's hosted API.
///
/// Ollama serves one API from two places — a server on the user's own machine and
/// `https://ollama.com`. These tests cover the differences that matter: the bearer
/// token, the wording of a hosted 401, model metadata that the hosted catalogue does
/// not provide, and the fact that a remote host is not "local" for privacy purposes.
enum OllamaCloudSuite {

    /// The provider under test in this suite is standing in for the hosted API, but
    /// the requests go to a loopback test server. The cloud role is therefore stated
    /// explicitly — which is exactly what the app does, so the fixtures match the
    /// production wiring rather than relying on the host to imply it.

    /// A response shaped exactly like the live `https://ollama.com/api/tags`: the
    /// cloud catalogue returns names with no `details` at all.
    /// Note the shape: `details` comes back with keys present but *empty*, exactly as
    /// the live endpoint returns them. A fixture that simply omitted these keys would
    /// hide the fact that an empty string must be treated as "unknown".
    static let emptyDetails: [String: Any] = [
        "parent_model": "", "format": "", "family": "", "families": NSNull(),
        "parameter_size": "", "quantization_level": ""
    ]

    static let cloudCatalogue: [[String: Any]] = [
        ["name": "gpt-oss:120b", "model": "gpt-oss:120b", "size": 65_290_180_781, "digest": "d98fe6ba01", "details": emptyDetails],
        ["name": "gpt-oss:20b", "model": "gpt-oss:20b", "size": 13_780_162_412, "digest": "05afbac4ba", "details": emptyDetails],
        ["name": "mistral-large-3:675b", "model": "mistral-large-3:675b", "size": 682_000_000_000, "digest": "f7e3b2a16d", "details": emptyDetails],
        ["name": "minimax-m3", "model": "minimax-m3", "size": 0, "digest": "9ce5291d9c", "details": emptyDetails],
        ["name": "glm-5.3", "model": "glm-5.3", "size": 755_433_728_000, "digest": "632dfda18c6d", "details": emptyDetails],
        ["name": "nomic-embed-text", "model": "nomic-embed-text", "size": 274_302_112, "digest": "0a109f422b", "details": emptyDetails],
        ["name": "qwen3.5:397b", "model": "qwen3.5:397b", "size": 397_000_000_000, "digest": "b909ca2f1b", "details": emptyDetails],
        ["name": "kimi-k3", "model": "kimi-k3", "size": 1_560_860_324_864, "digest": "d189309738", "details": emptyDetails]
    ]

    static var suite: TestSuite {
        TestSuite("14 · Ollama Cloud API", cases: [

            test("the hosted endpoint is recognised as cloud, a local one is not") { ctx in
                let cloud = OllamaProvider(endpoint: URL(string: "https://ollama.com")!)
                try ctx.equal(cloud.isCloud, true)
                try ctx.equal(cloud.isLocal, false, "a remote host is not local, so privacy rules apply")
                try ctx.equal(cloud.identifier, "ollama-cloud")
                try ctx.equal(cloud.displayName, "Ollama Cloud")

                let local = OllamaProvider(endpoint: URL(string: "http://127.0.0.1:11434")!)
                try ctx.equal(local.isCloud, false)
                try ctx.equal(local.isLocal, true)
                try ctx.equal(local.identifier, "ollama", "the local provider keeps its original identifier")
                try ctx.equal(local.displayName, "Ollama (local)")
            },

            test("a model server on the user's own network counts as local") { ctx in
                // The privacy distinction is "the user controls this host", not
                // "the host is loopback".
                for endpoint in ["http://127.0.0.1:11434", "http://localhost:11434",
                                 "http://mac-studio.local:11434", "http://10.0.0.5:11434",
                                 "http://192.168.1.20:11434", "http://172.16.4.9:11434"] {
                    try ctx.equal(Networking.isPrivateNetworkEndpoint(URL(string: endpoint)!), true, endpoint)
                }
                for endpoint in ["https://ollama.com", "http://203.0.113.10:11434",
                                 "https://ollama.example.com", "http://172.32.0.1:11434"] {
                    try ctx.equal(Networking.isPrivateNetworkEndpoint(URL(string: endpoint)!), false, endpoint)
                }
                let remoteLAN = OllamaProvider(endpoint: URL(string: "http://192.168.1.20:11434")!)
                try ctx.equal(remoteLAN.isLocal, true, "a LAN host is not a third party")
                try ctx.equal(remoteLAN.identifier, "ollama", "and is the same provider as the local one")
            },

            test("no API key means not configured, with the right advice") { ctx in
                let provider = OllamaProvider(endpoint: OllamaProvider.cloudEndpoint, keychain: EmptyKeychain())
                try ctx.equal(provider.isConfigured, false)
                try ctx.contains(provider.configurationHint ?? "", "ollama.com/settings/keys")
                try ctx.contains(provider.configurationHint ?? "", "Keychain")

                let availability = await provider.availability()
                guard case .notConfigured(let reason) = availability else {
                    throw TestFailure(description: "expected .notConfigured, got \(availability)")
                }
                try ctx.contains(reason, "no Ollama API key")

                // The local provider needs no key at all.
                let local = OllamaProvider(endpoint: URL(string: "http://127.0.0.1:11434")!, keychain: EmptyKeychain())
                try ctx.equal(local.isConfigured, true)
            },

            test("the API key is sent as a bearer token on every call") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" {
                        return .json(["models": OllamaCloudSuite.cloudCatalogue])
                    }
                    if request.path == "/api/chat" {
                        let payload = ["message": ["content": "Two causes. [Source 1]"], "done": true, "done_reason": "stop"]
                        return .json(payload)
                    }
                    if request.path == "/api/embed" {
                        return .json(["embeddings": [[0.1, 0.2]]])
                    }
                    return .json(["error": "not found"], status: 404)
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain(), explicitKey: "ollama-key-123")
                try ctx.equal(provider.isConfigured, true)

                _ = try await provider.availableModels()
                _ = try await provider.generate(AIRequest(messages: [.user("why?")], model: "gpt-oss:120b"))
                _ = try await provider.embed(["text"], model: "nomic-embed-text")

                for path in ["/api/tags", "/api/chat", "/api/embed"] {
                    let request = try ctx.unwrap(server.requests.first { $0.path == path }, "\(path) was called")
                    try ctx.equal(request.headers["authorization"], "Bearer ollama-key-123",
                                  "\(path) carried the bearer token")
                }
            },

            test("a hosted 401 becomes 'rejected the stored API key'") { ctx in
                let server = LocalHTTPServer { _ in
                    // The exact body the live endpoint returns.
                    .json(["error": "Unauthorized"], status: 401)
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain(), explicitKey: "wrong-key")
                let error = try await ctx.expectError("401") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "gpt-oss:120b"))
                }
                let sde = try ctx.unwrap(error as? SourceDeskError)
                try ctx.contains(sde.errorDescription ?? "", "rejected the stored API key")
                try ctx.contains(sde.recoverySuggestion ?? "", "Re-enter the key")
            },

            test("a 401 during streaming is reported before any text is shown") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" { return .json(["models": OllamaCloudSuite.cloudCatalogue]) }
                    return .json(["error": "Unauthorized"], status: 401)
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain(), explicitKey: "k")
                var failure: SourceDeskError?
                for try await event in provider.stream(AIRequest(messages: [.user("hi")], model: "gpt-oss:120b")) {
                    if case .failed(let error) = event { failure = error }
                }
                let sde = try ctx.unwrap(failure, "the stream reported a failure")
                try ctx.contains(sde.errorDescription ?? "", "rejected the stored API key")
            },

            test("an in-stream error body is mapped, not swallowed") { ctx in
                // Ollama reports a mid-stream problem as an NDJSON object with "error".
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" { return .json(["models": OllamaCloudSuite.cloudCatalogue]) }
                    return .ndjson([
                        #"{"message":{"content":"partial "},"done":false}"#,
                        #"{"error":"model requires a subscription"}"#
                    ])
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain(), explicitKey: "k")
                var failure: SourceDeskError?
                for try await event in provider.stream(AIRequest(messages: [.user("hi")], model: "gpt-oss:120b")) {
                    if case .failed(let error) = event { failure = error }
                }
                let sde = try ctx.unwrap(failure)
                try ctx.contains(sde.errorDescription ?? "", "does not have access")
                try ctx.contains(sde.recoverySuggestion ?? "", "local model")
            },

            test("each error body maps to the error that names the actual fix") { ctx in
                let endpoint = OllamaProvider.cloudEndpoint
                func map(_ message: String) -> SourceDeskError {
                    OllamaProvider.generationError(message, model: "gpt-oss:120b", endpoint: endpoint)
                }

                let unauthorized = map("Unauthorized")
                try ctx.contains(unauthorized.errorDescription ?? "", "rejected the stored API key")

                let missing = map("model 'gpt-oss:999b' not found, try pulling it first")
                try ctx.contains(missing.errorDescription ?? "", "not installed")
                try ctx.contains(missing.recoverySuggestion ?? "", "ollama pull")

                let context = map("prompt is too long: 200000 tokens > 131072 maximum")
                try ctx.contains(context.errorDescription ?? "", "cannot hold this request")

                let denied = map("this model is not available on your plan")
                try ctx.contains(denied.errorDescription ?? "", "does not have access")

                let limited = map("rate limit exceeded, please try again later")
                try ctx.contains(limited.errorDescription ?? "", "rate limiting")
                let rateLimited = try ctx.unwrap(limited as? SourceDeskError)
                try ctx.contains(rateLimited.recoverySuggestion ?? "", "local model")

                // Anything unrecognised still reaches the user verbatim.
                let other = map("something entirely new happened")
                try ctx.contains(other.errorDescription ?? "", "something entirely new happened")
            },

            test("hosted models get a real context window and no fake download size") { ctx in
                let server = LocalHTTPServer { _ in
                    .json(["models": OllamaCloudSuite.cloudCatalogue])
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain(), explicitKey: "k")
                let models = try await provider.availableModels()

                try ctx.equal(models.count, cloudCatalogue.count)
                let large = try ctx.unwrap(models.first { $0.name == "gpt-oss:120b" })
                // The catalogue returns an empty `details` object, so the parameter
                // count has to come from the name — otherwise every cloud model would
                // be assumed to hold 8k tokens.
                try ctx.equal(large.parameterSize, "120B")
                try ctx.check((large.contextLength ?? 0) >= 131_072, "got \(large.contextLength ?? 0)")
                try ctx.equal(large.isLocal, false)
                try ctx.contains(large.capabilityNote ?? "", "hosted")
                try ctx.isNil(large.sizeDescription, "an uncompressed hosted size is not a download size")

                let small = try ctx.unwrap(models.first { $0.name == "gpt-oss:20b" })
                try ctx.equal(small.parameterSize, "20B")

                let huge = try ctx.unwrap(models.first { $0.name == "mistral-large-3:675b" })
                try ctx.equal(huge.parameterSize, "675B")
                try ctx.check((huge.contextLength ?? 0) >= 262_144, "very large models get a large window")

                // A name with no parameter count must not be misread from its version.
                let versioned = try ctx.unwrap(models.first { $0.name == "glm-5.3" })
                try ctx.isNil(versioned.parameterSize, "a version number is not a parameter count")

                // Embedding models are still recognised for the embedding picker.
                let embedding = try ctx.unwrap(models.first { $0.name == "nomic-embed-text" })
                try ctx.equal(embedding.supportsEmbeddings, true)
            },

            test("empty metadata strings are treated as unknown, not as values") { ctx in
                // The live endpoint returns `"parameter_size": ""`. Treating that as a
                // value meant `?? guess` never ran, so every hosted model showed no
                // parameter count in the picker.
                let server = LocalHTTPServer { _ in .json(["models": OllamaCloudSuite.cloudCatalogue]) }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .cloud,
                                              keychain: EmptyKeychain(), explicitKey: "k")
                let models = try await provider.availableModels()
                // Blank strings must not survive as values.
                for model in models {
                    if let parameterSize = model.parameterSize {
                        try ctx.check(!parameterSize.trimmingCharacters(in: .whitespaces).isEmpty,
                                      "\(model.name): a blank parameter size is not a value")
                    }
                    try ctx.isNil(model.quantization, "\(model.name): an empty quantisation is not a quantisation")
                }
                // Where the name genuinely carries a count, it must now be recovered —
                // this is the part that regressed.
                let large = try ctx.unwrap(models.first { $0.name == "gpt-oss:120b" })
                try ctx.equal(large.parameterSize, "120B")
                let huge = try ctx.unwrap(models.first { $0.name == "mistral-large-3:675b" })
                try ctx.equal(huge.parameterSize, "675B")
                // And where it does not, "unknown" is the honest answer — a version
                // number must never be read as a parameter count.
                let versioned = try ctx.unwrap(models.first { $0.name == "glm-5.3" })
                try ctx.isNil(versioned.parameterSize, "a version number is not a parameter count")
            },

            test("a local catalogue with blank metadata behaves the same way") { ctx in
                // A local server that reports a real quantisation must keep it.
                let server = LocalHTTPServer { _ in
                    .json(["models": [["name": "llama3.2:3b", "size": 2_019_393_182,
                                       "details": ["parameter_size": "3.2B", "quantization_level": "Q4_K_M", "family": "llama"]]]])
                }
                try server.start()
                defer { server.stop() }
                let provider = OllamaProvider(endpoint: server.baseURL, host: .local, keychain: EmptyKeychain())
                let model = try ctx.unwrap(try await provider.availableModels().first)
                try ctx.equal(model.parameterSize, "3.2B")
                try ctx.equal(model.quantization, "Q4_K_M")
                try ctx.notNil(model.sizeDescription, "a local model does show its download size")
            },

            test("a hosted model the account cannot run still reports clearly") { ctx in
                // The listing succeeds (it lists the whole catalogue), but the chat
                // call is refused. The check must not fail early on a false negative.
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" { return .json(["models": OllamaCloudSuite.cloudCatalogue]) }
                    return .json(["error": "model 'kimi-k3' is not available for this account"], status: 403)
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain(), explicitKey: "k")
                let error = try await ctx.expectError("403") {
                    try await provider.generate(AIRequest(messages: [.user("hi")], model: "kimi-k3"))
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "does not have access")
            },

            test("the hosted catalogue can be listed without a key, but chat cannot") { ctx in
                // Mirrors the live endpoint exactly: /api/tags answers unauthenticated
                // (that is how the app can show what exists before a key is entered),
                // while generation requires the token.
                let server = LocalHTTPServer { request in
                    let authorized = request.headers["authorization"]?.hasPrefix("Bearer ") == true
                    if request.path == "/api/tags" { return .json(["models": OllamaCloudSuite.cloudCatalogue]) }
                    if !authorized { return .json(["error": "Unauthorized"], status: 401) }
                    return .json(["message": ["content": "ok"], "done": true])
                }
                try server.start()
                defer { server.stop() }

                let keyless = OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain())
                let models = try await keyless.availableModels()
                try ctx.equal(models.count, cloudCatalogue.count, "the catalogue is visible without a key")

                let error = try await ctx.expectError("chat needs the key") {
                    try await keyless.generate(AIRequest(messages: [.user("hi")], model: "gpt-oss:120b"))
                }
                try ctx.contains((error as? SourceDeskError)?.errorDescription ?? "", "no API key is stored")
            },

            test("cloud use is refused offline, in local-only mode and without consent") { ctx in
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, _) = try RetrievalSuite.makeCorpus(store)

                func engine(localOnly: Bool, consented: Bool, online: Bool) -> AnswerEngine {
                    AnswerEngine(
                        store: store,
                        providers: ProviderRegistry(providers: [
                            OllamaProvider(endpoint: URL(string: "https://ollama.com")!,
                                           host: .cloud, keychain: EmptyKeychain(), explicitKey: "k")
                        ]),
                        embedder: BuiltInEmbedder(),
                        search: nil,
                        configuration: .init(providerID: "ollama-cloud", modelName: "gpt-oss:120b",
                                             localOnlyMode: localOnly, cloudConsentGranted: consented),
                        networkIsOnline: { online }
                    )
                }

                // Offline.
                let offline = try await ctx.expectError("offline") {
                    try await engine(localOnly: false, consented: true, online: false)
                        .answerOnce(question: "what caused the decline", notebookID: notebook.id)
                }
                try ctx.contains((offline as? SourceDeskError)?.errorDescription ?? "", "internet connection")

                // Local-Only Mode.
                let localOnly = try await ctx.expectError("local-only") {
                    try await engine(localOnly: true, consented: true, online: true)
                        .answerOnce(question: "what caused the decline", notebookID: notebook.id)
                }
                try ctx.contains((localOnly as? SourceDeskError)?.recoverySuggestion ?? "", "Local-Only Mode")

                // No consent yet.
                let noConsent = try await ctx.expectError("no consent") {
                    try await engine(localOnly: false, consented: false, online: true)
                        .answerOnce(question: "what caused the decline", notebookID: notebook.id)
                }
                try ctx.contains((noConsent as? SourceDeskError)?.recoverySuggestion ?? "", "banner above the composer")
            },

            test("answers from a hosted model are marked as leaving the Mac") { ctx in
                let server = LocalHTTPServer { request in
                    if request.path == "/api/tags" { return .json(["models": OllamaCloudSuite.cloudCatalogue]) }
                    return .ndjson([
                        #"{"message":{"content":"Throughput fell by nineteen percent. [Source 1]"},"done":false}"#,
                        #"{"done":true,"prompt_eval_count":900,"eval_count":30,"done_reason":"stop"}"#
                    ])
                }
                try server.start()
                defer { server.stop() }

                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let (notebook, sources) = try RetrievalSuite.makeCorpus(store)

                let engine = AnswerEngine(
                    store: store,
                    providers: ProviderRegistry(providers: [
                        OllamaProvider(endpoint: server.baseURL, host: .cloud, keychain: EmptyKeychain(), explicitKey: "k")
                    ]),
                    embedder: BuiltInEmbedder(),
                    search: nil,
                    configuration: .init(providerID: "ollama-cloud", modelName: "gpt-oss:120b", cloudConsentGranted: true)
                )
                let outcome = try await engine.answerOnce(
                    question: "What caused the decline in inspection throughput?",
                    notebookID: notebook.id
                )

                try ctx.contains(outcome.answer, "nineteen percent")
                try ctx.equal(outcome.privacyLevel, .cloud, "a hosted model is not a local one")
                try ctx.equal(outcome.provider, "ollama-cloud")
                try ctx.equal(outcome.citations.count, 1)
                let cited = try ctx.unwrap(outcome.citations[0].sourceID)
                try ctx.check(sources.contains { $0.id == cited }, "the citation resolves to a real source")

                // The grounding prompts still reached the model.
                let chat = try ctx.unwrap(server.requests.first { $0.path == "/api/chat" })
                let messages = try ctx.unwrap(chat.json?["messages"] as? [[String: Any]])
                try ctx.contains(messages.first?["content"] as? String ?? "", "GROUNDING RULES")
                try ctx.contains(messages.last?["content"] as? String ?? "", "[Source 1]")
            },

            test("the registry offers the hosted provider without duplicating the local one") { ctx in
                let registry = ProviderRegistry.standard(keychain: EmptyKeychain())
                try ctx.notNil(registry.provider(id: "ollama"))
                try ctx.notNil(registry.provider(id: "ollama-cloud"))
                try ctx.notNil(registry.provider(id: "openai"))
                try ctx.notNil(registry.provider(id: "anthropic"))

                let local = try ctx.unwrap(registry.provider(id: "ollama"))
                let cloud = try ctx.unwrap(registry.provider(id: "ollama-cloud"))
                try ctx.equal(local.isLocal, true)
                try ctx.equal(cloud.isLocal, false)
                try ctx.equal(registry.all.first?.identifier, "ollama", "a local provider still sorts first")

                // Pointing both endpoints at the same host must not list it twice.
                let collapsed = ProviderRegistry.standard(
                    ollamaEndpoint: URL(string: "https://ollama.com")!,
                    ollamaCloudEndpoint: URL(string: "https://ollama.com")!,
                    keychain: EmptyKeychain()
                )
                let ollamaEntries = collapsed.all.filter { $0.identifier.hasPrefix("ollama") }
                try ctx.equal(ollamaEntries.count, 1, "got \(ollamaEntries.map(\.identifier))")
            },

            test("the cloud endpoint is a setting, and defaults to ollama.com") { ctx in
                let settings = AppSettings()
                try ctx.equal(settings.ollamaCloudEndpoint, "https://ollama.com")
                try ctx.equal(settings.ollamaEndpoint, "http://127.0.0.1:11434")
                try ctx.equal(settings.ollamaCloudEndpointURL.absoluteString, "https://ollama.com")

                // A settings blob written before the cloud endpoint existed must still
                // load, keeping the default.
                let (store, paths) = try Fixtures.temporaryStore()
                defer { Fixtures.cleanup(paths) }
                let partial = #"{"preferredProviderID":"ollama-cloud","modelSelection":{"ollama-cloud":"gpt-oss:120b"}}"#
                try store.setSettingValue(SettingsStore.key, partial)
                let loaded = SettingsStore(store: store).load()
                try ctx.equal(loaded.preferredProviderID, "ollama-cloud")
                try ctx.equal(loaded.model(for: "ollama-cloud"), "gpt-oss:120b")
                try ctx.equal(loaded.ollamaCloudEndpoint, "https://ollama.com", "the new field defaults cleanly")
                try ctx.equal(loaded.ollamaEndpoint, "http://127.0.0.1:11434")
            },

            test("live: the hosted catalogue is reachable and shaped as documented") { ctx in
                guard ProcessInfo.processInfo.environment["SOURCEDESK_LIVE_WEB"] == "1" else {
                    ctx.note("skipped: set SOURCEDESK_LIVE_WEB=1 to check the live endpoint")
                    return
                }
                let provider = OllamaProvider(endpoint: OllamaProvider.cloudEndpoint, keychain: EmptyKeychain())
                let models = try await provider.availableModels()
                try ctx.check(!models.isEmpty, "the catalogue returned models")
                ctx.note("live catalogue: \(models.count) models, e.g. \(models.prefix(3).map(\.name).joined(separator: ", "))")
                for model in models.prefix(20) {
                    try ctx.equal(model.isLocal, false, "\(model.name) is hosted")
                    try ctx.equal(model.providerID, "ollama-cloud")
                    try ctx.isNil(model.sizeDescription, "\(model.name) reports no download size")
                }
                try ctx.check(models.contains { $0.parameterSize != nil },
                              "at least some names yield a parameter count")
            }
        ])
    }
}
