import Foundation
import SourceDeskCore

/// Ad-hoc diagnostics, run explicitly with `--debug-scratch`.
///
/// Kept in the repository because it is genuinely useful: it drives the hosted Ollama
/// API through the same code the app uses, which is how the shape of that endpoint
/// (blank `details`, unauthenticated catalogue, uncompressed sizes) was established.
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

            // The catalogue is readable without a key, which is what lets the app show
            // what exists before the user has created one.
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

            // With no key, generation must say exactly that — not a bare 401.
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
        print("--- done ---")
    }
}
