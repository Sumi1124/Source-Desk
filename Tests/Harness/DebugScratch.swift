import Foundation
import SourceDeskCore

/// Ad-hoc diagnostics, run explicitly with `--debug-scratch`.
///
/// Kept in the repository because it is genuinely useful: it drives the hosted Ollama
/// API through the same code the app uses, which is how the shape of that endpoint
/// (blank `details`, unauthenticated catalogue, uncompressed sizes) was established.
///
/// It also prints exactly what the toolbar's model menu is built from, provider by
/// provider, so "is the Ollama Cloud choice visible?" is answered by the code that
/// renders it rather than by reading source.
enum DebugScratch {

    static func run() {
        print("--- Ollama Cloud, live ---")
        let provider = OllamaProvider(endpoint: OllamaProvider.cloudEndpoint, host: .cloud, keychain: EmptyKeychain())

        print("identifier:   \(provider.identifier)")
        print("displayName:  \(provider.displayName)")
        print("isLocal:      \(provider.isLocal)")
        print("isConfigured: \(provider.isConfigured)  (no key in the Keychain)")

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let availability = await provider.availability()
            print("availability: \(availability)")

            do {
                let models = try await provider.availableModels()
                print("models:       \(models.count)")
                for model in models {
                    let params: String = model.parameterSize ?? "-"
                    let context: Int = model.contextLength ?? 0
                    let size: String = model.sizeDescription ?? "(not a download)"
                    print("  \(model.name)  params={\(params)}  ctx=\(context)  size=\(size)")
                }
            } catch {
                print("models failed: \(error)")
            }

            do {
                _ = try await provider.generate(AIRequest(messages: [.user("hi")], model: "gpt-oss:120b"))
                print("generate:     UNEXPECTED SUCCESS (is a key configured?)")
            } catch let error as SourceDeskError {
                print("generate err: \(error.errorDescription ?? "")")
                print("  recovery:   \(error.recoverySuggestion ?? "")")
            } catch {
                print("generate err: \(error)")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 45) == .timedOut { print("TIMED OUT") }

        print("")
        print("--- what the toolbar model menu is built from ---")
        // The same registry the app builds, then the same policy the menu renders from.
        // Listing is attempted regardless of configuration, which is the fix under test.
        let registry = ProviderRegistry.standard(
            ollamaEndpoint: URL(string: "http://127.0.0.1:11434")!,
            ollamaCloudEndpoint: OllamaProvider.cloudEndpoint,
            keychain: EmptyKeychain()
        )
        let menuSemaphore = DispatchSemaphore(value: 0)
        Task {
            for provider in registry.all {
                let availability = await provider.availability()
                let models = (try? await provider.availableModels()) ?? []
                let section = ModelMenuPolicy.section(
                    providerID: provider.identifier,
                    displayName: provider.displayName,
                    models: models,
                    availability: availability,
                    hasBeenProbed: true
                )
                print("section \u{201C}\(section.displayName)\u{201D}  models=\(section.rows.count)  usable=\(section.hasUsableModel)")
                if let statusLine = section.statusLine { print("    status: \(statusLine)") }
                if let emptyLine = section.emptyLine { print("    empty:  \(emptyLine)") }
                for row in section.rows.prefix(5) {
                    print("    row: \(row.model.name) — \(row.model.detailLine)")
                }
                if section.rows.count > 5 { print("    \u{2026} \(section.rows.count - 5) more") }
            }
            menuSemaphore.signal()
        }
        if menuSemaphore.wait(timeout: .now() + 60) == .timedOut { print("MENU TIMED OUT") }

        print("--- done ---")
    }
}
