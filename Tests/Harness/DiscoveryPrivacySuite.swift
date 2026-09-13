import Foundation
import SourceDeskCore

/// Privacy gating for source discovery.
///
/// "Find sources by topic" sends the user's topic and the titles of the search results to
/// the selected model. That is the same disclosure as asking a question, so it must obey
/// the same rules. It did not: discovery consulted a cloud provider with Local-Only Mode
/// switched on and with no per-notebook consent, while the README's privacy table promised
/// that nothing reached a cloud provider in that state.
///
/// The assertion that matters is therefore not "does discovery work" but "was the provider
/// actually called" — so every test counts real requests to a provider that records them. A
/// test that only inspected the plan's output would pass even while the topic was being sent.
enum DiscoveryPrivacySuite {

    /// A cloud provider that remembers every string it was asked to process.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        func record(_ text: String) { lock.lock(); _requests.append(text); lock.unlock() }
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    }

    struct CloudProvider: AIProvider {
        let recorder: Recorder
        var identifier: String { "recording-cloud" }
        var displayName: String { "Recording Cloud" }
        var isLocal: Bool { false }
        var isConfigured: Bool { true }
        var configurationHint: String? { nil }

        func availability() async -> ProviderAvailability { .ready }
        func availableModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(providerID: identifier, name: "cloud-1", isLocal: false)]
        }
        func generate(_ request: AIRequest) async throws -> AIResponse {
            for message in request.messages { recorder.record(message.content) }
            return AIResponse(text: "1", model: request.model)
        }
        func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func embed(_ texts: [String], model: String) async throws -> [[Float]] { [] }
    }

    struct LocalProvider: AIProvider {
        let recorder: Recorder
        var identifier: String { "recording-local" }
        var displayName: String { "Recording Local" }
        var isLocal: Bool { true }
        var isConfigured: Bool { true }
        var configurationHint: String? { nil }

        func availability() async -> ProviderAvailability { .ready }
        func availableModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(providerID: identifier, name: "local-1", isLocal: true)]
        }
        func generate(_ request: AIRequest) async throws -> AIResponse {
            recorder.record(request.messages.map(\.content).joined(separator: " "))
            return AIResponse(text: "1", model: request.model)
        }
        func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func embed(_ texts: [String], model: String) async throws -> [[Float]] { [] }
    }

    /// A cloud provider with no key: it must be withheld, not made fatal.
    struct UnkeyedProvider: AIProvider {
        var identifier: String { "unkeyed" }
        var displayName: String { "Unkeyed" }
        var isLocal: Bool { false }
        var isConfigured: Bool { false }
        var configurationHint: String? { "Add a key." }

        func availability() async -> ProviderAvailability { .notConfigured(reason: "Add a key.") }
        func availableModels() async throws -> [ModelDescriptor] { [] }
        func generate(_ request: AIRequest) async throws -> AIResponse {
            struct ShouldNotBeCalled: Error {}
            throw ShouldNotBeCalled()
        }
        func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func embed(_ texts: [String], model: String) async throws -> [[Float]] { [] }
    }

    struct FixedSearch: SearchProvider {
        let identifier = "fixed"
        let displayName = "Fixed Search"
        let requiresKey = false
        let isConfigured = true
        let configurationHint: String? = nil
        let privacyNote = "Nothing is sent anywhere."

        func search(query: String, limit: Int) async throws -> [WebSearchResult] {
            (1...6).map {
                WebSearchResult(
                    title: "Result title \($0)",
                    url: "https://example\($0).test/page",
                    snippet: "Snippet \($0)"
                )
            }
        }
    }

    static func service<P: AIProvider>(
        provider: P,
        gate: SourceDiscoveryService.Gate
    ) -> SourceDiscoveryService {
        SourceDiscoveryService(
            search: WebSearchService(provider: FixedSearch()),
            provider: provider,
            model: "cloud-1",
            gate: gate
        )
    }

    static let openGate = SourceDiscoveryService.Gate(
        localOnlyMode: false, cloudConsentGranted: true, networkIsOnline: true
    )
    static let localOnlyGate = SourceDiscoveryService.Gate(
        localOnlyMode: true, cloudConsentGranted: true, networkIsOnline: true
    )
    static let noConsentGate = SourceDiscoveryService.Gate(
        localOnlyMode: false, cloudConsentGranted: false, networkIsOnline: true
    )
    static let offlineGate = SourceDiscoveryService.Gate(
        localOnlyMode: false, cloudConsentGranted: true, networkIsOnline: false
    )

    static var suite: TestSuite {
        TestSuite("28 · Discovery privacy gating", cases: [

            // The baseline. Without it the tests below would all pass on a service that
            // never contacted a provider at all, which would prove nothing about the gate.
            test("with consent the cloud model judges the results") { ctx in
                let recorder = Recorder()
                let plan = try await service(
                    provider: CloudProvider(recorder: recorder), gate: openGate
                ).plan(topic: "inspectorate reform")
                try ctx.check(recorder.requests.count > 0, "the cloud model was consulted")
                try ctx.check(plan.selections.count > 0, "results were chosen")
                try ctx.check(plan.aiNotice == nil, "no notice is needed when AI chose")
            },

            test("Local-Only Mode keeps the topic away from a cloud model") { ctx in
                let recorder = Recorder()
                let plan = try await service(
                    provider: CloudProvider(recorder: recorder), gate: localOnlyGate
                ).plan(topic: "inspectorate reform")
                try ctx.equal(recorder.requests.count, 0,
                          "no request reached the cloud provider while Local-Only Mode was on")
                try ctx.check(plan.selections.count > 0, "the search still produced usable results")
                try ctx.check(plan.aiNotice?.contains("Local-Only") ?? false,
                          "the user is told why AI did not choose: \(plan.aiNotice ?? "nil")")
            },

            test("without notebook consent the topic stays local") { ctx in
                let recorder = Recorder()
                let plan = try await service(
                    provider: CloudProvider(recorder: recorder), gate: noConsentGate
                ).plan(topic: "inspectorate reform")
                try ctx.equal(recorder.requests.count, 0, "no request reached the cloud provider")
                try ctx.check(plan.selections.count > 0, "the search still produced usable results")
                try ctx.check(plan.aiNotice?.contains("not been approved") ?? false,
                          "the user is told consent is missing: \(plan.aiNotice ?? "nil")")
            },

            test("offline does not attempt a cloud model") { ctx in
                let recorder = Recorder()
                let plan = try await service(
                    provider: CloudProvider(recorder: recorder), gate: offlineGate
                ).plan(topic: "inspectorate reform")
                try ctx.equal(recorder.requests.count, 0, "no request reached the cloud provider")
                try ctx.check(plan.aiNotice?.contains("internet") ?? false,
                          "the user is told the connection is why: \(plan.aiNotice ?? "nil")")
            },

            // The topic is the sensitive string. Assert directly that it never appears in
            // anything sent, so a future extra call site cannot slip past unnoticed.
            test("the topic text is never sent when the gate is closed") { ctx in
                let recorder = Recorder()
                let secret = "a topic the user would not want sent"
                _ = try await service(
                    provider: CloudProvider(recorder: recorder), gate: localOnlyGate
                ).plan(topic: secret)
                let sent = recorder.requests.joined(separator: " ")
                try ctx.check(!(sent.contains(secret)), "the topic was not transmitted")
            },

            test("an unconfigured cloud provider is withheld, not fatal") { ctx in
                let plan = try await service(provider: UnkeyedProvider(), gate: openGate)
                    .plan(topic: "inspectorate reform")
                try ctx.check(plan.selections.count > 0, "the search still worked")
                try ctx.check(plan.aiNotice?.contains("API key") ?? false,
                          "the user is told the key is missing: \(plan.aiNotice ?? "nil")")
            },

            // A local model is never gated: Local-Only Mode exists to permit exactly this.
            test("a local model is consulted even in Local-Only Mode") { ctx in
                let recorder = Recorder()
                _ = try await service(
                    provider: LocalProvider(recorder: recorder), gate: localOnlyGate
                ).plan(topic: "inspectorate reform")
                try ctx.check(recorder.requests.count > 0, "the local model judged the results")
            }
        ])
    }
}
