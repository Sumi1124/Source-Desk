import Foundation
import SourceDeskCore

/// The model picker's contents.
///
/// Two separate questions had been collapsed into one: "can this model be listed?" and
/// "can this model answer right now?". Conflating them meant a provider that could list
/// its models without a credential rendered an empty menu section, which looked like a
/// missing feature rather than a missing key.
enum ModelMenuSuite {

    private static func descriptor(
        _ name: String,
        isLocal: Bool = false,
        embeddings: Bool = false,
        context: Int? = nil,
        estimated: Bool = false,
        params: String? = nil
    ) -> ModelDescriptor {
        ModelDescriptor(
            providerID: "test",
            name: name,
            parameterSize: params,
            contextLength: context,
            contextLengthIsEstimated: estimated,
            isLocal: isLocal,
            supportsEmbeddings: embeddings
        )
    }

    static var suite: TestSuite {
        TestSuite("15 · Model menu", cases: [

            test("a hosted provider lists its models even with no key stored") { ctx in
                // The exact situation reported: Ollama Cloud reachable and listable but
                // not configured, so the menu must still offer the choice.
                let models = [descriptor("gpt-oss:120b", params: "120B"),
                              descriptor("glm-5.3"),
                              descriptor("nomic-embed-text", embeddings: true)]
                let section = ModelMenuPolicy.section(
                    providerID: "ollama-cloud",
                    displayName: "Ollama Cloud",
                    models: models,
                    availability: .notConfigured(reason: "no Ollama API key is stored (Settings → AI Providers)"),
                    hasBeenProbed: true
                )

                try ctx.equal(section.displayName, "Ollama Cloud")
                // Both chat models appear; the embedding model does not (it cannot answer).
                try ctx.equal(section.rows.count, 2, "chat models are listed")
                try ctx.equal(section.rows.map(\.model.name), ["gpt-oss:120b", "glm-5.3"])
                // The reason is stated, and no model claims to be usable.
                try ctx.contains(section.statusLine ?? "", "no Ollama API key")
                try ctx.check(section.rows.allSatisfy { !$0.isUsable }, "nothing claims to be usable without a key")
                try ctx.check(!section.hasUsableModel, "the section reports nothing usable")
                try ctx.isNil(section.emptyLine, "a populated section needs no empty line")
            },

            test("a ready provider marks its models usable") { ctx in
                let section = ModelMenuPolicy.section(
                    providerID: "ollama",
                    displayName: "Ollama (local)",
                    models: [descriptor("llama3.2:3b", isLocal: true, context: 131_072, params: "3.2B")],
                    availability: .ready,
                    hasBeenProbed: true
                )
                try ctx.isNil(section.statusLine, "a ready provider has nothing to explain")
                try ctx.check(section.rows.allSatisfy(\.isUsable), "models are usable")
                try ctx.check(section.hasUsableModel)
            },

            test("an empty section distinguishes checking from finding nothing") { ctx in
                let checking = ModelMenuPolicy.section(
                    providerID: "p", displayName: "P", models: [],
                    availability: nil, hasBeenProbed: false
                )
                try ctx.equal(checking.emptyLine, "Checking…")

                let probed = ModelMenuPolicy.section(
                    providerID: "p", displayName: "P", models: [],
                    availability: .ready, hasBeenProbed: true
                )
                try ctx.equal(probed.emptyLine, "No models found")

                // A not-ready provider shows its reason on the status line, so the empty
                // line must not repeat the same sentence twice.
                let blocked = ModelMenuPolicy.section(
                    providerID: "p", displayName: "P", models: [],
                    availability: .unreachable(reason: "the server is not running"),
                    hasBeenProbed: true
                )
                try ctx.equal(blocked.emptyLine, "No models listed")
                try ctx.equal(blocked.statusLine, "the server is not running")
                try ctx.check(blocked.emptyLine != blocked.statusLine, "the reason is not repeated")
            },

            test("an estimated context window is labelled, a reported one is not") { ctx in
                // Reporting an inferred window as fact would be the same class of error
                // as presenting an uncompressed model weight as a download size.
                let reported = descriptor("llama3.2:3b", isLocal: true, context: 131_072)
                try ctx.equal(reported.detailLine, "131,072 token context")
                try ctx.check(!reported.detailLine.contains("est."), "a measured window is stated plainly")

                let estimated = descriptor("gpt-oss:120b", context: 131_072, estimated: true, params: "120B")
                try ctx.contains(estimated.detailLine, "est.")
                try ctx.contains(estimated.detailLine, "~131,072")
            },

            test("an empty local Ollama mentions the no-download alternative") { ctx in
                // "Run ollama pull" alone hides the option that costs nothing. With no
                // models installed, the user should hear about the hosted route too,
                // because the difference is a two-gigabyte wait versus an answer now.
                let server = LocalHTTPServer { _ in .json(["models": []]) }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .local, keychain: EmptyKeychain())
                let availability = await provider.availability()
                try ctx.check(!availability.isReady, "an empty install is not ready")
                let reason = try ctx.unwrap(availability.reason)
                try ctx.contains(reason, "ollama pull", "it says how to get a local model")
                try ctx.contains(reason, "Ollama Cloud", "and that a hosted model needs no download")
            },

            test("a model with nothing known says where it runs, not a guess") { ctx in
                try ctx.equal(descriptor("mystery").detailLine, "Cloud model")
                try ctx.equal(descriptor("mystery", isLocal: true).detailLine, "Local model")
            },

            test("the Ollama provider labels inferred windows and keeps reported ones") { ctx in
                // One server reporting a real window, one model reporting none — the two
                // cases the descriptor has to tell apart.
                let server = LocalHTTPServer { _ in
                    .json(["models": [
                        ["name": "llama3.2:3b", "size": 2_019_393_182,
                         "details": ["parameter_size": "3.2B", "quantization_level": "Q4_K_M"],
                         "model_info": ["llama.context_length": 131_072]],
                        ["name": "gpt-oss:120b", "size": 65_290_180_781,
                         "details": ["parameter_size": "", "quantization_level": ""]]
                    ]])
                }
                try server.start()
                defer { server.stop() }

                let provider = OllamaProvider(endpoint: server.baseURL, host: .local, keychain: EmptyKeychain())
                let models = try await provider.availableModels()
                let measured = try ctx.unwrap(models.first { $0.name == "llama3.2:3b" })
                try ctx.equal(measured.contextLength, 131_072)
                try ctx.check(!measured.contextLengthIsEstimated, "a reported window is not an estimate")

                let inferred = try ctx.unwrap(models.first { $0.name == "gpt-oss:120b" })
                try ctx.check(inferred.contextLengthIsEstimated, "an inferred window is marked as an estimate")
                try ctx.contains(inferred.detailLine, "est.")
            },
        ])
    }
}
