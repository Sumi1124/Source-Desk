import Foundation
import SourceDeskCore

/// "Find sources about X": the search plus the AI's judgement.
///
/// The model is used for the one thing a search engine cannot do — deciding which of
/// twenty results actually relate to what the user asked — so the checks here are mostly
/// about what happens when the model misbehaves. A model that invents a result, answers
/// with prose, or refuses must not cause an unintended download or an unexplained empty
/// list.
enum SourceDiscoverySuite {

    /// Returns a fixed result list.
    struct FixedSearch: SearchProvider {
        let identifier = "fixed"
        let displayName = "Fixed Search"
        let requiresKey = false
        let isConfigured = true
        let configurationHint: String? = nil
        let privacyNote = "Nothing is sent anywhere."
        let results: [WebSearchResult]

        func search(query: String, limit: Int) async throws -> [WebSearchResult] {
            Array(results.prefix(limit))
        }
    }

    /// A provider whose replies are scripted per call, so a test can control what the
    /// model says for the query-rewrite step and then for the selection step.
    struct ScriptedProvider: AIProvider {
        var identifier: String { "scripted" }
        var displayName: String { "Scripted Model" }
        var isLocal: Bool { true }
        var isConfigured: Bool { true }
        var configurationHint: String? { nil }
        /// Replies in order; the last one repeats if more calls happen.
        var replies: [String]
        var failure: SourceDeskError?
        /// Records the prompts, so a test can assert what the model was actually shown.
        final class Log: @unchecked Sendable { var prompts: [String] = [] }
        let log = Log()

        func availability() async -> ProviderAvailability { .ready }

        func availableModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(providerID: identifier, name: "scripted-1", isLocal: true)]
        }

        func generate(_ request: AIRequest) async throws -> AIResponse {
            if let failure { throw failure }
            log.prompts.append(request.messages.map(\.content).joined(separator: "\n"))
            let index = min(log.prompts.count - 1, replies.count - 1)
            return AIResponse(text: replies[max(0, index)], model: request.model,
                              usage: ChatUsage(promptTokens: 10, completionTokens: 10))
        }

        func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    static func candidate(_ index: Int, title: String? = nil, path: String = "") -> WebSearchResult {
        WebSearchResult(
            title: title ?? "Result \(index)",
            url: "https://example\(index).com/\(path.isEmpty ? "article" : path)",
            snippet: "A snippet describing result \(index)."
        )
    }

    static func service(
        results: [WebSearchResult],
        replies: [String],
        failure: SourceDeskError? = nil
    ) -> (SourceDiscoveryService, ScriptedProvider) {
        let provider = ScriptedProvider(replies: replies, failure: failure)
        let search = WebSearchService(provider: FixedSearch(results: results))
        let service = SourceDiscoveryService(
            search: search, provider: provider, model: "scripted-1",
            options: .init(candidatesToConsider: 20, fallbackKeep: 3, maximumKeep: 5)
        )
        return (service, provider)
    }

    static var suite: TestSuite {
        TestSuite("23 · Find sources by topic", cases: [

            test("the model's choice decides which results are kept") { ctx in
                let candidates = (1...6).map { candidate($0) }
                // First reply rewrites the query, second selects results 3 and 5.
                let (service, _) = service(results: candidates, replies: [
                    "industrial decline causes",
                    "3 | a primary source\n5 | directly on the topic"
                ])
                let plan = try await service.plan(topic: "why did the decline happen", limit: 4)

                try ctx.equal(plan.searchedCount, 6)
                try ctx.equal(plan.keptCount, 2)
                try ctx.equal(plan.results.map(\.url),
                              ["https://example3.com/article", "https://example5.com/article"])
                try ctx.equal(plan.selections[0].reason, "a primary source")
                try ctx.check(plan.selections.allSatisfy(\.chosenByModel))
                try ctx.equal(plan.query, "industrial decline causes")
                try ctx.check(plan.queryWasRewritten, "the model's query replaced the topic")
                try ctx.isNil(plan.aiNotice)
            },

            test("a result index the model invents is ignored, not clamped") { ctx in
                // If the model says "result 9" when six were offered, that is a
                // hallucination. Clamping it to 6 would download a page nobody chose.
                let candidates = (1...6).map { candidate($0) }
                let (service, _) = service(results: candidates, replies: [
                    "query",
                    "2 | real\n9 | invented\n0 | also invented\n-3 | nonsense"
                ])
                let plan = try await service.plan(topic: "anything", limit: 4)

                try ctx.equal(plan.keptCount, 1, "only the in-range choice survives")
                try ctx.equal(plan.results[0].url, "https://example2.com/article")
            },

            test("the model is sent titles, hosts and snippets but never a download") { ctx in
                // What leaves the Mac for this step is the topic and the result metadata.
                // Asserting the shape keeps that honest: if a future change started
                // sending page bodies, this would fail.
                let candidates = [candidate(1, title: "Thornbury report", path: "report")]
                let (service, provider) = service(results: candidates, replies: ["q", "1 | good"])
                _ = try await service.plan(topic: "the decline", limit: 3)

                try ctx.check(provider.log.prompts.count >= 2, "the model was consulted for both steps")
                let selectionPrompt = try ctx.unwrap(provider.log.prompts.last)
                try ctx.contains(selectionPrompt, "the decline", "the topic is included")
                try ctx.contains(selectionPrompt, "Thornbury report", "the result title is included")
                try ctx.contains(selectionPrompt, "A snippet describing result 1", "the snippet is included")
                try ctx.doesNotContain(selectionPrompt, "WEB RESULTS", "no page bodies are attached")
            },

            test("a model that replies with prose falls back to the top results") { ctx in
                // Models do sometimes answer a selection request with a sentence. The run
                // must still produce usable sources, and say the AI was not used.
                let candidates = (1...5).map { candidate($0) }
                let (service, _) = service(results: candidates, replies: [
                    "query",
                    "I'm sorry, I can't help with selecting results."
                ])
                let plan = try await service.plan(topic: "anything", limit: 3)

                try ctx.equal(plan.keptCount, 3, "the top results were used")
                try ctx.check(plan.selections.allSatisfy { !$0.chosenByModel })
                let notice = try ctx.unwrap(plan.aiNotice)
                try ctx.contains(notice, "could not be read")
            },

            test("a model that says NONE is believed") { ctx in
                // The opposite case, and it must not be confused with a parse failure:
                // "none of these are relevant" is an answer, not an error.
                let candidates = (1...5).map { candidate($0) }
                let (service, _) = service(results: candidates, replies: ["query", "NONE"])
                let plan = try await service.plan(topic: "something obscure", limit: 3)

                try ctx.equal(plan.keptCount, 0, "nothing was selected")
                let notice = try ctx.unwrap(plan.aiNotice)
                try ctx.contains(notice, "judged none")
            },

            test("an unusable model still returns sources, and says so") { ctx in
                // A missing key or an unreachable model must not block finding pages;
                // fetching the obvious results beats refusing to do anything.
                let candidates = (1...5).map { candidate($0) }
                let (service, _) = service(
                    results: candidates, replies: ["query", "1 | x"],
                    failure: .missingAPIKey(provider: "Scripted Model")
                )
                let plan = try await service.plan(topic: "anything", limit: 3)

                try ctx.equal(plan.keptCount, 3)
                try ctx.check(plan.selections.allSatisfy { !$0.chosenByModel })
                let notice = try ctx.unwrap(plan.aiNotice)
                try ctx.contains(notice, "top results")
            },

            test("the fallback prefers article pages over obvious section listings") { ctx in
                // Search engines surface their own category and tag pages for some
                // queries. Those are near-empty, so the model-free path should not lead
                // with them.
                let candidates = [
                    candidate(1, title: "Tag listing", path: "tag/risc-v"),
                    candidate(2, title: "Category", path: "category/architecture"),
                    candidate(3, title: "Real article", path: "2024/risc-v-history"),
                    candidate(4, title: "Home", path: "")
                ]
                let (service, _) = service(results: candidates, replies: ["q", "unparseable prose"])
                let plan = try await service.plan(topic: "risc-v", limit: 2)

                try ctx.equal(plan.keptCount, 2)
                try ctx.equal(plan.results.first?.title, "Real article",
                              "the substantive page leads the fallback")
            },

            test("the model cannot exceed the hard ceiling on downloads") { ctx in
                // A model replying "1..20" must not start a twenty-page crawl.
                let candidates = (1...20).map { candidate($0) }
                let all = (1...20).map { "\($0) | yes" }.joined(separator: "\n")
                let (service, _) = service(results: candidates, replies: ["q", all])
                let plan = try await service.plan(topic: "anything", limit: 12)

                try ctx.equal(plan.keptCount, 5, "bounded by maximumKeep")
            },

            test("a query the model mangles is rejected and the topic is used") { ctx in
                let candidates = [candidate(1)]
                let (service, _) = service(results: candidates, replies: [
                    "I cannot help with that request, but here is a long explanation of why not.",
                    "1 | fine"
                ])
                let plan = try await service.plan(topic: "the decline", limit: 2)

                try ctx.equal(plan.query, "the decline", "the original topic was searched")
                try ctx.check(!plan.queryWasRewritten)
            },

            test("an empty search result is reported rather than thrown as a fault") { ctx in
                let (service, _) = service(results: [], replies: ["q", "1 | x"])
                let plan = try await service.plan(topic: "nothing matches this", limit: 3)
                try ctx.equal(plan.searchedCount, 0)
                try ctx.equal(plan.keptCount, 0)
            },

            test("duplicate result lines from the model are only counted once") { ctx in
                let candidates = (1...4).map { candidate($0) }
                let (service, _) = service(results: candidates, replies: [
                    "q", "2 | first mention\n2 | repeated\n3 | other"
                ])
                let plan = try await service.plan(topic: "t", limit: 4)
                try ctx.equal(plan.keptCount, 2, "no duplicate pages")
                try ctx.equal(plan.results.map(\.url), [
                    "https://example2.com/article", "https://example3.com/article"
                ])
            },
        ])
    }
}
