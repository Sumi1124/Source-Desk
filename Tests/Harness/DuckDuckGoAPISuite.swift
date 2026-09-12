import Foundation
import SourceDeskCore

/// DuckDuckGo's documented Instant Answer API.
///
/// Worth testing carefully because its output is *not* a web result list, and the failure
/// mode is subtle: its related-topic links frequently point back into DuckDuckGo itself
/// (`duckduckgo.com/RISC-V_ecosystem`, `/c/Some_Category`). Returning those would store
/// the search engine's own navigation pages as research sources — thin content that would
/// then be cited as if it were a document. Measured against the live endpoint: a query
/// returns one genuinely citable page (usually Wikipedia) plus several internal links.
enum DuckDuckGoAPISuite {

    /// The shape the live endpoint actually returns, trimmed to the interesting parts.
    static func payload(abstract: String = "", related: [[String: Any]] = [], results: [[String: Any]] = []) -> [String: Any] {
        var json: [String: Any] = [
            "Heading": "RISC-V",
            "AbstractText": abstract,
            "AbstractURL": abstract.isEmpty ? "" : "https://en.wikipedia.org/wiki/RISC-V",
            "AbstractSource": "Wikipedia",
            "Results": results,
            "RelatedTopics": related
        ]
        json["Definition"] = ""
        json["DefinitionURL"] = ""
        return json
    }

    static var suite: TestSuite {
        TestSuite("24 · DuckDuckGo API provider", cases: [

            test("the abstract becomes the first, best result") { ctx in
                let json = payload(abstract: "RISC-V is a free and open standard instruction set architecture.")
                let results = DuckDuckGoInstantAnswerProvider.parse(json: json, query: "risc-v", limit: 5)
                try ctx.equal(results.count, 1)
                try ctx.equal(results[0].url, "https://en.wikipedia.org/wiki/RISC-V")
                try ctx.contains(results[0].snippet, "free and open standard")
                try ctx.equal(results[0].siteName, "en.wikipedia.org")
            },

            test("links back into DuckDuckGo itself are not offered as sources") { ctx in
                // The specific trap: these are navigation pages on the search engine.
                let related: [[String: Any]] = [
                    ["Text": "RISC-V ecosystem - Tools and platforms", "FirstURL": "https://duckduckgo.com/RISC-V_ecosystem"],
                    ["Text": "RISC-V Category - Categories", "FirstURL": "https://duckduckgo.com/c/RISC-V"],
                    ["Text": "RISC-V - Wikipedia article", "FirstURL": "https://en.wikipedia.org/wiki/RISC-V"]
                ]
                let json = payload(related: related)
                let results = DuckDuckGoInstantAnswerProvider.parse(json: json, query: "risc-v", limit: 10)

                try ctx.equal(results.count, 1, "only the real site survives")
                try ctx.equal(results[0].url, "https://en.wikipedia.org/wiki/RISC-V")
                for result in results {
                    try ctx.doesNotContain(result.url, "duckduckgo.com",
                                           "no search-engine navigation pages")
                }
            },

            test("nested topic groups are flattened") { ctx in
                // The API nests: a RelatedTopics entry may carry its own Topics array.
                let related: [[String: Any]] = [
                    ["Name": "Group", "Topics": [
                        ["Text": "One - first", "FirstURL": "https://example.com/one"],
                        ["Text": "Two - second", "FirstURL": "https://example.com/two"]
                    ]]
                ]
                let json = payload(related: related)
                let results = DuckDuckGoInstantAnswerProvider.parse(json: json, query: "q", limit: 10)
                try ctx.equal(results.count, 2, "both nested entries are found")
                try ctx.equal(results.map(\.url), ["https://example.com/one", "https://example.com/two"])
            },

            test("a long topic sentence is shortened into a usable title") { ctx in
                let related: [[String: Any]] = [
                    ["Text": "Industrial Revolution - The transition to new manufacturing processes in the period from about 1760 to sometime between 1820 and 1840.",
                     "FirstURL": "https://en.wikipedia.org/wiki/Industrial_Revolution"]
                ]
                let json = payload(related: related)
                let results = DuckDuckGoInstantAnswerProvider.parse(json: json, query: "q", limit: 5)
                try ctx.equal(results[0].title, "Industrial Revolution")
                try ctx.contains(results[0].snippet, "transition to new manufacturing")
            },

            test("an entry with no link cannot become a source") { ctx in
                // Without a URL there is nothing to cite, so it must not be returned.
                let related: [[String: Any]] = [
                    ["Text": "Some fact with no link", "FirstURL": ""],
                    ["Text": "Another with no key"],
                    ["Text": "A real one", "FirstURL": "https://example.org/real"]
                ]
                let json = payload(related: related)
                let results = DuckDuckGoInstantAnswerProvider.parse(json: json, query: "q", limit: 10)
                try ctx.equal(results.count, 1)
                try ctx.equal(results[0].url, "https://example.org/real")
            },

            test("duplicate URLs are returned once") { ctx in
                let related: [[String: Any]] = [
                    ["Text": "First copy", "FirstURL": "https://example.com/same"],
                    ["Text": "Second copy", "FirstURL": "https://example.com/same"]
                ]
                let json = payload(abstract: "An abstract",
                                   related: related)
                let results = DuckDuckGoInstantAnswerProvider.parse(json: json, query: "q", limit: 10)
                try ctx.equal(results.count, 2, "the abstract plus one copy of the shared URL")
                try ctx.equal(Set(results.map(\.url)).count, results.count, "all URLs distinct")
            },

            test("the provider needs no key and says what it is for") { ctx in
                let provider = DuckDuckGoInstantAnswerProvider()
                try ctx.check(!provider.requiresKey, "no key required")
                try ctx.check(provider.isConfigured, "and it is usable out of the box")
                // The honest description matters: this is not a general web search.
                try ctx.contains(provider.configurationHint ?? "", "not for news")
                try ctx.contains(provider.displayName, "API")
            },

            test("it is registered as a selectable engine alongside the others") { ctx in
                let provider = SearchProviderFactory.make(choice: .duckduckgoInstantAnswer)
                try ctx.notNil(provider)
                try ctx.equal(provider?.identifier, "duckduckgo-api")
                // And the two DuckDuckGo options are distinguishable in the UI.
                try ctx.check(SearchEngine.duckduckgo.displayName != SearchEngine.duckduckgoInstantAnswer.displayName)
                try ctx.contains(SearchEngine.duckduckgoInstantAnswer.detail, "instant answers")
            },
        ])
    }
}
