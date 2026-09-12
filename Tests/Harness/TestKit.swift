import Foundation
import SourceDeskCore

/// A deliberately tiny test framework.
///
/// SwiftPM's `XCTest` and `swift-testing` bundles are not available with Apple's
/// Command Line Tools (they ship with Xcode), but SourceDesk still needs real,
/// runnable verification. So the suites live in an ordinary executable target that
/// runs them all and exits non-zero on failure. It is plain Swift: `throw` fails a
/// test, `check`/`equal`/`unwrap` count assertions, and everything below is exactly
/// what `swift test` would tell us.
public struct TestFailure: Error, CustomStringConvertible {
    public let description: String
    public var localizedDescription: String { description }
}

public final class TestContext {
    public private(set) var assertions = 0
    public var notes: [String] = []

    public init() {}

    public func check(_ condition: Bool, _ message: String = "condition was false", file: String = #fileID, line: UInt = #line) throws {
        assertions += 1
        guard condition else { throw TestFailure(description: "\(file):\(line) — \(message)") }
    }

    public func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #fileID, line: UInt = #line) throws {
        assertions += 1
        guard actual == expected else {
            throw TestFailure(description: "\(file):\(line) — expected \(expected), got \(actual)\(message.isEmpty ? "" : " (\(message))")")
        }
    }

    public func close(_ actual: Double, _ expected: Double, tolerance: Double = 1e-6, _ message: String = "", file: String = #fileID, line: UInt = #line) throws {
        assertions += 1
        guard abs(actual - expected) <= tolerance else {
            throw TestFailure(description: "\(file):\(line) — expected \(expected) ± \(tolerance), got \(actual)\(message.isEmpty ? "" : " (\(message))")")
        }
    }

    public func unwrap<T>(_ value: T?, _ message: String = "expected a value", file: String = #fileID, line: UInt = #line) throws -> T {
        assertions += 1
        guard let value else { throw TestFailure(description: "\(file):\(line) — \(message)") }
        return value
    }

    public func notNil<T>(_ value: T?, _ message: String = "expected a value", file: String = #fileID, line: UInt = #line) throws {
        assertions += 1
        guard value != nil else { throw TestFailure(description: "\(file):\(line) — \(message)") }
    }

    public func isNil<T>(_ value: T?, _ message: String = "expected nil", file: String = #fileID, line: UInt = #line) throws {
        assertions += 1
        guard value == nil else { throw TestFailure(description: "\(file):\(line) — \(message); got \(String(describing: value))") }
    }

    public func contains(_ haystack: String, _ needle: String, _ message: String = "", file: String = #fileID, line: UInt = #line) throws {
        assertions += 1
        guard haystack.localizedCaseInsensitiveContains(needle) else {
            throw TestFailure(description: "\(file):\(line) — expected to find \(needle.debugDescription) in \(haystack.prefix(400))\(message.isEmpty ? "" : " (\(message))")")
        }
    }

    public func doesNotContain(_ haystack: String, _ needle: String, _ message: String = "", file: String = #fileID, line: UInt = #line) throws {
        assertions += 1
        guard !haystack.localizedCaseInsensitiveContains(needle) else {
            throw TestFailure(description: "\(file):\(line) — did not expect \(needle.debugDescription) in \(haystack.prefix(400))\(message.isEmpty ? "" : " (\(message))")")
        }
    }

    public func close(_ actual: Float, _ expected: Float, tolerance: Float = 1e-6, _ message: String = "", file: String = #fileID, line: UInt = #line) throws {
        try close(Double(actual), Double(expected), tolerance: Double(tolerance), message, file: file, line: line)
    }

    /// Asserts that `body` throws, and returns the error so the test can inspect
    /// the message the user would actually see.
    @discardableResult
    public func expectError<T>(
        _ message: String,
        file: String = #fileID,
        line: UInt = #line,
        _ body: () async throws -> T
    ) async throws -> Error {
        assertions += 1
        do {
            _ = try await body()
            throw TestFailure(description: "\(file):\(line) — expected an error (\(message)) but the call succeeded")
        } catch let failure as TestFailure {
            throw failure
        } catch {
            return error
        }
    }

    public func note(_ text: String) { notes.append(text) }
}

public struct TestCase {
    public let name: String
    public let body: (TestContext) async throws -> Void
}

public func test(_ name: String, _ body: @escaping (TestContext) async throws -> Void) -> TestCase {
    TestCase(name: name, body: body)
}

public struct TestSuite {
    public let name: String
    public let cases: [TestCase]

    public init(_ name: String, cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }
}

public struct HarnessResult {
    public var suites = 0
    public var tests = 0
    public var assertions = 0
    public var failures: [(suite: String, test: String, message: String)] = []

    public var passed: Bool { failures.isEmpty }
}

public enum Harness {

    public static func run(
        suites: [TestSuite],
        filter: String? = nil,
        verbose: Bool = true
    ) async -> HarnessResult {
        var result = HarnessResult()
        let selected = suites.filter { suite in
            guard let filter else { return true }
            if suite.name.localizedCaseInsensitiveContains(filter) { return true }
            // A filter may also name a single test.
            return suite.cases.contains { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        for suite in selected {
            let suiteMatches = filter == nil || suite.name.localizedCaseInsensitiveContains(filter!)
            let cases = suiteMatches
                ? suite.cases
                : suite.cases.filter { $0.name.localizedCaseInsensitiveContains(filter!) }
            guard !cases.isEmpty else { continue }
            result.suites += 1
            if verbose { print("\n\u{001B}[1m\(suite.name)\u{001B}[0m") }
            for item in cases {
                result.tests += 1
                let context = TestContext()
                let start = Date()
                do {
                    try await item.body(context)
                    result.assertions += context.assertions
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    if verbose {
                        print("  \u{001B}[32m✓\u{001B}[0m \(item.name) \u{001B}[2m(\(context.assertions) checks, \(ms) ms)\u{001B}[0m")
                    }
                } catch {
                    result.assertions += context.assertions
                    let message: String
                    if let failure = error as? TestFailure {
                        message = failure.description
                    } else if let sde = error as? SourceDeskError {
                        message = "unexpected SourceDeskError: \(sde.errorDescription ?? "\(sde)")"
                    } else {
                        message = "\(error)"
                    }
                    result.failures.append((suite.name, item.name, message))
                    if verbose { print("  \u{001B}[31m✗\u{001B}[0m \(item.name)\n      \(message)") }
                }
            }
        }
        return result
    }

    public static func report(_ result: HarnessResult) -> Int32 {
        print("\n" + String(repeating: "─", count: 64))
        let verdict = result.passed ? "\u{001B}[32mPASS\u{001B}[0m" : "\u{001B}[31mFAIL\u{001B}[0m"
        print("\(verdict)  \(result.suites) suites · \(result.tests) tests · \(result.assertions) assertions · \(result.failures.count) failures")
        if !result.passed {
            print("\nFailing tests:")
            for failure in result.failures {
                print("  • \(failure.suite) → \(failure.test)\n      \(failure.message)")
            }
        }
        return result.passed ? 0 : 1
    }
}

// MARK: - Shared fixtures

public enum Fixtures {

    /// A provider that always answers, used where the point of a test is the
    /// pipeline around the model rather than the model itself.
    public static func stubProvider(identifier: String = "ollama", displayName: String = "Local stub") -> StubTestProvider {
        StubTestProvider(identifier: identifier, displayName: displayName)
    }

    /// A temporary, isolated store. Every suite that touches persistence uses one,
    /// so tests never see each other's data (and never touch the real library).
    public static func temporaryStore() throws -> (NotebookStore, AppPaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sourcedesk-harness-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        let store = try NotebookStore(paths: paths)
        return (store, paths)
    }

    public static func cleanup(_ paths: AppPaths) {
        try? FileManager.default.removeItem(at: paths.root)
    }

    @discardableResult
    public static func makeNotebook(_ store: NotebookStore, title: String = "Test Notebook") throws -> Notebook {
        let notebook = Notebook(title: title)
        return try store.upsert(notebook: notebook)
    }

    /// A long, realistic document used for chunking and retrieval tests.
    public static func longArticle(topic: String, paragraphs: Int = 40) -> String {
        var lines: [String] = ["# \(topic)", ""]
        for index in 0..<paragraphs {
            lines.append("Paragraph \(index + 1). The \(topic) programme entered phase \(index + 1) after the review board published its findings. ")
            lines.append("Officials cited budget pressure, staffing shortages and a rising backlog of permit applications as the proximate causes of the slowdown. ")
            lines.append("Independent analysts disagreed, arguing the decline began earlier, when the central office reorganised its inspection schedule. ")
            lines.append("By sector \(index % 7), throughput had fallen by \(5 + index % 30) percent against the previous year's baseline. ")
            lines.append("The committee asked for a follow-up report within ninety days, and recommended retaining the regional offices. ")
            lines.append("")
        }
        lines.append("## Conclusion")
        lines.append("The evidence points to two causes: an administrative reorganisation and a shortage of qualified inspectors. ")
        lines.append("Neither explanation alone accounts for the observed decline, and the two are not independent of one another.")
        return lines.joined(separator: "\n")
    }

    public static func htmlPage(title: String, body: String, navigation: Bool = true) -> String {
        let nav = navigation ? """
        <nav id="site-nav"><ul><li><a href="/home">Home</a></li><li><a href="/about">About</a></li>
        <li><a href="/subscribe">Subscribe now</a></li></ul></nav>
        <aside class="advert"><a href="/promo">Buy our newsletter — 50% off</a></aside>
        """ : ""
        return """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <title>\(title)</title>
        <meta name="author" content="A. Researcher">
        <meta property="article:published_time" content="2024-03-05T09:00:00Z">
        <meta name="description" content="A study of \(title).">
        <script>window.track = function(){ /* analytics */ }; window.track();</script>
        <style>body { font-family: sans-serif; }</style>
        </head><body>
        \(nav)
        <main>
        <h1>\(title)</h1>
        <p>\(body)</p>
        <h2>Method</h2>
        <p>The review board collected inspection logs from all regional offices and compared them with the previous baseline.</p>
        <footer><p>© 2024 Some Publisher. All rights reserved.</p><p><a href="/privacy">Privacy</a></p></footer>
        </main>
        </body></html>
        """
    }
}


/// A deterministic in-process provider. It answers from the material it was given,
/// citing the first marker it can see, which is what a compliant model does.
public struct StubTestProvider: AIProvider {
    public let identifier: String
    public let displayName: String
    public let isLocal = true
    public var isConfigured: Bool { true }
    public var configurationHint: String? { nil }

    public init(identifier: String = "ollama", displayName: String = "Local stub") {
        self.identifier = identifier
        self.displayName = displayName
    }

    public func availability() async -> ProviderAvailability { .ready }

    public func availableModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(providerID: identifier, name: "stub", parameterSize: "0.1B", isLocal: true)]
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        AIResponse(text: answer(for: request), model: request.model, usage: ChatUsage(promptTokens: 100, completionTokens: 20))
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let text = answer(for: request)
            continuation.yield(.started(model: request.model))
            for word in text.split(separator: " ") {
                continuation.yield(.delta(String(word) + " "))
            }
            continuation.yield(.finished(AIResponse(
                text: text, model: request.model,
                usage: ChatUsage(promptTokens: 100, completionTokens: 20), finishReason: "stop"
            )))
            continuation.finish()
        }
    }

    /// Answers from the supplied context, with the first citation marker it finds.
    private func answer(for request: AIRequest) -> String {
        let prompt = request.messages.last?.content ?? ""
        guard prompt.contains("[Source 1]") else {
            return "The material does not contain enough information to answer that."
        }
        let snippet = prompt
            .components(separatedBy: "[Source 1]")
            .dropFirst()
            .first?
            .components(separatedBy: "\n")
            .first(where: { $0.count > 40 })
            .map { TextMath.preview($0, limit: 200) } ?? ""
        return "According to the stored material, the decline was driven by the reorganisation of the inspection schedule and a shortage of inspectors. [Source 1] \(snippet)"
    }
}
